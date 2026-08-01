"""Loopback FastAPI broker that isolates Kompress provider processes."""

from __future__ import annotations

import asyncio
import inspect
import json
import math
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse


_DEVICE_LOSS_CODES = ("887a0005", "887a0006", "887a0007", "887a0020")
_ERROR_CODE_RE = re.compile(r"^[A-Za-z0-9_.-]{1,80}$")
_READER_EOF = object()


@dataclass(frozen=True)
class _ReaderFailure:
    """Internal reader sentinel; never exposed in an HTTP response."""

    error: BaseException


def _float_env(name: str, default: float, minimum: float, maximum: float) -> float:
    try:
        value = float(os.environ.get(name, str(default)))
    except ValueError:
        return default
    return value if minimum <= value <= maximum else default


def _int_env(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.environ.get(name, str(default)))
    except ValueError:
        return default
    return value if minimum <= value <= maximum else default


def _safe_text(value: Any, default: str) -> str:
    """Return a bounded metadata string without ever persisting request data."""

    if not isinstance(value, str):
        return default
    text = value.strip()
    if not text or len(text) > 120 or any(ord(char) < 0x20 for char in text):
        return default
    return text


def _safe_error_code(value: Any, default: str) -> str:
    candidate = value if isinstance(value, str) else ""
    if _ERROR_CODE_RE.fullmatch(candidate):
        return candidate
    lowered = candidate.lower()
    for code in _DEVICE_LOSS_CODES:
        if code in lowered:
            return f"device_lost_{code}"
    if "device" in lowered and any(
        marker in lowered for marker in ("loss", "lost", "removed", "removal")
    ):
        return "device_lost"
    return default


def _request_failure_code(exc: BaseException) -> str:
    """Map worker/protocol failures to stable, non-sensitive fallback codes."""

    message = str(exc).lower()
    if "decode" in message or "unicode" in message or "json" in message:
        return "decode_error"
    if "malformed" in message or "mismatch" in message:
        return "malformed_output"
    if "eof" in message or "crash" in message or "unavailable" in message:
        return "worker_crash"
    if "timeout" in message:
        return "provider_timeout"
    return "worker_error"


def _json_error(status_code: int, error_type: str, message: str) -> JSONResponse:
    """Build API errors with keyword arguments (FastAPI 0.110+ contract)."""

    return JSONResponse(
        status_code=status_code,
        content={"error": {"type": error_type, "message": message}},
    )


@dataclass(frozen=True)
class BrokerConfig:
    worker_python: Path
    worker_module: str = "kompress_broker.worker"
    provider_backend: str = "cpu"
    queue_limit: int = 4
    queue_wait_seconds: float = 0.1
    request_timeout_seconds: float = 20.0
    startup_timeout_seconds: float = 90.0
    max_content_bytes: int = 16 * 1024 * 1024
    state_path: Path | None = None
    worker_stderr_path: Path | None = None

    @classmethod
    def from_env(cls) -> "BrokerConfig":
        state_raw = os.environ.get("KOMPRESS_BROKER_STATE_PATH", "").strip()
        stderr_raw = os.environ.get("KOMPRESS_WORKER_STDERR_PATH", "").strip()
        return cls(
            worker_python=Path(os.environ.get("KOMPRESS_WORKER_PYTHON", sys.executable)),
            provider_backend=os.environ.get("KOMPRESS_PROVIDER_BACKEND", "cpu").strip().lower(),
            queue_limit=_int_env("KOMPRESS_QUEUE_LIMIT", 4, 0, 128),
            queue_wait_seconds=_float_env("KOMPRESS_QUEUE_WAIT_SECONDS", 0.1, 0.001, 30.0),
            request_timeout_seconds=_float_env("KOMPRESS_REQUEST_TIMEOUT_SECONDS", 20.0, 0.1, 300.0),
            startup_timeout_seconds=_float_env("KOMPRESS_STARTUP_TIMEOUT_SECONDS", 90.0, 1.0, 600.0),
            max_content_bytes=_int_env(
                "KOMPRESS_MAX_CONTENT_BYTES", 16 * 1024 * 1024, 1024, 128 * 1024 * 1024
            ),
            state_path=Path(state_raw) if state_raw else None,
            worker_stderr_path=Path(stderr_raw) if stderr_raw else None,
        )


class ProviderWorker:
    def __init__(self, config: BrokerConfig) -> None:
        self.config = config
        self._process: subprocess.Popen[str] | None = None
        self._stderr_handle: Any = None
        # Protocol I/O is serialized, while lifecycle operations deliberately
        # use a separate lock.  A timeout must be able to terminate the child
        # even when a request is blocked waiting for stdout.
        self._io_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._reader_thread: threading.Thread | None = None
        self._reader_stop: threading.Event | None = None
        self._responses: queue.Queue[Any] | None = None
        self.provider: str | None = None
        self.backend: str | None = None

    def _reader_loop(
        self,
        process: subprocess.Popen[str],
        responses: queue.Queue[Any],
        stop_event: threading.Event,
    ) -> None:
        """Drain stdout in one daemon thread and hand complete lines to callers.

        A new executor future for each read leaks a blocked thread when a child
        stops producing output.  One bounded-lifetime reader instead makes a
        timeout deterministic: terminating/closing the child causes EOF and
        the reader exits without holding the protocol lock.
        """

        try:
            stream = process.stdout
            if stream is None:
                return
            while not stop_event.is_set():
                line = stream.readline()
                if not line:
                    break
                responses.put(line)
        except BaseException as exc:  # noqa: BLE001 - convert to fail-open sentinel
            if not stop_event.is_set():
                responses.put(_ReaderFailure(exc))
        finally:
            responses.put(_READER_EOF)

    def _readline(self, timeout: float) -> str:
        responses = self._responses
        if responses is None:
            raise RuntimeError("worker_not_started")
        try:
            item = responses.get(timeout=max(0.0, timeout))
        except queue.Empty as exc:
            raise TimeoutError("worker_response_timeout") from exc
        if item is _READER_EOF:
            raise RuntimeError("worker_response_eof")
        if isinstance(item, _ReaderFailure):
            if isinstance(item.error, UnicodeError):
                raise RuntimeError("worker_stdout_decode_error") from item.error
            raise RuntimeError("worker_stdout_error") from item.error
        if not isinstance(item, str):
            raise RuntimeError("worker_response_malformed")
        return item

    def _detach_process(self) -> tuple[subprocess.Popen[str] | None, threading.Thread | None]:
        with self._state_lock:
            process = self._process
            self._process = None
            stop_event = self._reader_stop
            reader_thread = self._reader_thread
            self._reader_stop = None
            self._reader_thread = None
            self._responses = None
            self.provider = None
            self.backend = None

        if stop_event is not None:
            stop_event.set()
        return process, reader_thread

    def _stop_process(self) -> None:
        detached = self._detach_process()
        process, reader_thread = detached
        if process is not None:
            try:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=3)
            except (OSError, subprocess.SubprocessError):
                # The process may have exited between poll/terminate; this is
                # already a fail-open path and does not affect the caller.
                pass
            for stream in (process.stdin, process.stdout):
                if stream is not None:
                    try:
                        stream.close()
                    except (OSError, ValueError):
                        pass
        if reader_thread is not None and reader_thread is not threading.current_thread():
            reader_thread.join(timeout=1.0)
        if self._stderr_handle is not None:
            try:
                self._stderr_handle.close()
            except (OSError, ValueError):
                pass
            self._stderr_handle = None

    def start(self) -> None:
        self._stop_process()
        if not self.config.worker_python.is_file():
            raise FileNotFoundError(f"worker_python_missing:{self.config.worker_python}")

        environment = os.environ.copy()
        environment["KOMPRESS_PROVIDER_BACKEND"] = self.config.provider_backend
        # The isolated production provider is intentionally CPU-only.  Do not
        # inherit a parent process's experimental accelerator selection.
        environment["HEADROOM_KOMPRESS_BACKEND"] = "onnx_cpu"
        package_root = str(Path(__file__).resolve().parent.parent)
        existing_pythonpath = environment.get("PYTHONPATH", "")
        pythonpath_parts = [part for part in existing_pythonpath.split(os.pathsep) if part]
        if package_root not in pythonpath_parts:
            pythonpath_parts.insert(0, package_root)
        environment["PYTHONPATH"] = os.pathsep.join(pythonpath_parts)
        stderr_target: Any = subprocess.DEVNULL
        stderr_handle: Any = None
        if self.config.worker_stderr_path is not None:
            self.config.worker_stderr_path.parent.mkdir(parents=True, exist_ok=True)
            stderr_handle = self.config.worker_stderr_path.open("a", encoding="utf-8", newline="\n")
            stderr_target = stderr_handle

        process: subprocess.Popen[str] | None = None
        try:
            process = subprocess.Popen(
                [str(self.config.worker_python), "-m", self.config.worker_module],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=stderr_target,
                text=True,
                encoding="utf-8",
                errors="strict",
                bufsize=1,
                env=environment,
            )
            responses: queue.Queue[Any] = queue.Queue()
            stop_event = threading.Event()
            reader_thread = threading.Thread(
                target=self._reader_loop,
                args=(process, responses, stop_event),
                name="kompress-worker-read",
                daemon=True,
            )
            with self._state_lock:
                self._process = process
                self._responses = responses
                self._reader_stop = stop_event
                self._reader_thread = reader_thread
                self._stderr_handle = stderr_handle
            reader_thread.start()
            line = self._readline(self.config.startup_timeout_seconds)
            try:
                message = json.loads(line)
            except (TypeError, ValueError, UnicodeError) as exc:
                raise RuntimeError("worker_startup_decode_error") from exc
            if not isinstance(message, dict):
                raise RuntimeError("worker_startup_malformed")
            if message.get("type") != "ready" or message.get("ready") is not True:
                raise RuntimeError(_safe_error_code(message.get("error_code"), "worker_not_ready"))
            self.provider = _safe_text(message.get("provider"), "unknown")
            self.backend = _safe_text(message.get("backend"), "unknown")
        except BaseException:
            self._stop_process()
            if process is None and stderr_handle is not None:
                try:
                    stderr_handle.close()
                except (OSError, ValueError):
                    pass
            raise

    def stop(self) -> None:
        self._stop_process()

    def restart(self) -> None:
        self.start()

    def request(self, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
        with self._io_lock:
            with self._state_lock:
                process = self._process
            if process is None or process.stdin is None or process.poll() is not None:
                raise RuntimeError("worker_unavailable")
            try:
                process.stdin.write(json.dumps(payload, ensure_ascii=True, separators=(",", ":")) + "\n")
                process.stdin.flush()
                line = self._readline(timeout)
            except (BrokenPipeError, OSError) as exc:
                raise RuntimeError("worker_crash") from exc
            if not line:
                raise RuntimeError("worker_response_eof")
            try:
                response = json.loads(line)
            except (TypeError, ValueError, UnicodeError) as exc:
                raise RuntimeError("worker_response_decode_error") from exc
            if not isinstance(response, dict):
                raise RuntimeError("worker_response_malformed")
            if str(response.get("id", "")) != str(payload.get("id", "")):
                raise RuntimeError("worker_response_mismatch")
            return response


class BrokerState:
    def __init__(
        self,
        config: BrokerConfig,
        worker_factory: Callable[[BrokerConfig], ProviderWorker] = ProviderWorker,
    ) -> None:
        self.config = config
        self.worker = worker_factory(config)
        self.ready = False
        self.provider: str | None = None
        self.backend: str | None = None
        self.circuit_open = False
        self._capacity = asyncio.Semaphore(config.queue_limit + 1)
        self._worker_lock = asyncio.Lock()
        self._state_lock = threading.Lock()
        self.counters = {
            "total": 0,
            "compressed": 0,
            "passthrough": 0,
            "timeout": 0,
            "queue_full": 0,
            "worker_restart": 0,
            "device_removal": 0,
            "error": 0,
        }

    def _persist(self) -> None:
        path = self.config.state_path
        if path is None:
            return
        document = {
            "schema_version": 1,
            "service": "kompress-broker",
            "ready": self.ready,
            "provider": self.provider,
            "backend": self.backend,
            "circuit_open": self.circuit_open,
            "queue_limit": self.config.queue_limit,
            "counters": dict(self.counters),
        }
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
            try:
                with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
                    json.dump(document, handle, ensure_ascii=True, separators=(",", ":"))
                    handle.write("\n")
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temporary, path)
            finally:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass
        except (OSError, TypeError, ValueError):
            return

    def start(self) -> None:
        self.ready = False
        self.provider = None
        self.backend = None
        self.circuit_open = False
        try:
            self.worker.start()
            canary_payload = {
                "id": uuid.uuid4().hex,
                "op": "compress",
                "content": " ".join(
                    ["Headroom validates Kompress readiness before serving requests."] * 30
                ),
                "target_ratio": 0.5,
            }
            canary = self.worker.request(
                canary_payload,
                self.config.request_timeout_seconds,
            )
            if not _valid_compression_response(canary, expected_id=canary_payload["id"]):
                error_code = _safe_error_code(
                    canary.get("error_code") if isinstance(canary, dict) else None,
                    "canary_failed",
                )
                raise RuntimeError(error_code)
            self.ready = True
            self.provider = _safe_text(getattr(self.worker, "provider", None), "unknown")
            self.backend = _safe_text(getattr(self.worker, "backend", None), "unknown")
            self.circuit_open = False
        except BaseException:
            try:
                self.worker.stop()
            except BaseException:
                pass
            self.ready = False
            self.provider = None
            self.backend = None
        self._persist()

    def stop(self) -> None:
        try:
            self.worker.stop()
        except BaseException:
            pass
        self.ready = False
        self.provider = None
        self.backend = None
        self._persist()

    def passthrough(
        self,
        content: str,
        *,
        reason: str,
        error_code: str,
        latency_ms: float,
    ) -> dict[str, Any]:
        tokens = len(content.split())
        return {
            "compressed": content,
            "original_tokens": tokens,
            "compressed_tokens": tokens,
            "compression_ratio": 1.0,
            "model_used": "chopratejas/kompress-v2-base",
            "provider": self.provider or "none",
            "backend": self.backend,
            "status": "passthrough",
            "fallback_reason": reason,
            "error_code": _safe_error_code(error_code, "provider_error"),
            "latency_ms": round(max(0.0, latency_ms), 3),
        }

    def record(self, name: str) -> None:
        with self._state_lock:
            self.counters["total"] += 1
            self.counters.setdefault(name, 0)
            self.counters[name] += 1
            self._persist()

    def bump(self, name: str) -> None:
        """Update non-request counters without treating them as requests."""

        with self._state_lock:
            self.counters.setdefault(name, 0)
            self.counters[name] += 1
            self._persist()


def _device_loss(error_code: str) -> bool:
    lowered = error_code.lower()
    return any(code in lowered for code in _DEVICE_LOSS_CODES) or (
        "device" in lowered
        and any(marker in lowered for marker in ("loss", "lost", "removed", "removal"))
    )


def _valid_compression_response(response: Any, *, expected_id: str | None = None) -> bool:
    """Validate the small provider envelope before it can affect readiness."""

    if not isinstance(response, dict) or response.get("ok") is not True:
        return False
    compressed = response.get("compressed")
    if not isinstance(compressed, str):
        return False
    response_id = response.get("id")
    if expected_id is not None and response_id is not None and str(response_id) != expected_id:
        return False
    try:
        compressed.encode("utf-8")
    except UnicodeError:
        return False
    return True


def _token_count(value: Any, default: int) -> int | None:
    if value is None:
        return default
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value >= 0 else None
    if isinstance(value, float) and math.isfinite(value) and value.is_integer() and value >= 0:
        return int(value)
    return None


def _normalise_success(
    response: Any,
    content: str,
    state: BrokerState,
    *,
    expected_id: str | None = None,
) -> dict[str, Any] | None:
    if not _valid_compression_response(response, expected_id=expected_id):
        return None
    compressed = response["compressed"]
    original_tokens = _token_count(response.get("original_tokens"), len(content.split()))
    compressed_tokens = _token_count(response.get("compressed_tokens"), len(compressed.split()))
    if original_tokens is None or compressed_tokens is None:
        return None
    compression_ratio = response.get("compression_ratio")
    if compression_ratio is None:
        compression_ratio = (
            compressed_tokens / original_tokens if original_tokens > 0 else 1.0
        )
    elif (
        isinstance(compression_ratio, bool)
        or not isinstance(compression_ratio, (int, float))
        or not math.isfinite(float(compression_ratio))
        or float(compression_ratio) < 0.0
    ):
        return None

    if compressed == content:
        compressed_tokens = min(compressed_tokens, original_tokens)
    result: dict[str, Any] = {
        "ok": True,
        "compressed": compressed,
        "original_tokens": original_tokens,
        "compressed_tokens": compressed_tokens,
        "compression_ratio": float(compression_ratio),
        "model_used": _safe_text(response.get("model_used"), "chopratejas/kompress-v2-base"),
        "provider": _safe_text(response.get("provider"), state.provider or "none"),
        "backend": _safe_text(response.get("backend"), state.backend or "unknown"),
        "status": "compressed" if compressed != content else "passthrough",
        "fallback_reason": None,
        "error_code": None,
    }
    response_id = _safe_text(response.get("id"), "")
    if response_id:
        result["id"] = response_id
    return result


def create_app(
    config: BrokerConfig | None = None,
    worker_factory: Callable[[BrokerConfig], ProviderWorker] = ProviderWorker,
) -> FastAPI:
    cfg = config or BrokerConfig.from_env()
    state = BrokerState(cfg, worker_factory=worker_factory)
    app = FastAPI(title="Kompress Broker", docs_url=None, redoc_url=None)
    app.state.broker = state

    @app.on_event("startup")
    async def startup() -> None:
        # The worker owns its own bounded stdout startup read.  Keep the ASGI
        # startup hook bounded as well when a custom worker factory misbehaves.
        await asyncio.wait_for(
            asyncio.to_thread(state.start),
            timeout=max(cfg.startup_timeout_seconds + 1.0, 2.0),
        )

    @app.on_event("shutdown")
    async def shutdown() -> None:
        await asyncio.wait_for(asyncio.to_thread(state.stop), timeout=5.0)

    @app.get("/livez")
    async def livez() -> dict[str, Any]:
        return {"service": "kompress-broker", "alive": True, "status": "healthy"}

    def health_body() -> dict[str, Any]:
        return {
            "service": "kompress-broker",
            "status": "healthy" if state.ready else "unhealthy",
            "ready": state.ready,
            "provider": state.provider,
            "backend": state.backend,
            "circuit_open": state.circuit_open,
            "queue_limit": cfg.queue_limit,
            "counters": dict(state.counters),
        }

    @app.get("/readyz")
    async def readyz() -> JSONResponse:
        return JSONResponse(status_code=200 if state.ready else 503, content=health_body())

    @app.get("/health")
    async def health() -> JSONResponse:
        return JSONResponse(status_code=200 if state.ready else 503, content=health_body())

    @app.post("/compress")
    async def compress(request: Request) -> JSONResponse:
        started = time.perf_counter()
        try:
            payload = await request.json()
        except Exception:
            return _json_error(400, "invalid_json", "invalid_json")
        if not isinstance(payload, dict) or not isinstance(payload.get("content"), str):
            return _json_error(400, "invalid_request", "content_must_be_string")
        content = payload["content"]
        try:
            content_bytes = len(content.encode("utf-8"))
        except UnicodeEncodeError:
            return _json_error(400, "invalid_request", "content_must_be_utf8")
        if content_bytes > cfg.max_content_bytes:
            return _json_error(413, "request_too_large", "request_too_large")
        ratio = payload.get("target_ratio")
        if ratio is not None:
            if isinstance(ratio, bool):
                return _json_error(400, "invalid_request", "invalid_target_ratio")
            try:
                ratio = float(ratio)
            except (TypeError, ValueError, OverflowError):
                return _json_error(400, "invalid_request", "invalid_target_ratio")
            if not math.isfinite(ratio) or not 0.0 < ratio <= 1.0:
                return _json_error(400, "invalid_request", "invalid_target_ratio")

        try:
            await asyncio.wait_for(state._capacity.acquire(), timeout=cfg.queue_wait_seconds)
        except asyncio.TimeoutError:
            state.record("queue_full")
            body = state.passthrough(
                content,
                reason="queue_full",
                error_code="queue_full",
                latency_ms=(time.perf_counter() - started) * 1000,
            )
            return JSONResponse(status_code=200, content=body)

        worker_lock_acquired = False
        try:
            try:
                await asyncio.wait_for(
                    state._worker_lock.acquire(),
                    timeout=cfg.queue_wait_seconds,
                )
                worker_lock_acquired = True
            except asyncio.TimeoutError:
                state.record("queue_full")
                return JSONResponse(
                    status_code=200,
                    content=state.passthrough(
                        content,
                        reason="queue_full",
                        error_code="queue_full",
                        latency_ms=(time.perf_counter() - started) * 1000,
                    ),
                )
            if not state.ready or state.circuit_open:
                state.record("passthrough")
                return JSONResponse(
                    status_code=200,
                    content=state.passthrough(
                        content,
                        reason="provider_not_ready",
                        error_code="provider_not_ready",
                        latency_ms=(time.perf_counter() - started) * 1000,
                    ),
                )
            worker_payload = {
                "id": uuid.uuid4().hex,
                "op": "compress",
                "content": content,
                "target_ratio": ratio,
            }
            try:
                response = await asyncio.wait_for(
                    asyncio.to_thread(state.worker.request, worker_payload, cfg.request_timeout_seconds),
                    timeout=cfg.request_timeout_seconds,
                )
            except (asyncio.TimeoutError, TimeoutError):
                state.record("timeout")
                state.ready = False
                state.provider = None
                state.backend = None
                try:
                    await asyncio.wait_for(asyncio.to_thread(state.worker.stop), timeout=3.0)
                except Exception:
                    pass
                state.bump("worker_restart")
                return JSONResponse(
                    status_code=200,
                    content=state.passthrough(
                        content,
                        reason="provider_timeout",
                        error_code="provider_timeout",
                        latency_ms=(time.perf_counter() - started) * 1000,
                    ),
                )
            except Exception as exc:
                state.record("error")
                state.ready = False
                state.provider = None
                state.backend = None
                try:
                    await asyncio.wait_for(asyncio.to_thread(state.worker.stop), timeout=3.0)
                except Exception:
                    pass
                state.bump("worker_restart")
                failure_code = _request_failure_code(exc)
                return JSONResponse(
                    status_code=200,
                    content=state.passthrough(
                        content,
                        reason="worker_error" if failure_code == "worker_error" else failure_code,
                        error_code=failure_code,
                        latency_ms=(time.perf_counter() - started) * 1000,
                    ),
                )

            normalized = _normalise_success(
                response,
                content,
                state,
                expected_id=worker_payload["id"],
            )
            if normalized is None:
                raw_error_code = response.get("error_code") if isinstance(response, dict) else None
                error_code = _safe_error_code(raw_error_code, "malformed_output")
                if _device_loss(error_code):
                    state.circuit_open = True
                    state.ready = False
                    state.provider = None
                    state.backend = None
                    state.bump("device_removal")
                    try:
                        await asyncio.wait_for(asyncio.to_thread(state.worker.stop), timeout=3.0)
                    except Exception:
                        pass
                state.record("error")
                return JSONResponse(
                    status_code=200,
                    content=state.passthrough(
                        content,
                        reason="provider_error",
                        error_code=error_code,
                        latency_ms=(time.perf_counter() - started) * 1000,
                    ),
                )
            normalized["latency_ms"] = round((time.perf_counter() - started) * 1000, 3)
            state.record("compressed" if normalized["status"] == "compressed" else "passthrough")
            return JSONResponse(status_code=200, content=normalized)
        finally:
            if worker_lock_acquired:
                state._worker_lock.release()
            state._capacity.release()

    # FastAPI versions before 0.115 exposed ``router.startup()`` and
    # ``router.shutdown()``; newer versions retain the handler lists but
    # removed those convenience methods.  Keep the in-process contract stable
    # for contract tests and embedding callers without changing ASGI lifespan.
    if not hasattr(app.router, "startup"):
        async def _compat_startup() -> None:
            for handler in app.router.on_startup:
                result = handler()
                if inspect.isawaitable(result):
                    await result

        setattr(app.router, "startup", _compat_startup)
    if not hasattr(app.router, "shutdown"):
        async def _compat_shutdown() -> None:
            for handler in app.router.on_shutdown:
                result = handler()
                if inspect.isawaitable(result):
                    await result

        setattr(app.router, "shutdown", _compat_shutdown)

    return app


app = create_app()

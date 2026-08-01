"""Local policy gateway for the Headroom -> helper chain.

The gateway is deliberately the only request hop exposed to clients.  It
classifies the request, applies the local compression policy, and forwards
``/v1/*`` traffic to Headroom.  Only an explicit pre-connect failure may
switch to the helper without replaying a request that could already have been
delivered.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import math
import os
import socket
import tempfile
import threading
import time
from datetime import datetime, timezone
from dataclasses import dataclass
from pathlib import Path
from typing import Any, AsyncIterator, Mapping
from urllib.parse import urlsplit

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse


_HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}
_INTERNAL_POLICY_HEADERS = {"x-headroom-bypass", "x-headroom-mode"}
_DEFAULT_STATE_NAME = "gateway-metrics-state.json"
_TURN_METADATA_HEADER = "x-codex-turn-metadata"
_CLASSIFICATION_DIAGNOSTICS = (
    "malformed_turn_metadata",
    "unknown_turn_metadata",
    "missing_parent_thread_id",
)
_CACHE_SEGMENT_KEYS = ("model", "instructions", "system", "tools", "input", "messages")


def _float_env(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = float(raw)
    except ValueError:
        return default
    return value if math.isfinite(value) and 0.001 <= value <= 3600.0 else default


def _base_url(raw: str, *, name: str) -> str:
    value = raw.strip().rstrip("/")
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError(f"{name} must be an HTTP URL without credentials")
    if parsed.hostname.lower() not in {"127.0.0.1", "localhost", "::1"}:
        raise ValueError(f"{name} must point to a loopback service")
    if parsed.query or parsed.fragment:
        raise ValueError(f"{name} must not contain a query or fragment")
    return value


@dataclass(frozen=True)
class GatewayConfig:
    """Runtime configuration.  Defaults form the production local chain."""

    headroom_url: str = "http://127.0.0.1:18789"
    helper_url: str = "http://127.0.0.1:57321"
    connect_timeout: float = 2.0
    read_timeout: float = 120.0
    total_timeout: float = 300.0
    state_path: Path = Path(__file__).with_name(_DEFAULT_STATE_NAME)

    @classmethod
    def from_env(cls) -> "GatewayConfig":
        state_raw = os.environ.get("POLICY_GATEWAY_STATE_PATH", "").strip()
        state_path = Path(state_raw) if state_raw else Path(__file__).with_name(_DEFAULT_STATE_NAME)
        return cls(
            headroom_url=_base_url(os.environ.get("HEADROOM_URL", cls.headroom_url), name="HEADROOM_URL"),
            helper_url=_base_url(os.environ.get("HELPER_URL", cls.helper_url), name="HELPER_URL"),
            connect_timeout=_float_env("POLICY_GATEWAY_CONNECT_TIMEOUT", cls.connect_timeout),
            read_timeout=_float_env("POLICY_GATEWAY_READ_TIMEOUT", cls.read_timeout),
            total_timeout=_float_env("POLICY_GATEWAY_TOTAL_TIMEOUT", cls.total_timeout),
            state_path=state_path,
        )


def _header_value(headers: Mapping[str, str], name: str) -> str | None:
    wanted = name.lower()
    for key, value in headers.items():
        if key.lower() == wanted:
            return value
    return None


def _body_json(body: bytes) -> dict[str, Any] | None:
    if not body:
        return None
    try:
        parsed = json.loads(body)
    except Exception:
        # Body inspection is diagnostic only.  A malformed or deeply nested
        # payload must continue upstream unchanged instead of becoming a 5xx.
        return None
    return parsed if isinstance(parsed, dict) else None


def _metadata_payload(headers: Mapping[str, str]) -> tuple[dict[str, Any] | None, str | None]:
    """Parse turn metadata while keeping malformed values out of metrics."""

    raw = _header_value(headers, _TURN_METADATA_HEADER)
    if raw is None:
        return None, None
    if not raw.strip():
        return None, "malformed_turn_metadata"
    try:
        payload = json.loads(raw)
    except Exception:
        return None, "malformed_turn_metadata"
    if not isinstance(payload, dict):
        return None, "unknown_turn_metadata"
    kind = payload.get("subagent_kind")
    parent = payload.get("parent_thread_id")
    if kind is not None and not isinstance(kind, str):
        return payload, "unknown_turn_metadata"
    if parent is not None and not isinstance(parent, str):
        return payload, "unknown_turn_metadata"
    if kind is not None and str(kind).strip().lower() not in {"", "thread_spawn"}:
        return payload, "unknown_turn_metadata"
    if kind and str(kind).strip().lower() == "thread_spawn" and not str(parent or "").strip():
        return payload, "missing_parent_thread_id"
    return payload, None


def classify_request(headers: Mapping[str, str], body: bytes) -> tuple[bool, str, str | None]:
    """Return spawned/main, source category, and a safe diagnostic code.

    Native Codex metadata is authoritative only when both spawn kind and a
    non-empty parent are present.  Legacy signals remain compatible, while
    ``thread_source`` and body-only fields never grant bypass on their own.
    """

    metadata, diagnostic = _metadata_payload(headers)
    # A payload carrying a parser diagnostic is never eligible for bypass. In
    # particular, non-string parent IDs must not be coerced into a bypass
    # signal merely because their string form is non-empty. The damaged
    # metadata is authoritative for this safety decision: fail closed to the
    # main/compress path rather than letting a weaker legacy signal upgrade it.
    if diagnostic is not None:
        return False, "main", diagnostic
    if metadata:
        kind = str(metadata.get("subagent_kind", "")).strip().lower()
        parent = str(metadata.get("parent_thread_id", "")).strip()
        if kind == "thread_spawn" and parent:
            return True, "turn_metadata", diagnostic

    openai_subagent = (_header_value(headers, "x-openai-subagent") or "").strip().lower()
    if openai_subagent == "collab_spawn":
        return True, "collab_spawn", diagnostic
    if openai_subagent and openai_subagent not in {"false", "0", "no", "off"} and diagnostic is None:
        diagnostic = "unknown_turn_metadata"

    kind = (_header_value(headers, "subagent_kind") or "").strip().lower()
    parent = (_header_value(headers, "x-codex-parent-thread-id") or "").strip()
    if kind == "thread_spawn" and parent:
        return True, "legacy_parent_header", diagnostic
    if kind == "thread_spawn" and diagnostic is None:
        diagnostic = "missing_parent_thread_id"

    return False, "main", diagnostic


def is_spawned_request(headers: Mapping[str, str], body: bytes) -> bool:
    """Compatibility wrapper for callers that only need the class."""

    return classify_request(headers, body)[0]


def _request_category(path: str) -> str:
    normalized = path.rstrip("/").lower()
    if normalized.endswith("/responses"):
        return "responses"
    if normalized.endswith("/chat/completions"):
        return "chat_completions"
    if normalized.endswith("/completions"):
        return "completions"
    return "v1_other"


def _request_hash(method: str, path: str, body: bytes) -> str:
    digest = hashlib.sha256()
    digest.update(method.encode("utf-8", "replace"))
    digest.update(b"\0")
    digest.update(path.encode("utf-8", "replace"))
    digest.update(b"\0")
    digest.update(body)
    return digest.hexdigest()[:32]


def _safe_json_hash(value: Any) -> str:
    try:
        encoded = json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode("utf-8")
    except (TypeError, ValueError):
        encoded = repr(type(value)).encode("ascii", "replace")
    return hashlib.sha256(encoded).hexdigest()[:16]


def _cache_segments(body: bytes) -> list[dict[str, str]]:
    payload = _body_json(body)
    if payload is None:
        return []
    segments: list[dict[str, str]] = []
    for key in _CACHE_SEGMENT_KEYS:
        if key in payload:
            segments.append({"key": key, "hash": _safe_json_hash(payload[key])})
    return segments


def _transform_names(headers: Mapping[str, str]) -> list[str]:
    raw = _header_value(headers, "x-headroom-transforms") or ""
    names: list[str] = []
    for value in raw.split(",")[:32]:
        safe = "".join(char for char in value.strip() if char.isalnum() or char in "._:-")[:64]
        if safe:
            names.append(safe)
    return names


def _cache_flag(headers: Mapping[str, str]) -> bool | None:
    value = (_header_value(headers, "x-headroom-cached") or "").strip().lower()
    if value in {"1", "true", "yes", "hit", "cached"}:
        return True
    if value in {"0", "false", "no", "miss", "uncached"}:
        return False
    return None


def _target_url(base: str, request: Request) -> str:
    query = request.url.query
    return f"{base}{request.url.path}" + (f"?{query}" if query else "")


def _forward_headers(incoming: Mapping[str, str], *, spawned: bool) -> dict[str, str]:
    result: dict[str, str] = {}
    for key, value in incoming.items():
        lowered = key.lower()
        if lowered in _HOP_BY_HOP_HEADERS or lowered in _INTERNAL_POLICY_HEADERS:
            continue
        result[key] = value
    if spawned:
        # Headroom consumes this control flag and strips it before the helper.
        result["x-headroom-bypass"] = "true"
    return result


def _response_headers(headers: Mapping[str, str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for key, value in headers.items():
        lowered = key.lower()
        if lowered in _HOP_BY_HOP_HEADERS or lowered in {
            "server",
            "authorization",
            "proxy-authorization",
            "set-cookie",
        } or lowered in _INTERNAL_POLICY_HEADERS:
            continue
        result[key] = value
    return result


def _token_metrics(headers: Mapping[str, str]) -> dict[str, int] | None:
    result: dict[str, int] = {}
    invalid = False
    for output_name, header_name in (
        ("before", "x-headroom-tokens-before"),
        ("after", "x-headroom-tokens-after"),
        ("saved", "x-headroom-tokens-saved"),
    ):
        raw = _header_value(headers, header_name)
        if raw is None:
            continue
        try:
            value = int(raw)
            if value < 0:
                invalid = True
            result[output_name] = value
        except (TypeError, ValueError):
            continue
    if invalid:
        result["_invalid"] = 1
    return result or None


def _usage_metrics(headers: Mapping[str, str]) -> tuple[dict[str, int] | None, str]:
    """Read an explicit upstream usage contract without guessing totals.

    Headroom may expose usage as a JSON response header for streaming
    responses.  Missing or malformed usage is deliberately represented as
    ``null`` with a stable reason instead of estimating from token headers.
    """

    raw = (
        _header_value(headers, "x-headroom-upstream-usage")
        or _header_value(headers, "x-headroom-usage")
        or _header_value(headers, "x-upstream-usage")
    )
    if not raw:
        return None, "upstream_usage_unavailable"
    try:
        parsed = json.loads(raw)
    except (TypeError, ValueError, json.JSONDecodeError):
        return None, "upstream_usage_unavailable"
    if not isinstance(parsed, Mapping):
        return None, "upstream_usage_unavailable"
    usage: dict[str, int] = {}
    for name in ("input", "output", "total", "prompt_tokens", "completion_tokens", "total_tokens"):
        value = parsed.get(name)
        if isinstance(value, bool):
            continue
        try:
            normalized = int(value)
        except (TypeError, ValueError, OverflowError):
            continue
        if normalized >= 0:
            usage[name] = normalized
    return (usage or None), ("upstream_usage" if usage else "upstream_usage_unavailable")


class MetricsStore:
    """Small atomic JSON state store safe for the monitor to read."""

    def __init__(self, path: Path, *, recent_limit: int = 100) -> None:
        self.path = path
        try:
            normalized_limit = int(recent_limit)
        except (TypeError, ValueError):
            normalized_limit = 100
        self.recent_limit = max(1, min(normalized_limit, 10_000))
        self._lock = threading.Lock()
        self._prefix_baselines: dict[tuple[str, str], list[dict[str, str]]] = {}
        self._state: dict[str, Any] = {
            "schema_version": 2,
            "service": "policy-gateway",
            "updated_at": None,
            "counters": {"total": 0, "ok": 0, "error": 0, "timeout": 0},
            "by_request_class": {
                "main": {"total": 0, "ok": 0, "error": 0, "timeout": 0},
                "spawned": {"total": 0, "ok": 0, "error": 0, "timeout": 0},
            },
            "by_policy": {
                "compress": {"total": 0, "ok": 0, "error": 0, "timeout": 0},
                "bypass": {"total": 0, "ok": 0, "error": 0, "timeout": 0},
            },
            "usage_contract": {"status": "upstream_usage_unavailable", "known": False},
            "classification_diagnostics": {name: 0 for name in _CLASSIFICATION_DIAGNOSTICS},
            "token_accounting": {
                "input_before": 0,
                "input_after": 0,
                "saved": 0,
                "completed_samples": 0,
                "missing_samples": 0,
                "invalid_samples": 0,
            },
            "recent": [],
        }
        self._load()
        if not self.path.exists():
            self._write_locked()

    def _load(self) -> None:
        try:
            loaded = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return
        if not isinstance(loaded, dict):
            return
        counters = loaded.get("counters")
        if isinstance(counters, dict):
            for name in ("total", "ok", "error", "timeout"):
                self._state["counters"][name] = self._nonnegative_int(counters.get(name), 0)
        for group_name in ("by_request_class", "by_policy"):
            groups = loaded.get(group_name)
            if not isinstance(groups, Mapping):
                continue
            for name in self._state[group_name]:
                source = groups.get(name)
                if not isinstance(source, Mapping):
                    continue
                for counter in ("total", "ok", "error", "timeout"):
                    self._state[group_name][name][counter] = self._nonnegative_int(source.get(counter), 0)
        diagnostics = loaded.get("classification_diagnostics")
        if isinstance(diagnostics, Mapping):
            for name in _CLASSIFICATION_DIAGNOSTICS:
                self._state["classification_diagnostics"][name] = self._nonnegative_int(diagnostics.get(name), 0)
        token_accounting = loaded.get("token_accounting")
        if isinstance(token_accounting, Mapping):
            for name in ("input_before", "input_after", "saved", "completed_samples", "missing_samples", "invalid_samples"):
                self._state["token_accounting"][name] = self._nonnegative_int(token_accounting.get(name), 0)
            token_state = self._state["token_accounting"]
            aggregate_fields = ("input_before", "input_after", "saved")
            aggregate_present = all(name in token_accounting for name in aggregate_fields)
            raw_values_valid = True
            for name in ("input_before", "input_after", "saved", "completed_samples", "missing_samples", "invalid_samples"):
                if name not in token_accounting:
                    continue
                raw_value = token_accounting.get(name)
                try:
                    parsed_value = int(raw_value)
                except (TypeError, ValueError, OverflowError):
                    parsed_value = -1
                if isinstance(raw_value, bool) or parsed_value < 0 or str(parsed_value) != str(raw_value).strip():
                    raw_values_valid = False
            if token_state["completed_samples"] > 0 and not aggregate_present:
                token_state["missing_samples"] = max(token_state["missing_samples"], 1)
            if not raw_values_valid or (
                aggregate_present
                and (
                    token_state["input_after"] > token_state["input_before"]
                    or token_state["saved"] != token_state["input_before"] - token_state["input_after"]
                )
            ):
                token_state["invalid_samples"] = max(token_state["invalid_samples"], 1)
        updated_at = loaded.get("updated_at")
        if updated_at is None or isinstance(updated_at, str):
            self._state["updated_at"] = updated_at
        recent = loaded.get("recent")
        if isinstance(recent, list):
            self._state["recent"] = [
                normalized for item in recent
                if (normalized := self._normalize_metric(item)) is not None
            ][-self.recent_limit :]

    @staticmethod
    def _nonnegative_int(value: Any, default: int = 0) -> int:
        if isinstance(value, bool):
            return default
        try:
            normalized = int(value)
        except (TypeError, ValueError, OverflowError):
            return default
        return normalized if normalized >= 0 else default

    @staticmethod
    def _strict_nonnegative_int(value: Any) -> tuple[int | None, bool]:
        """Parse a token field without turning malformed data into zero."""

        if isinstance(value, bool) or value is None:
            return None, True
        if isinstance(value, int):
            return (value, False) if value >= 0 else (None, True)
        if isinstance(value, str):
            text = value.strip()
            if not text or not text.isdigit():
                return None, True
            try:
                return int(text), False
            except ValueError:
                return None, True
        return None, True

    @classmethod
    def _normalize_metric(cls, metric: Any) -> dict[str, Any] | None:
        if not isinstance(metric, Mapping):
            return None
        source = str(metric.get("classification_source", "main")).lower()
        if source not in {"main", "turn_metadata", "collab_spawn", "openai_subagent", "legacy_parent_header"}:
            source = "main"
        diagnostic = str(metric.get("classification_diagnostic", ""))
        if diagnostic not in _CLASSIFICATION_DIAGNOSTICS:
            diagnostic = None
        normalized: dict[str, Any] = {
            "hash": str(metric.get("hash", ""))[:128],
            "category": str(metric.get("category", ""))[:64],
            "policy": str(metric.get("policy", ""))[:64],
            "result": str(metric.get("result", "error"))[:64] or "error",
            "request_class": "spawned" if str(metric.get("request_class", "main")).lower() == "spawned" else "main",
            "policy_mode": "bypass" if str(metric.get("policy_mode", "compress")).lower() == "bypass" else "compress",
            "classification_source": source,
            "classification_diagnostic": diagnostic,
            "fallback": str(metric.get("fallback", ""))[:64] or None,
        }
        token = metric.get("token")
        if isinstance(token, Mapping):
            token_values: dict[str, int] = {}
            token_invalid = bool(token.get("_invalid"))
            for name in ("before", "after", "saved"):
                if name in token:
                    parsed, invalid = cls._strict_nonnegative_int(token.get(name))
                    token_invalid = token_invalid or invalid
                    if parsed is not None:
                        token_values[name] = parsed
            normalized["token"] = token_values or None
            normalized["token_invalid"] = token_invalid
        else:
            normalized["token"] = None
            normalized["token_invalid"] = False
        latency = metric.get("latency_ms")
        try:
            latency_value = float(latency) if latency is not None else None
        except (TypeError, ValueError, OverflowError):
            latency_value = None
        normalized["latency_ms"] = latency_value if latency_value is not None and math.isfinite(latency_value) and latency_value >= 0 else None
        usage = metric.get("usage")
        if isinstance(usage, Mapping):
            usage_values: dict[str, int] = {}
            for name in ("input", "output", "total", "prompt_tokens", "completion_tokens", "total_tokens"):
                if name in usage:
                    parsed = cls._nonnegative_int(usage.get(name), -1)
                    if parsed >= 0:
                        usage_values[name] = parsed
            normalized["usage"] = usage_values or None
        else:
            normalized["usage"] = None
        usage_status = str(metric.get("usage_status", "upstream_usage_unavailable"))[:64]
        normalized["usage_status"] = usage_status or "upstream_usage_unavailable"
        observation = metric.get("cache_observation")
        if isinstance(observation, Mapping):
            safe_segments: list[dict[str, str]] = []
            raw_segments = observation.get("segment_hashes", [])
            if not isinstance(raw_segments, (list, tuple)):
                raw_segments = []
            for segment in raw_segments:
                if not isinstance(segment, Mapping):
                    continue
                key = str(segment.get("key", ""))[:32]
                value = str(segment.get("hash", ""))[:32]
                if key and value:
                    safe_segments.append({"key": key, "hash": value})
            normalized["cache_observation"] = {
                "input_size_bytes": cls._nonnegative_int(observation.get("input_size_bytes"), 0),
                "prefix_hash": str(observation.get("prefix_hash", ""))[:32] or None,
                "segment_hashes": safe_segments[:32],
                "first_change_index": cls._nonnegative_int(observation.get("first_change_index"), 0)
                if observation.get("first_change_index") is not None else None,
                "transforms": [str(item)[:64] for item in (observation.get("transforms", []) if isinstance(observation.get("transforms", []), (list, tuple)) else []) if str(item)[:64]][:32],
                "cached": observation.get("cached") if isinstance(observation.get("cached"), bool) else None,
            }
        else:
            normalized["cache_observation"] = None
        return normalized

    def observe_cache_prefix(
        self,
        request_class: str,
        category: str,
        segments: list[dict[str, str]],
    ) -> dict[str, Any]:
        key = (request_class, category)
        with self._lock:
            previous = self._prefix_baselines.get(key)
            first_change = None
            if previous is not None:
                limit = min(len(previous), len(segments))
                first_change = next(
                    (index for index in range(limit) if previous[index] != segments[index]),
                    limit if len(previous) != len(segments) else None,
                )
            self._prefix_baselines[key] = list(segments)
        canonical = "|".join(f"{item['key']}={item['hash']}" for item in segments)
        return {
            "prefix_hash": hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16] if canonical else None,
            "segment_hashes": segments,
            "first_change_index": first_change,
        }

    def record(self, metric: dict[str, Any]) -> None:
        now = time.time()
        safe_metric = self._normalize_metric(metric) or self._normalize_metric({})
        assert safe_metric is not None
        with self._lock:
            counters = self._state["counters"]
            counters["total"] = self._nonnegative_int(counters.get("total"), 0) + 1
            result = safe_metric["result"]
            if result == "ok":
                counters["ok"] = self._nonnegative_int(counters.get("ok"), 0) + 1
            elif result == "timeout":
                counters["timeout"] = self._nonnegative_int(counters.get("timeout"), 0) + 1
            else:
                counters["error"] = self._nonnegative_int(counters.get("error"), 0) + 1
            request_class = safe_metric["request_class"]
            policy_mode = safe_metric["policy_mode"]
            class_counters = self._state["by_request_class"][request_class]
            policy_counters = self._state["by_policy"][policy_mode]
            for bucket in (class_counters, policy_counters):
                bucket["total"] = self._nonnegative_int(bucket.get("total"), 0) + 1
                if result == "ok":
                    bucket["ok"] = self._nonnegative_int(bucket.get("ok"), 0) + 1
                elif result == "timeout":
                    bucket["timeout"] = self._nonnegative_int(bucket.get("timeout"), 0) + 1
                else:
                    bucket["error"] = self._nonnegative_int(bucket.get("error"), 0) + 1
            diagnostic = safe_metric.get("classification_diagnostic")
            if diagnostic in self._state["classification_diagnostics"]:
                diagnostics = self._state["classification_diagnostics"]
                diagnostics[diagnostic] = self._nonnegative_int(diagnostics.get(diagnostic), 0) + 1
            token = safe_metric.get("token")
            token_accounting = self._state["token_accounting"]
            if safe_metric.get("token_invalid"):
                token_accounting["invalid_samples"] = self._nonnegative_int(token_accounting.get("invalid_samples"), 0) + 1
            elif not isinstance(token, Mapping) or not all(name in token for name in ("before", "after", "saved")):
                token_accounting["missing_samples"] = self._nonnegative_int(token_accounting.get("missing_samples"), 0) + 1
            else:
                before = token["before"]
                after = token["after"]
                saved = token["saved"]
                if after > before or saved != before - after:
                    token_accounting["invalid_samples"] = self._nonnegative_int(token_accounting.get("invalid_samples"), 0) + 1
                else:
                    token_accounting["completed_samples"] = self._nonnegative_int(token_accounting.get("completed_samples"), 0) + 1
                    token_accounting["input_before"] = self._nonnegative_int(token_accounting.get("input_before"), 0) + before
                    token_accounting["input_after"] = self._nonnegative_int(token_accounting.get("input_after"), 0) + after
                    token_accounting["saved"] = self._nonnegative_int(token_accounting.get("saved"), 0) + saved
            usage_known = safe_metric.get("usage") is not None
            self._state["usage_contract"] = {
                "status": "upstream_usage" if usage_known else "upstream_usage_unavailable",
                "known": usage_known,
            }
            recent = self._state.setdefault("recent", [])
            recent.append(safe_metric)
            del recent[:-self.recent_limit]
            self._state["updated_at"] = datetime.fromtimestamp(now, tz=timezone.utc).isoformat().replace("+00:00", "Z")
            self._write_locked()

    def _write_locked(self) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix=f".{self.path.name}.", dir=str(self.path.parent))
            try:
                with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
                    json.dump(self._state, handle, ensure_ascii=True, separators=(",", ":"))
                    handle.write("\n")
                    handle.flush()
                    os.fsync(handle.fileno())
                os.replace(temporary, self.path)
            finally:
                try:
                    os.unlink(temporary)
                except FileNotFoundError:
                    pass
        except (OSError, TypeError, ValueError):
            # Metrics must never break the request path.
            return


async def _tcp_probe(url: str, timeout: float) -> bool:
    parsed = urlsplit(url)
    if not parsed.hostname or parsed.port is None:
        return False

    def connect() -> bool:
        try:
            with socket.create_connection((parsed.hostname, parsed.port), timeout=timeout):
                return True
        except OSError:
            return False

    return await asyncio.to_thread(connect)


async def _http_probe(client: httpx.AsyncClient, base: str, timeout: float) -> tuple[bool, int | None]:
    try:
        response = await client.get(f"{base}/health", timeout=timeout)
        if 200 <= response.status_code < 300:
            return True, response.status_code
        # Some local helpers expose no HTTP health route.  A live TCP port is
        # still a useful dependency check, while a stopped process fails both.
        if response.status_code == 404:
            return await _tcp_probe(base, timeout), response.status_code
        return False, response.status_code
    except httpx.HTTPError:
        return False, None


def _stable_error(status_code: int, error_type: str) -> JSONResponse:
    return JSONResponse(
        status_code=status_code,
        content={"error": {"type": error_type, "message": f"policy_gateway_{error_type}"}},
        headers={"cache-control": "no-store"},
    )


def _is_preconnect_failure(error: BaseException) -> bool:
    """Return whether the transport explicitly guarantees no request bytes sent.

    A helper retry is safe only for failures that occur before a connection can
    carry the request.  ``ConnectError``/``ConnectTimeout`` are HTTPX's
    pre-connect failures; ``PoolTimeout`` also means no connection was acquired.
    Read/write/overall timeouts and other transport errors may happen after a
    non-idempotent POST was delivered, so they must never trigger a replay.
    """

    return isinstance(error, (httpx.ConnectError, httpx.ConnectTimeout, httpx.PoolTimeout))


async def _aclose_quietly(resource: Any) -> None:
    """Close an upstream resource without turning cleanup into a request error."""

    try:
        await resource.aclose()
    except Exception:
        # Cleanup is best effort.  In particular, a diagnostic/close failure
        # must not replace an already-started upstream response or cancellation.
        return


def _record_metric_quietly(metrics: MetricsStore, metric: dict[str, Any]) -> None:
    """Persist telemetry without coupling its failure to the request path."""

    try:
        metrics.record(metric)
    except Exception:
        # Metrics are advisory and must never turn a valid upstream response
        # into a gateway failure.
        return


_SSE_PROBE_LIMIT = 64 * 1024


def _sse_terminal_state(buffer: bytes) -> str | None:
    """Return the terminal Responses SSE state, if one is present.

    The probe is deliberately bounded and lossy only for diagnostics. The
    original bytes are always forwarded unchanged; this prevents a parser
    failure from becoming a second stream failure.
    """
    try:
        text = buffer.decode("utf-8", errors="replace")
        event_name: str | None = None
        for line in text.splitlines():
            if line.startswith("event:"):
                event_name = line[6:].strip().lower() or None
                continue
            if not line.startswith("data:"):
                continue
            payload_text = line[5:].strip()
            if payload_text == "[DONE]":
                return "completed"
            try:
                payload = json.loads(payload_text)
            except Exception:
                event_name = None
                continue
            payload_type = payload.get("type") if isinstance(payload, dict) else None
            terminal_type = payload_type if payload_type in {"response.completed", "response.failed"} else event_name
            if terminal_type in {"response.completed", "response.failed"}:
                return "completed" if terminal_type == "response.completed" else "failed"
            event_name = None
    except Exception:
        # The probe is strictly advisory.  Any decode/parser failure must
        # leave the original bytes eligible for direct streaming.
        return None
    return None


def _response_failed_event(reason: str) -> bytes:
    """Build a small terminal Responses event without leaking upstream data."""
    payload = {
        "type": "response.failed",
        "response": {
            "status": "failed",
            "error": {
                "code": reason,
                "message": f"policy_gateway_{reason}",
            },
        },
    }
    return f"event: response.failed\ndata: {json.dumps(payload, separators=(',', ':'))}\n\n".encode(
        "utf-8"
    )


def _compression_passthrough(body: bytes, *, reason: str) -> JSONResponse:
    """Return an explicit no-op result for the diagnostic compress endpoint.

    ``/v1/compress`` is an internal contract probe, not the upstream model
    protocol.  If Headroom cannot run its compressor, preserving the payload
    with zero token claims is the only honest fail-open response; callers of
    the real Responses API only use the helper when a pre-connect failure
    explicitly guarantees that the original request was not sent.
    """

    payload = _body_json(body) or {}
    result = dict(payload)
    result.update(
        {
            "tokens_before": 0,
            "tokens_after": 0,
            "tokens_saved": 0,
            "compression_ratio": 1.0,
            "transforms_applied": [],
            "transforms_summary": [],
            "passthrough": True,
            "passthrough_reason": reason[:64],
        }
    )
    return JSONResponse(status_code=200, content=result)


def create_app(config: GatewayConfig | None = None) -> FastAPI:
    cfg = config or GatewayConfig.from_env()
    metrics = MetricsStore(cfg.state_path)
    app = FastAPI(title="Policy Gateway", docs_url=None, redoc_url=None)
    app.state.config = cfg
    app.state.metrics = metrics

    @app.get("/livez")
    async def livez() -> dict[str, Any]:
        # Liveness intentionally describes this process only.
        return {"service": "policy-gateway", "status": "healthy", "alive": True}

    @app.get("/health")
    async def health() -> JSONResponse:
        # Headroom's readiness check includes dependency probes and can take
        # longer than a normal request connect timeout. Keep this diagnostic
        # endpoint bounded without turning a healthy, slow probe into 503.
        # Health is also queried while the single local compression worker is
        # busy. A short probe timeout turns harmless CPU contention into a
        # false red route state, so keep it bounded but above the measured
        # Kompress warm/cold path.
        timeout = min(max(cfg.connect_timeout, 15.0), 30.0)
        probe_timeout = httpx.Timeout(timeout=timeout)
        async with httpx.AsyncClient(timeout=probe_timeout, follow_redirects=False) as client:
            headroom_task = _http_probe(client, cfg.headroom_url, timeout)
            helper_task = _http_probe(client, cfg.helper_url, timeout)
            (headroom_ok, headroom_status), (helper_ok, helper_status) = await asyncio.gather(headroom_task, helper_task)
        ready = headroom_ok and helper_ok
        body = {
            "service": "policy-gateway",
            "status": "healthy" if ready else "degraded",
            "ready": ready,
            "checks": {
                "headroom": {"ok": headroom_ok, "status_code": headroom_status, "port": urlsplit(cfg.headroom_url).port},
                "helper": {"ok": helper_ok, "status_code": helper_status, "port": urlsplit(cfg.helper_url).port},
            },
        }
        return JSONResponse(status_code=200 if ready else 503, content=body)

    async def forward(request: Request) -> StreamingResponse | JSONResponse:
        started = time.monotonic()
        body = await request.body()
        spawned, classification_source, classification_diagnostic = classify_request(request.headers, body)
        policy = "spawned_bypass" if spawned else "main_compress"
        request_class = "spawned" if spawned else "main"
        policy_mode = "bypass" if spawned else "compress"
        category = _request_category(request.url.path)
        request_hash = _request_hash(request.method, request.url.path, body)
        metric_base = {
            "hash": request_hash,
            "category": category,
            "policy": policy,
            "request_class": request_class,
            "policy_mode": policy_mode,
            "classification_source": classification_source,
            "classification_diagnostic": classification_diagnostic,
            "token": None,
            "usage": None,
            "usage_status": "upstream_usage_unavailable",
            "latency_ms": None,
            "result": "error",
        }
        segments = _cache_segments(body)
        cache_observation = metrics.observe_cache_prefix(request_class, category, segments)
        cache_observation["input_size_bytes"] = len(body)
        cache_observation["transforms"] = []
        cache_observation["cached"] = None
        metric_base["cache_observation"] = cache_observation
        headers = _forward_headers(request.headers, spawned=spawned)
        timeout = httpx.Timeout(
            connect=cfg.connect_timeout,
            read=cfg.read_timeout,
            write=cfg.read_timeout,
            pool=cfg.connect_timeout,
        )
        client = httpx.AsyncClient(timeout=timeout, follow_redirects=False)
        upstream: httpx.Response | None = None
        deadline = time.monotonic() + cfg.total_timeout

        async def send_to(base_url: str, active_client: httpx.AsyncClient) -> httpx.Response:
            outbound = active_client.build_request(
                request.method,
                _target_url(base_url, request),
                headers=headers,
                content=body,
            )
            remaining = max(0.001, deadline - time.monotonic())
            return await asyncio.wait_for(active_client.send(outbound, stream=True), timeout=remaining)

        fallback_reason: str | None = None

        async def try_helper_fallback(reason: str) -> bool:
            """Retry the uncompressed request against the original helper."""

            nonlocal client, upstream, fallback_reason
            fallback_reason = reason
            await _aclose_quietly(client)
            client = httpx.AsyncClient(timeout=timeout, follow_redirects=False)
            try:
                upstream = await send_to(cfg.helper_url, client)
                return True
            except asyncio.CancelledError:
                await _aclose_quietly(client)
                raise
            except (asyncio.TimeoutError, httpx.TimeoutException):
                await _aclose_quietly(client)
                metric_base["result"] = "timeout"
                metric_base["fallback"] = fallback_reason
                metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
                _record_metric_quietly(metrics, metric_base)
                return False
            except httpx.HTTPError:
                await _aclose_quietly(client)
                metric_base["result"] = "upstream_unavailable"
                metric_base["fallback"] = fallback_reason
                metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
                _record_metric_quietly(metrics, metric_base)
                return False
            except Exception:
                await _aclose_quietly(client)
                metric_base["result"] = "upstream_unavailable"
                metric_base["fallback"] = fallback_reason
                metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
                _record_metric_quietly(metrics, metric_base)
                return False

        try:
            upstream = await send_to(cfg.headroom_url, client)
        except asyncio.CancelledError:
            await _aclose_quietly(client)
            raise
        except (asyncio.TimeoutError, httpx.TimeoutException) as exc:
            is_compress_contract = request.url.path.rstrip("/").lower() == "/v1/compress"
            timeout_reason = "headroom_connect_timeout" if _is_preconnect_failure(exc) else "headroom_timeout"
            if is_compress_contract:
                await _aclose_quietly(client)
                metric_base["result"] = "ok"
                metric_base["fallback"] = "compression_passthrough"
                metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
                _record_metric_quietly(metrics, metric_base)
                return _compression_passthrough(body, reason=timeout_reason)
            if _is_preconnect_failure(exc):
                if not await try_helper_fallback(timeout_reason):
                    return _stable_error(504, "upstream_timeout")
            else:
                await _aclose_quietly(client)
                metric_base["result"] = "timeout"
                metric_base["fallback"] = timeout_reason
                metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
                _record_metric_quietly(metrics, metric_base)
                return _stable_error(504, "upstream_timeout")
        except httpx.HTTPError as exc:
            is_compress_contract = request.url.path.rstrip("/").lower() == "/v1/compress"
            error_reason = "headroom_connect_error" if _is_preconnect_failure(exc) else "headroom_unavailable"
            if is_compress_contract:
                await _aclose_quietly(client)
                metric_base["result"] = "ok"
                metric_base["fallback"] = "compression_passthrough"
                metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
                _record_metric_quietly(metrics, metric_base)
                return _compression_passthrough(body, reason=error_reason)
            if _is_preconnect_failure(exc):
                if not await try_helper_fallback(error_reason):
                    return _stable_error(502, "upstream_unavailable")
            else:
                await _aclose_quietly(client)
                metric_base["result"] = "upstream_unavailable"
                metric_base["fallback"] = error_reason
                metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
                _record_metric_quietly(metrics, metric_base)
                return _stable_error(502, "upstream_unavailable")
        except Exception:
            is_compress_contract = request.url.path.rstrip("/").lower() == "/v1/compress"
            if is_compress_contract:
                await _aclose_quietly(client)
                metric_base["result"] = "ok"
                metric_base["fallback"] = "compression_passthrough"
                metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
                _record_metric_quietly(metrics, metric_base)
                return _compression_passthrough(body, reason="headroom_error")
            await _aclose_quietly(client)
            metric_base["result"] = "upstream_unavailable"
            metric_base["fallback"] = "headroom_error"
            metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
            _record_metric_quietly(metrics, metric_base)
            return _stable_error(502, "upstream_unavailable")

        if upstream.status_code >= 500:
            is_compress_contract = request.url.path.rstrip("/").lower() == "/v1/compress"
            if is_compress_contract:
                await _aclose_quietly(upstream)
                await _aclose_quietly(client)
                metric_base["result"] = "ok"
                metric_base["fallback"] = "compression_passthrough"
                metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
                _record_metric_quietly(metrics, metric_base)
                return _compression_passthrough(body, reason=f"headroom_http_{upstream.status_code}")
            await _aclose_quietly(upstream)
            await _aclose_quietly(client)
            metric_base["result"] = "upstream_unavailable"
            metric_base["fallback"] = fallback_reason or f"headroom_http_{upstream.status_code}"
            metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
            _record_metric_quietly(metrics, metric_base)
            return _stable_error(502, "upstream_unavailable")

        # A helper that is reachable but does not expose the requested
        # protocol is still an unavailable fallback for a request that never
        # reached the intended upstream. Do not leak its diagnostic 404.
        if fallback_reason is not None and upstream.status_code == 404:
            await _aclose_quietly(upstream)
            await _aclose_quietly(client)
            metric_base["result"] = "upstream_unavailable"
            metric_base["fallback"] = fallback_reason
            metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
            _record_metric_quietly(metrics, metric_base)
            return _stable_error(502, "upstream_unavailable")

        if fallback_reason is not None:
            metric_base["fallback"] = fallback_reason

        try:
            response_headers = _response_headers(upstream.headers)
        except Exception:
            response_headers = {}
        try:
            metric_base["token"] = _token_metrics(upstream.headers)
        except Exception:
            metric_base["token"] = None
        try:
            metric_base["usage"], metric_base["usage_status"] = _usage_metrics(upstream.headers)
        except Exception:
            metric_base["usage"] = None
            metric_base["usage_status"] = "upstream_usage_unavailable"
        try:
            cache_observation["transforms"] = _transform_names(upstream.headers)
        except Exception:
            cache_observation["transforms"] = []
        try:
            cache_observation["cached"] = _cache_flag(upstream.headers)
        except Exception:
            cache_observation["cached"] = None
        status_code = upstream.status_code
        result = "ok" if 200 <= status_code < 300 else f"http_{status_code}"
        is_responses_sse = (
            request.url.path.rstrip("/").endswith("/responses")
            and "text/event-stream" in upstream.headers.get("content-type", "").lower()
        )

        async def stream() -> AsyncIterator[bytes]:
            sse_probe = bytearray()
            response_terminal_state: str | None = None
            try:
                iterator = upstream.aiter_raw()
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise asyncio.TimeoutError
                    try:
                        chunk = await asyncio.wait_for(iterator.__anext__(), timeout=remaining)
                    except StopAsyncIteration:
                        break
                    # Forward the exact bytes before running any best-effort
                    # SSE diagnostics.  A parser failure must not truncate or
                    # rewrite an upstream stream.
                    yield chunk
                    if is_responses_sse:
                        try:
                            sse_probe.extend(chunk)
                            if len(sse_probe) > _SSE_PROBE_LIMIT:
                                del sse_probe[:-_SSE_PROBE_LIMIT]
                            terminal_state = _sse_terminal_state(bytes(sse_probe))
                            if terminal_state is not None and response_terminal_state is None:
                                response_terminal_state = terminal_state
                        except Exception:
                            # Diagnostics are fail-open by design; preserve
                            # the raw chunk and continue consuming upstream.
                            continue
                if is_responses_sse and response_terminal_state is None:
                    metric_base["result"] = "upstream_incomplete"
                    yield _response_failed_event("upstream_eof_before_response_completed")
                elif is_responses_sse and response_terminal_state == "failed":
                    metric_base["result"] = "upstream_failed"
                else:
                    metric_base["result"] = result
            except (asyncio.TimeoutError, httpx.TimeoutException):
                metric_base["result"] = "timeout"
                if is_responses_sse and response_terminal_state is None:
                    yield _response_failed_event("upstream_timeout")
            except httpx.HTTPError:
                metric_base["result"] = "upstream_unavailable"
                if is_responses_sse and response_terminal_state is None:
                    yield _response_failed_event("upstream_read_error")
            except asyncio.CancelledError:
                metric_base["result"] = "cancelled"
                raise
            except Exception:
                metric_base["result"] = "upstream_read_error"
                if is_responses_sse and response_terminal_state is None:
                    yield _response_failed_event("upstream_read_error")
            finally:
                metric_base["latency_ms"] = round((time.monotonic() - started) * 1000, 3)
                _record_metric_quietly(metrics, metric_base)
                await _aclose_quietly(upstream)
                await _aclose_quietly(client)

        return StreamingResponse(stream(), status_code=status_code, headers=response_headers)

    for method in ("GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"):
        app.add_api_route(
            "/v1/{path:path}",
            forward,
            methods=[method],
            include_in_schema=False,
            response_model=None,
        )

    return app


app = create_app()


if __name__ == "__main__":  # pragma: no cover - exercised by uvicorn
    import uvicorn

    uvicorn.run("gateway:app", host=os.environ.get("POLICY_GATEWAY_HOST", "127.0.0.1"), port=int(os.environ.get("POLICY_GATEWAY_PORT", "18787")))

"""Line-delimited JSON worker hosting one Kompress model session.

Stdout is reserved for the broker protocol. Diagnostics go to stderr and must
never include request content.
"""

from __future__ import annotations

import json
import math
import os
import sys
import time
from typing import Any


def _emit(payload: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=True, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _error_code(exc: BaseException) -> str:
    message = str(exc).lower()
    for code in ("0x887a0005", "0x887a0006", "0x887a0007", "0x887a0020"):
        if code in message:
            return f"device_lost_{code[2:]}"
    if isinstance(exc, (UnicodeError, json.JSONDecodeError)):
        return "decode_error"
    return "provider_error"


class KompressProvider:
    def __init__(self) -> None:
        backend = os.environ.get("KOMPRESS_PROVIDER_BACKEND", "cpu").strip().lower()
        if backend not in {"cpu"}:
            raise RuntimeError(f"unsupported_provider_backend:{backend}")

        # Keep the production broker on the CPU ONNX path even if the parent
        # process carries an accelerator experiment override.
        os.environ["HEADROOM_KOMPRESS_BACKEND"] = "onnx_cpu"

        from headroom.transforms.kompress_compressor import KompressCompressor

        self._compressor = KompressCompressor()
        selected = self._compressor.preload(allow_download=False)
        self.provider = "CPUExecutionProvider"
        self.backend = selected

    def compress(self, content: str, target_ratio: float | None) -> dict[str, Any]:
        started = time.perf_counter()
        result = self._compressor.compress(
            content,
            target_ratio=target_ratio,
            allow_download=False,
        )
        return {
            "compressed": result.compressed,
            "original_tokens": max(0, int(result.original_tokens)),
            "compressed_tokens": max(0, int(result.compressed_tokens)),
            "compression_ratio": max(0.0, float(result.compression_ratio)),
            "model_used": str(result.model_used),
            "provider": self.provider,
            "backend": self.backend,
            "latency_ms": round((time.perf_counter() - started) * 1000, 3),
        }


def main() -> int:
    try:
        provider = KompressProvider()
        _emit(
            {
                "type": "ready",
                "ready": True,
                "provider": provider.provider,
                "backend": provider.backend,
            }
        )
    except BaseException as exc:
        _emit({"type": "ready", "ready": False, "error_code": _error_code(exc)})
        return 2

    for raw_line in sys.stdin:
        request_id = ""
        try:
            request = json.loads(raw_line)
            request_id = str(request.get("id", ""))
            operation = request.get("op")
            if operation == "ping":
                _emit(
                    {
                        "id": request_id,
                        "ok": True,
                        "provider": provider.provider,
                        "backend": provider.backend,
                    }
                )
                continue
            if operation != "compress":
                raise ValueError("unsupported_operation")
            content = request.get("content")
            if not isinstance(content, str):
                raise TypeError("content_must_be_string")
            ratio = request.get("target_ratio")
            if ratio is None:
                target_ratio = None
            elif isinstance(ratio, bool):
                raise ValueError("target_ratio_out_of_range")
            else:
                try:
                    target_ratio = float(ratio)
                except (TypeError, ValueError, OverflowError) as exc:
                    raise ValueError("target_ratio_out_of_range") from exc
                if not math.isfinite(target_ratio) or not 0.0 < target_ratio <= 1.0:
                    raise ValueError("target_ratio_out_of_range")
            response = provider.compress(content, target_ratio)
            response.update({"id": request_id, "ok": True})
            _emit(response)
        except BaseException as exc:
            _emit({"id": request_id, "ok": False, "error_code": _error_code(exc)})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Isolated DirectML/CPU Kompress gate harness.

The harness intentionally keeps the production runtime untouched.  It uses one
session at a time, ORT_SEQUENTIAL, and disables the memory pattern as required
by the DirectML execution provider.  Output is a redacted JSON summary: model
inputs are deterministic synthetic ids and no source text is persisted.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import os
import platform
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort


DEVICE_ERROR_CODES = (
    "0x887a0005",
    "0x887a0006",
    "0x887a0007",
    "0x887a0020",
)

NATIVE_ERROR_CODES = {
    "80070057": "dml_e_invalidarg",
    "80004005": "dml_e_fail",
    "887a0001": "dml_invalid_call",
    "887a0005": "device_removed_887a0005",
    "887a0006": "device_removed_887a0006",
    "887a0007": "device_removed_887a0007",
    "887a0020": "device_removed_887a0020",
}

GRAPH_OPT_LEVELS = {
    "disable": ort.GraphOptimizationLevel.ORT_DISABLE_ALL,
    "basic": ort.GraphOptimizationLevel.ORT_ENABLE_BASIC,
    "extended": ort.GraphOptimizationLevel.ORT_ENABLE_EXTENDED,
    "all": ort.GraphOptimizationLevel.ORT_ENABLE_ALL,
}


def _exception_details(exc: BaseException) -> dict[str, Any]:
    """Expose codec-level bytes without replacing the original exception."""
    details: dict[str, Any] = {
        "repr": repr(exc)[:500],
        "type": type(exc).__name__,
    }
    if isinstance(exc, UnicodeDecodeError):
        raw = bytes(exc.object)
        details.update(
            {
                "encoding": exc.encoding,
                "start": exc.start,
                "end": exc.end,
                "reason": exc.reason,
                "object_len": len(raw),
                "object_hex": raw.hex(),
            }
        )
        for codec in ("cp936", "cp1252", "latin-1", "utf-8"):
            try:
                details[f"decode_{codec}"] = raw.decode(codec)
            except UnicodeDecodeError as decode_exc:
                details[f"decode_{codec}_error"] = str(decode_exc)[:200]
    return details


def _error_code(exc: BaseException) -> str:
    message = str(exc).lower()
    if isinstance(exc, UnicodeDecodeError):
        try:
            message = f"{message} {bytes(exc.object).decode('cp936', errors='replace').lower()}"
        except Exception:
            pass
    for code, label in NATIVE_ERROR_CODES.items():
        if code in message or f"0x{code}" in message:
            return label
    for code in DEVICE_ERROR_CODES:
        if code in message:
            return f"device_removed_{code[2:]}"
    if isinstance(exc, UnicodeDecodeError):
        return "provider_error_utf8"
    return type(exc).__name__


def _mask_bits(mask: np.ndarray) -> str:
    flat = np.asarray(mask, dtype=np.uint8).reshape(-1)
    packed = np.packbits(flat, bitorder="little")
    return packed.tobytes().hex()


def _digest(array: np.ndarray) -> str:
    return hashlib.sha256(np.asarray(array).tobytes()).hexdigest()


def _inputs(seq: int | None) -> dict[str, np.ndarray]:
    # Keep ids within the model's usual vocabulary range while remaining
    # deterministic and independent of any tokenizer or source content.
    if seq is None:
        ids = np.asarray([[1, 2], [3, 4], [5, 6]], dtype=np.int64)
        attention = np.ones((3, 2), dtype=np.int64)
        return {"X": ids.astype(np.float32)}
    ids = (np.arange(seq, dtype=np.int64) % 1024).reshape(1, seq)
    attention = np.ones((1, seq), dtype=np.int64)
    return {"input_ids": ids, "attention_mask": attention}


def _session_options(
    seq: int | None,
    profile_prefix: str | None,
    intra_threads: int,
    graph_optimization: str,
) -> ort.SessionOptions:
    options = ort.SessionOptions()
    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    options.enable_mem_pattern = False
    options.intra_op_num_threads = intra_threads
    options.inter_op_num_threads = 1
    options.graph_optimization_level = GRAPH_OPT_LEVELS[graph_optimization]
    if seq is not None:
        options.add_free_dimension_override_by_name("batch", 1)
        options.add_free_dimension_override_by_name("seq", seq)
    if profile_prefix:
        options.enable_profiling = True
        options.profile_file_prefix = profile_prefix
    return options


def _provider(mode: str, adapter: int) -> list[Any]:
    if mode in {"dml", "smoke"}:
        return [("DmlExecutionProvider", {"device_id": str(adapter)})]
    return ["CPUExecutionProvider"]


def _profile_summary(path: str | None) -> dict[str, Any]:
    if not path:
        return {"path": None, "dml_events": 0, "providers": []}
    result: dict[str, Any] = {"path": path, "dml_events": 0, "providers": []}
    try:
        events = json.loads(Path(path).read_text(encoding="utf-8"))
        providers = set()
        dml_events = 0
        for event in events:
            args = event.get("args") or {}
            provider = args.get("provider")
            if provider:
                providers.add(str(provider))
                if provider == "DmlExecutionProvider":
                    dml_events += 1
        result["dml_events"] = dml_events
        result["providers"] = sorted(providers)
    except Exception as exc:  # diagnostics must never hide inference result
        result["parse_error"] = type(exc).__name__
    return result


def _run_shape(
    *,
    model_path: Path,
    mode: str,
    adapter: int,
    seq: int,
    runs: int,
    profile_dir: Path | None,
    critical_positions: list[int],
    intra_threads: int,
    graph_optimization: str,
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "seq": seq,
        "mode": mode,
        "adapter": adapter if mode in {"dml", "smoke"} else None,
        "status": "not_started",
        "error_code": None,
        "provider_list": [],
        "session_options": {
            "execution_mode": "ORT_SEQUENTIAL",
            "enable_mem_pattern": False,
            "intra_op_num_threads": intra_threads,
            "inter_op_num_threads": 1,
            "graph_optimization_level": graph_optimization,
            "free_dimension_override": {"batch": 1, "seq": seq},
        },
        "warmup_ms": None,
        "runs": [],
        "critical_positions": critical_positions,
        "critical_retained_all": None,
        "profile": None,
    }
    session: ort.InferenceSession | None = None
    try:
        profile_prefix = None
        if profile_dir is not None:
            profile_dir.mkdir(parents=True, exist_ok=True)
            profile_prefix = str(profile_dir / f"{mode}-adapter{adapter}-seq{seq}")
        options = _session_options(
            seq, profile_prefix, intra_threads, graph_optimization
        )
        session = ort.InferenceSession(
            str(model_path),
            options,
            providers=_provider(mode, adapter),
            enable_fallback=0,
        )
        result["provider_list"] = session.get_providers()
        if mode in {"dml", "smoke"} and "DmlExecutionProvider" not in result["provider_list"]:
            result["status"] = "provider_not_active"
            result["error_code"] = "dml_not_active"
            return result
        feeds = _inputs(seq)
        started = time.perf_counter()
        output_name = "final_scores" if mode != "smoke" else "Y"
        warm = session.run([output_name], feeds)[0]
        result["warmup_ms"] = round((time.perf_counter() - started) * 1000, 3)
        measured: list[dict[str, Any]] = []
        for run_index in range(runs):
            started = time.perf_counter()
            scores = session.run([output_name], feeds)[0]
            elapsed_ms = (time.perf_counter() - started) * 1000
            keep = np.asarray(scores) > 0.5
            critical = [bool(keep.reshape(-1)[pos]) for pos in critical_positions]
            measured.append(
                {
                    "run": run_index + 1,
                    "latency_ms": round(elapsed_ms, 3),
                    "scores_sha256": _digest(scores),
                    "keep_mask_bits": _mask_bits(keep),
                    "keep_count": int(keep.sum()),
                    "critical_retained": critical,
                }
            )
        result["runs"] = measured
        result["critical_retained_all"] = all(
            all(item["critical_retained"]) for item in measured
        )
        result["output_shape"] = list(np.asarray(warm).shape)
        result["output_dtype"] = str(np.asarray(warm).dtype)
        result["status"] = "succeeded"
    except BaseException as exc:
        result["status"] = "failed"
        result["error_code"] = _error_code(exc)
        result["error_type"] = type(exc).__name__
        result["error_message"] = str(exc)[:500]
        result["exception_details"] = _exception_details(exc)
        if any(code in str(exc).lower() for code in DEVICE_ERROR_CODES):
            result["stop_after_device_removal"] = True
    finally:
        if session is not None:
            # Explicitly release the session before any next adapter/shape.
            del session
            gc.collect()
    if result.get("profile") is None and profile_prefix:
        # end_profiling is only available while the C++ session is alive; the
        # profile filename is discovered from the deterministic prefix instead.
        candidates = sorted(profile_dir.glob(f"{Path(profile_prefix).name}*.json"))
        if candidates:
            result["profile"] = _profile_summary(str(candidates[-1]))
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("dml", "cpu", "smoke"), required=True)
    parser.add_argument("--model", type=Path)
    parser.add_argument("--adapter", type=int, default=0)
    parser.add_argument("--adapters", default=None)
    parser.add_argument("--seqs", default="128")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile-dir", type=Path)
    parser.add_argument("--intra-threads", type=int, default=1)
    parser.add_argument(
        "--graph-optimization",
        choices=tuple(GRAPH_OPT_LEVELS),
        default="all",
    )
    args = parser.parse_args()

    if args.mode != "smoke" and (args.model is None or not args.model.is_file()):
        parser.error("--model is required for dml/cpu mode")
    if args.runs < 1 or args.runs > 30:
        parser.error("--runs must be between 1 and 30")
    if args.intra_threads < 1:
        parser.error("--intra-threads must be positive")

    if args.mode == "smoke":
        import onnxruntime.datasets as datasets

        model_path = Path(datasets.get_example("mul_1.onnx"))
        seqs = [3]
        adapters = [int(item) for item in (args.adapters or str(args.adapter)).split(",")]
    else:
        model_path = args.model.resolve()
        seqs = [int(item) for item in args.seqs.split(",")]
        adapters = [args.adapter]
    if any(seq < 1 for seq in seqs):
        parser.error("sequence lengths must be positive")

    results: list[dict[str, Any]] = []
    for adapter in adapters:
        for seq in seqs:
            critical_positions = [0, seq - 1]
            results.append(
                _run_shape(
                    model_path=model_path,
                    mode=args.mode,
                    adapter=adapter,
                    seq=seq if args.mode != "smoke" else None,
                    runs=args.runs,
                    profile_dir=args.profile_dir,
                    critical_positions=critical_positions,
                    intra_threads=args.intra_threads,
                    graph_optimization=args.graph_optimization,
                )
            )
            if results[-1].get("stop_after_device_removal"):
                break

    payload = {
        "schema": "directml-gate/v1",
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "onnxruntime": ort.__version__,
        "available_providers": ort.get_available_providers(),
        "model": str(model_path),
        "results": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    return 0 if all(item["status"] == "succeeded" for item in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())

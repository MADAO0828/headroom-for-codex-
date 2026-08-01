"""Read-only AMD NPU/provider provenance and CPU control harness.

This harness never installs a provider, changes PATH, or calls the system
RadeonML context-creation API.  It records the providers visible to the
selected Python environment, hashes vendor DLLs, and runs a deterministic CPU
control on the supplied Kompress model.  The output contains no source text.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import platform
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np
import onnxruntime as ort


SYSTEM_DLLS = (
    Path(r"C:\Windows\System32\RadeonML.dll"),
    Path(r"C:\Windows\System32\RadeonML_ipu.dll"),
    Path(r"C:\Windows\System32\RadeonML_DirectML.dll"),
    Path(r"C:\Windows\System32\RadeonML_tvm.dll"),
    Path(r"C:\Windows\System32\vitis-ai-runtime.dll"),
    Path(r"C:\Windows\System32\vitis-ai-runtime2.dll"),
    Path(r"C:\Windows\System32\tvm_ipu_runtime.dll"),
)

RML_SYMBOLS = (
    "rmlCreateDefaultContext",
    "rmlLoadGraphFromFile",
    "rmlCreateModelFromGraph",
    "rmlGetLastError",
)


def _digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _dll_inventory() -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    for path in SYSTEM_DLLS:
        item: dict[str, Any] = {
            "path": str(path),
            "exists": path.is_file(),
            "loaded": False,
            "symbols": {},
        }
        if not path.is_file():
            result.append(item)
            continue
        stat = path.stat()
        item.update(
            {
                "size_bytes": stat.st_size,
                "mtime_ns": stat.st_mtime_ns,
                "sha256": _digest(path),
            }
        )
        if path.name == "RadeonML_ipu.dll":
            try:
                library = ctypes.WinDLL(str(path))
                item["loaded"] = True
                item["symbols"] = {
                    symbol: hasattr(library, symbol) for symbol in RML_SYMBOLS
                }
            except BaseException as exc:  # diagnostics must not hide inventory
                item["load_error"] = {
                    "type": type(exc).__name__,
                    "message": str(exc)[:300],
                }
        result.append(item)
    return result


def _model_inputs(session: ort.InferenceSession, seq: int) -> dict[str, np.ndarray]:
    feeds: dict[str, np.ndarray] = {}
    for value in session.get_inputs():
        name = value.name
        if name == "input_ids":
            feeds[name] = (np.arange(seq, dtype=np.int64) % 1024).reshape(1, seq)
        elif name == "attention_mask":
            feeds[name] = np.ones((1, seq), dtype=np.int64)
        else:
            shape = [1 if dim in (None, "batch") else seq if dim == "seq" else 1 for dim in value.shape]
            dtype = np.int64 if "int64" in value.type else np.float32
            feeds[name] = np.zeros(shape, dtype=dtype)
    return feeds


def _cpu_control(model: Path, seqs: list[int], runs: int) -> dict[str, Any]:
    result: dict[str, Any] = {
        "status": "not_started",
        "provider_request": ["CPUExecutionProvider"],
        "runs": [],
    }
    options = ort.SessionOptions()
    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    options.enable_mem_pattern = False
    options.intra_op_num_threads = 1
    options.inter_op_num_threads = 1
    try:
        session = ort.InferenceSession(
            str(model), options, providers=["CPUExecutionProvider"], enable_fallback=0
        )
        result["session_providers"] = session.get_providers()
        result["inputs"] = [
            {"name": item.name, "type": item.type, "shape": list(item.shape)}
            for item in session.get_inputs()
        ]
        result["outputs"] = [
            {"name": item.name, "type": item.type, "shape": list(item.shape)}
            for item in session.get_outputs()
        ]
        meta = session.get_modelmeta()
        result["model_meta"] = {
            "producer_name": meta.producer_name,
            "graph_name": meta.graph_name,
            "domain": meta.domain,
            "version": meta.version,
        }
        for seq in seqs:
            feeds = _model_inputs(session, seq)
            warm_started = time.perf_counter()
            warm = session.run(None, feeds)
            item: dict[str, Any] = {
                "seq": seq,
                "warmup_ms": round((time.perf_counter() - warm_started) * 1000, 3),
                "runs": [],
                "output_shape": [list(np.asarray(value).shape) for value in warm],
                "output_dtype": [str(np.asarray(value).dtype) for value in warm],
            }
            for index in range(runs):
                started = time.perf_counter()
                outputs = session.run(None, feeds)
                item["runs"].append(
                    {
                        "run": index + 1,
                        "latency_ms": round((time.perf_counter() - started) * 1000, 3),
                        "output_sha256": [
                            hashlib.sha256(np.asarray(value).tobytes()).hexdigest()
                            for value in outputs
                        ],
                    }
                )
            result["runs"].append(item)
        result["status"] = "succeeded"
    except BaseException as exc:
        result.update(
            {
                "status": "failed",
                "error_type": type(exc).__name__,
                "error_message": str(exc)[:500],
            }
        )
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seqs", default="64,128")
    parser.add_argument("--runs", type=int, default=3)
    args = parser.parse_args()
    if not args.model.is_file():
        parser.error("--model must point to an existing file")
    if args.runs < 1 or args.runs > 10:
        parser.error("--runs must be between 1 and 10")
    seqs = [int(value) for value in args.seqs.split(",") if value]
    if not seqs or any(value < 1 for value in seqs):
        parser.error("--seqs must contain positive integers")

    model_stat = args.model.stat()
    payload = {
        "schema": "npu-provenance/v1",
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "python": sys.version.split()[0],
        "python_executable": sys.executable,
        "platform": platform.platform(),
        "onnxruntime": ort.__version__,
        "available_providers": ort.get_available_providers(),
        "model": {
            "path": str(args.model.resolve()),
            "size_bytes": model_stat.st_size,
            "sha256": _digest(args.model),
        },
        "system_vendor_dlls": _dll_inventory(),
        "cpu_control": _cpu_control(args.model.resolve(), seqs, args.runs),
        "npu_context_smoke": {
            "status": "not_run",
            "reason": "RadeonML IPU context ABI is not invoked by this safe inventory harness",
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w", encoding="utf-8", newline="\n") as stream:
        stream.write(json.dumps(payload, ensure_ascii=True, indent=2) + "\n")
    return 0 if payload["cpu_control"]["status"] == "succeeded" else 1


if __name__ == "__main__":
    raise SystemExit(main())

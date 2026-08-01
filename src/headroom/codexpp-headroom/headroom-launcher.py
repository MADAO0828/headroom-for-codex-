"""Warm Kompress once, then delegate to Headroom's official CLI."""

from __future__ import annotations

import sys
import os
from collections.abc import Sequence


def _requested_worker_count(argv: Sequence[str]) -> int:
    """Return the CLI worker count without changing Headroom's own parsing."""
    for index, argument in enumerate(argv):
        if argument == "--workers" and index + 1 < len(argv):
            try:
                return int(argv[index + 1])
            except ValueError:
                return 1
        if argument.startswith("--workers="):
            try:
                return int(argument.split("=", 1)[1])
            except ValueError:
                return 1

    try:
        return int(os.environ.get("HEADROOM_WORKERS", "1"))
    except ValueError:
        return 1


def _warm_kompress() -> None:
    """Warm only the in-process backend; the broker owns remote warmup."""
    if os.environ.get("HEADROOM_KOMPRESS_ENDPOINT", "").strip():
        return
    # Keep the launcher deterministic on Windows while respecting explicit
    # operator overrides supplied by the wrapper or the MCP environment.
    os.environ.setdefault("HEADROOM_KOMPRESS_BACKEND", "onnx_cpu")
    os.environ.setdefault("HEADROOM_ONNX_CPU_ARENA", "1")
    os.environ.setdefault("HEADROOM_KOMPRESS_ONNX_INTRA_THREADS", "12")
    os.environ.setdefault("HEADROOM_KOMPRESS_ONNX_INTER_THREADS", "1")
    try:
        from headroom.transforms.kompress_compressor import warm_kompress_model

        ready = warm_kompress_model(allow_download=False)
    except Exception as exc:  # pragma: no cover - depends on local runtime
        print(
            "headroom-launcher: Kompress warmup failed "
            f"({type(exc).__name__}: {exc}); continuing with official CLI",
            file=sys.stderr,
            flush=True,
        )
        return

    if not ready:
        print(
            "headroom-launcher: Kompress warmup unavailable "
            "(local model cache or dependencies); continuing with official CLI",
            file=sys.stderr,
            flush=True,
        )


def main(argv: Sequence[str] | None = None) -> None:
    """Warm Kompress and forward every argument to Headroom's CLI."""
    arguments = list(sys.argv[1:] if argv is None else argv)
    worker_count = _requested_worker_count(arguments)
    # One worker benefits from the measured 12-thread setting on this host;
    # multiple workers each own an ONNX pool, so keep eight threads per worker.
    os.environ.setdefault(
        "HEADROOM_KOMPRESS_ONNX_INTRA_THREADS",
        "12" if worker_count <= 1 else "8",
    )
    # With Uvicorn workers, this process is the supervisor. Each serving
    # worker runs Headroom's own startup preload, so warming here would retain
    # an unused third ONNX session for a two-worker launch.
    if worker_count <= 1 and not os.environ.get("HEADROOM_KOMPRESS_ENDPOINT", "").strip():
        _warm_kompress()

    from headroom.cli import main as headroom_main

    headroom_main.main(args=arguments, prog_name="headroom")


if __name__ == "__main__":
    main()

"""Run an isolated Kompress broker capacity matrix without touching production ports.

The harness starts one broker per case on a caller-selected loopback port, sends
bounded synthetic requests, and records only aggregate latency/status counters.
Request bodies are generated in memory and are never written to the evidence.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import httpx


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--python", type=Path)
    parser.add_argument("--base-port", type=int, default=18890)
    parser.add_argument("--per-class", type=int, default=30)
    parser.add_argument("--concurrency", type=int, default=0)
    parser.add_argument("--queue-limits", type=int, nargs="+", default=[4, 8, 16])
    parser.add_argument("--queue-waits", type=float, nargs="+", default=[0.1, 0.3, 0.6])
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("--output", type=Path, default=Path("evidence") / "p72f-kompress-capacity-benchmark.json")
    return parser.parse_args()


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * fraction))))
    return round(ordered[index], 3)


def build_environment(root: Path, python_path: Path, port: int, queue_limit: int, queue_wait: float) -> dict[str, str]:
    runtime = root / "runtime"
    cache = runtime / "cache"
    logs = runtime / "logs" / "isolated-capacity"
    state = runtime / "state" / "isolated-capacity"
    logs.mkdir(parents=True, exist_ok=True)
    state.mkdir(parents=True, exist_ok=True)
    return {
        "PYTHONPATH": str(root / "src"),
        "KOMPRESS_BROKER_STATE_PATH": str(state / f"broker-{port}.json"),
        "KOMPRESS_PROVIDER_BACKEND": "cpu",
        "KOMPRESS_WORKER_PYTHON": str(python_path),
        "KOMPRESS_WORKER_STDERR_PATH": str(logs / f"worker-{port}.stderr.log"),
        "KOMPRESS_QUEUE_LIMIT": str(queue_limit),
        "KOMPRESS_QUEUE_WAIT_SECONDS": str(queue_wait),
        "KOMPRESS_REQUEST_TIMEOUT_SECONDS": "60",
        "KOMPRESS_STARTUP_TIMEOUT_SECONDS": "600",
        "KOMPRESS_MAX_CONTENT_BYTES": str(16 * 1024 * 1024),
        "HEADROOM_KOMPRESS_BACKEND": "onnx_cpu",
        "HEADROOM_KOMPRESS_ONNX_INTRA_THREADS": "12",
        "HEADROOM_KOMPRESS_ONNX_INTER_THREADS": "1",
        "HEADROOM_ONNX_CPU_ARENA": "1",
        "HF_HOME": str(cache / "huggingface"),
        "HF_HUB_CACHE": str(cache / "huggingface" / "hub"),
        "TRANSFORMERS_CACHE": str(cache / "huggingface" / "transformers"),
        "HEADROOM_CACHE_DIR": str(cache / "headroom"),
        "HEADROOM_RUNTIME_ROOT": str(runtime),
        "HEADROOM_WORKSPACE_DIR": str(runtime / "private" / "headroom-workspace"),
        "HEADROOM_CONFIG_DIR": str(runtime / "private" / "headroom-config"),
    }


async def wait_ready(client: httpx.AsyncClient, deadline: float) -> dict[str, Any]:
    last: dict[str, Any] = {}
    while time.monotonic() < deadline:
        try:
            response = await client.get("/readyz")
            if response.status_code == 200:
                body = response.json()
                if body.get("ready") is True:
                    return body
                last = body
        except (httpx.HTTPError, ValueError):
            pass
        await asyncio.sleep(0.5)
    raise RuntimeError(f"isolated_broker_not_ready:{last.get('error_code', 'unknown')}")


async def run_case(
    root: Path,
    python_path: Path,
    port: int,
    queue_limit: int,
    queue_wait: float,
    per_class: int,
    timeout: float,
    concurrency: int,
) -> dict[str, Any]:
    environment = os.environ.copy()
    environment.update(build_environment(root, python_path, port, queue_limit, queue_wait))
    command = [
        str(python_path),
        "-m",
        "uvicorn",
        "kompress_broker.app:app",
        "--app-dir",
        str(root / "src"),
        "--host",
        "127.0.0.1",
        "--port",
        str(port),
        "--no-access-log",
    ]
    process = subprocess.Popen(
        command,
        cwd=root,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    base_url = f"http://127.0.0.1:{port}"
    try:
        async with httpx.AsyncClient(base_url=base_url, timeout=httpx.Timeout(timeout), trust_env=False) as client:
            ready = await wait_ready(client, time.monotonic() + timeout)
            content = "isolated kompress capacity sample " * 120
            limiter = asyncio.Semaphore(concurrency) if concurrency > 0 else None

            async def send(class_name: str, index: int) -> dict[str, Any]:
                if limiter is not None:
                    await limiter.acquire()
                started = time.perf_counter()
                try:
                    request_id = f"bench_{queue_limit}_{int(queue_wait * 1000)}_{class_name}_{index}"
                    response = await client.post(
                        "/compress",
                        json={
                            "content": content,
                            "request_id": request_id,
                            "correlation_id": f"bench_{class_name}_{index}",
                        },
                    )
                    elapsed = (time.perf_counter() - started) * 1000
                    body = response.json()
                    return {
                        "class": class_name,
                        "http_status": response.status_code,
                        "status": body.get("status"),
                        "error_code": body.get("error_code"),
                        "latency_ms": round(elapsed, 3),
                    }
                except (httpx.HTTPError, ValueError, TypeError) as exc:
                    return {
                        "class": class_name,
                        "http_status": None,
                        "status": "exception",
                        "error_code": type(exc).__name__,
                        "latency_ms": round((time.perf_counter() - started) * 1000, 3),
                    }
                finally:
                    if limiter is not None:
                        limiter.release()

            tasks = [
                send("main", index)
                for index in range(per_class)
            ] + [
                send("spawned", index)
                for index in range(per_class)
            ]
            results = await asyncio.gather(*tasks)
            health = (await client.get("/health")).json()

        latencies = [float(item["latency_ms"]) for item in results]
        grouped: dict[str, dict[str, Any]] = {}
        for class_name in ("main", "spawned"):
            subset = [item for item in results if item["class"] == class_name]
            grouped[class_name] = {
                "requests": len(subset),
                "compressed": sum(item.get("status") == "compressed" for item in subset),
                "passthrough": sum(item.get("status") == "passthrough" for item in subset),
                "exceptions": sum(item.get("status") == "exception" for item in subset),
                "p95_ms": percentile([float(item["latency_ms"]) for item in subset], 0.95),
            }
        return {
            "queue_limit": queue_limit,
            "queue_wait_seconds": queue_wait,
            "concurrency": concurrency if concurrency > 0 else len(results),
            "ready": ready,
            "requests": len(results),
            "compressed": sum(item.get("status") == "compressed" for item in results),
            "passthrough": sum(item.get("status") == "passthrough" for item in results),
            "exceptions": sum(item.get("status") == "exception" for item in results),
            "queue_full": sum(item.get("error_code") == "queue_full" for item in results),
            "p95_ms": percentile(latencies, 0.95),
            "p50_ms": percentile(latencies, 0.50),
            "by_class": grouped,
            "broker_counters": health.get("counters", {}),
        }
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def main() -> int:
    args = parse_args()
    root = args.project_root.resolve()
    python_path = (args.python or root / "runtime" / "python" / "Scripts" / "python.exe").resolve()
    if not python_path.is_file():
        raise SystemExit(f"python_missing:{python_path}")
    if args.per_class < 30:
        raise SystemExit("per_class_must_be_at_least_30")
    if args.concurrency < 0:
        raise SystemExit("concurrency_must_be_nonnegative")
    matrix = [(limit, wait) for limit in args.queue_limits for wait in args.queue_waits]
    cases: list[dict[str, Any]] = []
    for index, (queue_limit, queue_wait) in enumerate(matrix):
        cases.append(
            asyncio.run(
                run_case(
                    root,
                    python_path,
                    args.base_port + index,
                    queue_limit,
                    queue_wait,
                    args.per_class,
                    args.timeout,
                    args.concurrency,
                )
            )
        )
    evidence = {
        "schema_version": 1,
        "kind": "isolated_kompress_capacity_benchmark",
        "production_touched": False,
        "production_ports": [],
        "provider": "CPUExecutionProvider",
        "backend": "onnx",
        "per_class": args.per_class,
        "cases": cases,
    }
    output = args.output if args.output.is_absolute() else root / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(evidence, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(evidence, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

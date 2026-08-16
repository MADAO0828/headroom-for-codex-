"""Measure isolated multi-process Kompress worker pools.

This is a lab-only probe. Each child broker owns one model session and binds a
separate loopback port; production services and configuration are untouched.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any

import httpx


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--python", type=Path)
    parser.add_argument("--base-port", type=int, default=18900)
    parser.add_argument("--pool-sizes", type=int, nargs="+", default=[2, 4])
    parser.add_argument("--per-class", type=int, default=30)
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--output", type=Path, default=Path("evidence") / "p72f-kompress-worker-pool-benchmark.json")
    return parser.parse_args()


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * fraction))))
    return round(ordered[index], 3)


def environment(root: Path, python_path: Path, port: int, index: int) -> dict[str, str]:
    runtime = root / "runtime"
    cache = runtime / "cache"
    state = runtime / "state" / "isolated-worker-pool"
    logs = runtime / "logs" / "isolated-worker-pool"
    state.mkdir(parents=True, exist_ok=True)
    logs.mkdir(parents=True, exist_ok=True)
    return {
        "PYTHONPATH": str(root / "src"),
        "KOMPRESS_BROKER_STATE_PATH": str(state / f"broker-{port}.json"),
        "KOMPRESS_PROVIDER_BACKEND": "cpu",
        "KOMPRESS_WORKER_PYTHON": str(python_path),
        "KOMPRESS_WORKER_STDERR_PATH": str(logs / f"worker-{port}-{index}.stderr.log"),
        "KOMPRESS_QUEUE_LIMIT": "4",
        "KOMPRESS_QUEUE_WAIT_SECONDS": "0.1",
        "KOMPRESS_REQUEST_TIMEOUT_SECONDS": "60",
        "KOMPRESS_STARTUP_TIMEOUT_SECONDS": "600",
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


async def ready(client: httpx.AsyncClient, deadline: float) -> dict[str, Any]:
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
    raise RuntimeError(f"worker_pool_broker_not_ready:{last.get('error_code', 'unknown')}")


async def run_case(root: Path, python_path: Path, pool_size: int, base_port: int, per_class: int, timeout: float) -> dict[str, Any]:
    processes: list[subprocess.Popen[bytes]] = []
    urls = [f"http://127.0.0.1:{base_port + index}" for index in range(pool_size)]
    clients: list[httpx.AsyncClient] = []
    try:
        for index, port in enumerate(range(base_port, base_port + pool_size)):
            env = os.environ.copy()
            env.update(environment(root, python_path, port, index))
            process = subprocess.Popen(
                [
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
                ],
                cwd=root,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            )
            processes.append(process)
        clients = [httpx.AsyncClient(base_url=url, timeout=httpx.Timeout(timeout), trust_env=False) for url in urls]
        await asyncio.gather(*(ready(client, time.monotonic() + timeout) for client in clients))
        content = "isolated kompress worker pool sample " * 120

        async def send(class_name: str, index: int) -> dict[str, Any]:
            client = clients[index % pool_size]
            started = time.perf_counter()
            try:
                response = await client.post(
                    "/compress",
                    json={
                        "content": content,
                        "request_id": f"pool_{pool_size}_{class_name}_{index}",
                        "correlation_id": f"pool_{class_name}_{index}",
                    },
                )
                body = response.json()
                return {
                    "class": class_name,
                    "http_status": response.status_code,
                    "status": body.get("status"),
                    "error_code": body.get("error_code"),
                    "latency_ms": round((time.perf_counter() - started) * 1000, 3),
                }
            except (httpx.HTTPError, ValueError, TypeError) as exc:
                return {
                    "class": class_name,
                    "http_status": None,
                    "status": "exception",
                    "error_code": type(exc).__name__,
                    "latency_ms": round((time.perf_counter() - started) * 1000, 3),
                }

        results = await asyncio.gather(
            *(send("main", index) for index in range(per_class)),
            *(send("spawned", index) for index in range(per_class)),
        )
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
            "pool_size": pool_size,
            "requests": len(results),
            "compressed": sum(item.get("status") == "compressed" for item in results),
            "passthrough": sum(item.get("status") == "passthrough" for item in results),
            "exceptions": sum(item.get("status") == "exception" for item in results),
            "queue_full": sum(item.get("error_code") == "queue_full" for item in results),
            "p50_ms": percentile(latencies, 0.50),
            "p95_ms": percentile(latencies, 0.95),
            "by_class": grouped,
        }
    finally:
        for client in clients:
            await client.aclose()
        for process in processes:
            process.terminate()
        for process in processes:
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
    cases = [
        asyncio.run(run_case(root, python_path, pool_size, args.base_port + index * 10, args.per_class, args.timeout))
        for index, pool_size in enumerate(args.pool_sizes)
    ]
    evidence = {
        "schema_version": 1,
        "kind": "isolated_kompress_worker_pool_benchmark",
        "production_touched": False,
        "production_ports": [],
        "provider": "CPUExecutionProvider",
        "backend": "onnx",
        "queue_limit_per_worker": 4,
        "queue_wait_seconds_per_worker": 0.1,
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

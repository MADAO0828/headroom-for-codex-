"""Run a bounded, synthetic main/spawned contract window through Gateway."""

from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import sys
import time
from pathlib import Path

import httpx


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--count", type=int, default=50)
    parser.add_argument("--gateway", default="http://127.0.0.1:18787")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("evidence") / "synthetic-acceptance.json",
    )
    return parser.parse_args()


async def run_window(args: argparse.Namespace) -> dict[str, object]:
    if args.count <= 0 or args.count > 500:
        raise ValueError("count must be between 1 and 500")

    payload = {
        "model": "gpt-5",
        "messages": [
            {
                "role": "user",
                "content": "synthetic headroom acceptance sample " * 25,
            }
        ],
        "config": {"compress_user_messages": True},
    }
    classes = {
        "main": ({"x-codex-turn-metadata": json.dumps({"role": "main"})}, False),
        "spawned": (
            {
                "x-codex-turn-metadata": json.dumps(
                    {
                        "subagent_kind": "thread_spawn",
                        "parent_thread_id": "synthetic-parent",
                    }
                )
            },
            True,
        ),
    }
    results: dict[str, dict[str, object]] = {}
    timeout_count = 0
    negative_savings = 0
    synthetic_run_id = f"synthetic-acceptance-{int(time.time())}"
    async with httpx.AsyncClient(
        timeout=httpx.Timeout(90.0),
        follow_redirects=False,
        trust_env=False,
    ) as client:
        for request_class, (headers, expect_bypass) in classes.items():
            samples: list[float] = []
            status_counts: dict[str, int] = {}
            failures = 0
            bypass_mismatches = 0
            nonnegative_savings = True
            for index in range(args.count):
                started = time.perf_counter()
                try:
                    request_headers = dict(headers)
                    request_headers["x-headroom-synthetic-run-id"] = synthetic_run_id
                    response = await client.post(
                        f"{args.gateway.rstrip('/')}/v1/compress",
                        headers=request_headers,
                        json=payload,
                    )
                    elapsed_ms = (time.perf_counter() - started) * 1000
                    samples.append(elapsed_ms)
                    status_key = str(response.status_code)
                    status_counts[status_key] = status_counts.get(status_key, 0) + 1
                    if response.status_code == 504:
                        timeout_count += 1
                    if response.status_code != 200:
                        failures += 1
                        continue
                    body = response.json()
                    saved = body.get("tokens_saved")
                    if not isinstance(saved, (int, float)) or saved < 0:
                        negative_savings += 1
                        nonnegative_savings = False
                    transforms = body.get("transforms_applied") or []
                    if expect_bypass and (body.get("tokens_before") != 0 or transforms):
                        bypass_mismatches += 1
                except (httpx.HTTPError, ValueError, TypeError, KeyError):
                    failures += 1
                    status_counts["exception"] = status_counts.get("exception", 0) + 1
                if (index + 1) % 10 == 0:
                    print(f"{request_class}: {index + 1}/{args.count}", flush=True)
            results[request_class] = {
                "requested": args.count,
                "completed": len(samples),
                "failures": failures,
                "status_counts": status_counts,
                "bypass_mismatches": bypass_mismatches,
                "nonnegative_savings": nonnegative_savings,
                "latency_ms": {
                    "min": round(min(samples), 3) if samples else None,
                    "p50": round(statistics.median(samples), 3) if samples else None,
                    "max": round(max(samples), 3) if samples else None,
                },
            }

    return {
        "schema_version": 1,
        "kind": "synthetic_compress_contract",
        "gateway": args.gateway,
        "synthetic_run_id": synthetic_run_id,
        "requested_per_class": args.count,
        "classes": results,
        "compression_504_total": timeout_count,
        "negative_savings_total": negative_savings,
        "passed": (
            all(
                item["failures"] == 0
                and item["bypass_mismatches"] == 0
                and item["nonnegative_savings"]
                for item in results.values()
            )
            and timeout_count == 0
            and negative_savings == 0
        ),
    }


def main() -> int:
    args = parse_args()
    try:
        evidence = asyncio.run(run_window(args))
    except (OSError, ValueError, httpx.HTTPError) as exc:
        print(f"synthetic acceptance failed: {type(exc).__name__}", file=sys.stderr)
        return 2
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(evidence, ensure_ascii=True, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(evidence, ensure_ascii=True))
    return 0 if evidence["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

"""Minimal monitor fixture for the isolated Route C canary.

This module is intentionally not the production monitor.  It exposes only a
stable, redacted status contract so the isolated canary can prove that its
monitor port is owned by the same port generation without inspecting user
configuration, credentials, or session content.
"""

from __future__ import annotations

import os
from datetime import UTC, datetime
from typing import Any

from fastapi import FastAPI


def _port(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError:
        return default
    return value if 1 <= value <= 65535 else default


def _snapshot() -> dict[str, Any]:
    return {
        "service": "route-c-canary-monitor",
        "status": "healthy",
        "ready": True,
        "alive": True,
        "route_scope": "isolated",
        "official_dataplane": "not_proven",
        "generation": os.environ.get("ROUTE_C_CANARY_GENERATION", "isolated"),
        "ports": {
            "ingress": _port("ROUTE_C_INGRESS_PORT", 58321),
            "egress": _port("ROUTE_C_EGRESS_PORT", 58322),
            "gateway": _port("ROUTE_C_GATEWAY_PORT", 18887),
            "monitor": _port("ROUTE_C_MONITOR_PORT", 18888),
            "headroom": _port("ROUTE_C_HEADROOM_PORT", 18889),
            "broker": _port("ROUTE_C_BROKER_PORT", 18890),
        },
        "counters": {
            "main": 0,
            "spawned": 0,
            "fallback": 0,
            "device_removal": 0,
        },
        "updated_at_utc": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
    }


app = FastAPI(title="Route C Canary Monitor", docs_url=None, redoc_url=None)


@app.get("/livez")
def livez() -> dict[str, Any]:
    snapshot = _snapshot()
    return {"service": snapshot["service"], "status": "healthy", "alive": True}


@app.get("/health")
def health() -> dict[str, Any]:
    return _snapshot()


@app.get("/status")
def status() -> dict[str, Any]:
    return _snapshot()

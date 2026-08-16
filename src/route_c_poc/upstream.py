"""Redacted fake upstream for the isolated Route C canary."""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse


def _state_path() -> Path:
    return Path(os.environ.get("ROUTE_C_CANARY_UPSTREAM_STATE", "route-c-upstream.json"))


def _record(request: Request, body: bytes) -> None:
    path = _state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    current: dict[str, Any] = {"requests": 0, "paths": {}, "bytes": 0}
    try:
        current.update(json.loads(path.read_text(encoding="utf-8")))
    except (FileNotFoundError, ValueError, OSError):
        pass
    current["requests"] = int(current.get("requests", 0)) + 1
    paths = current.setdefault("paths", {})
    key = request.url.path
    paths[key] = int(paths.get(key, 0)) + 1
    current["bytes"] = int(current.get("bytes", 0)) + len(body)
    path.write_text(json.dumps(current, sort_keys=True), encoding="utf-8")


app = FastAPI(title="Route C Canary Upstream", docs_url=None, redoc_url=None)


@app.get("/health")
def health() -> dict[str, Any]:
    return {"service": "route-c-canary-upstream", "status": "healthy", "ready": True}


@app.api_route("/v1/{path:path}", methods=["GET", "POST", "OPTIONS"])
async def v1(request: Request, path: str) -> Any:
    body = await request.body()
    _record(request, body)
    if path == "models":
        return JSONResponse({"object": "list", "data": [{"id": "canary-model"}]})
    if path == "responses" and request.method == "POST":
        async def events():
            yield b'data: {"type":"response.output_text.delta","delta":"canary"}\n\n'
            yield b'data: {"type":"response.completed"}\n\n'

        return StreamingResponse(events(), media_type="text/event-stream")
    return JSONResponse({"status": "ok", "path": request.url.path})

"""In-process egress PoC with fail-open SSE handling."""

from __future__ import annotations

from dataclasses import dataclass
import json
from typing import Mapping

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response

from .contracts import RouteContractError, RouteLease, strip_internal_headers, validate_upstream_url


TERMINAL_TYPES = {"response.completed", "response.failed"}


@dataclass(frozen=True)
class EgressOutcome:
    status_code: int
    body: bytes
    passthrough: bool
    terminal: bool
    error_code: str | None = None
    request_count: int = 0


def _failed_event(code: str) -> bytes:
    payload = {"type": "response.failed", "error": {"code": code}}
    return f"data: {json.dumps(payload, separators=(',', ':'))}\n\n".encode("utf-8")


def ensure_terminal_sse(body: bytes) -> tuple[bytes, bool]:
    """Preserve bytes and append exactly one standard failure terminal if needed."""

    for line in body.splitlines():
        if not line.startswith(b"data:"):
            continue
        try:
            event = json.loads(line[5:].strip())
        except (UnicodeDecodeError, json.JSONDecodeError):
            continue
        if isinstance(event, dict) and event.get("type") in TERMINAL_TYPES:
            return body, True
    separator = b"" if not body or body.endswith(b"\n\n") else b"\n\n"
    return body + separator + _failed_event("upstream_incomplete"), True


class EgressRouter:
    """One-shot forwarding contract; never retries a non-idempotent request."""

    def __init__(self, lease: RouteLease, capability: str, *, transport: httpx.AsyncBaseTransport | None = None):
        if not lease.verify(capability):
            raise RouteContractError("invalid or stale lease capability")
        self._lease = lease
        self._capability = capability
        self._transport = transport

    async def forward(
        self,
        *,
        upstream_url: str,
        body: bytes,
        headers: Mapping[str, str],
        original_body: bytes | None = None,
    ) -> EgressOutcome:
        original = body if original_body is None else original_body
        try:
            validate_upstream_url(upstream_url)
        except RouteContractError as exc:
            return EgressOutcome(400, original, False, False, str(exc), 0)

        clean_headers = strip_internal_headers(headers)
        request_count = 1
        try:
            async with httpx.AsyncClient(
                transport=self._transport, timeout=httpx.Timeout(5.0)
            ) as client:
                response = await client.post(upstream_url, content=body, headers=clean_headers)
                response_body = await response.aread()
        except (httpx.TimeoutException, httpx.NetworkError) as exc:
            return EgressOutcome(200, original, True, False, type(exc).__name__, request_count)

        if response.status_code >= 500:
            return EgressOutcome(200, original, True, False, f"upstream_{response.status_code}", request_count)

        terminal_body, terminal = ensure_terminal_sse(response_body)
        return EgressOutcome(response.status_code, terminal_body, False, terminal, None, request_count)


def create_egress_app(router: EgressRouter, upstream_url: str) -> FastAPI:
    """Create an isolated ASGI app for tests or an ephemeral PoC listener."""

    app = FastAPI()

    @app.get("/health")
    async def health() -> dict[str, object]:
        return {"ready": True, "native": False, "production": False}

    @app.post("/v1/responses")
    async def responses(request: Request) -> Response:
        body = await request.body()
        outcome = await router.forward(
            upstream_url=upstream_url,
            body=body,
            original_body=body,
            headers=dict(request.headers),
        )
        if outcome.status_code == 400:
            return JSONResponse(
                status_code=400,
                content={"error": outcome.error_code or "route_contract_error"},
            )
        return Response(
            content=outcome.body,
            status_code=outcome.status_code,
            media_type="text/event-stream",
            headers={"x-route-c-passthrough": str(outcome.passthrough).lower()},
        )

    return app

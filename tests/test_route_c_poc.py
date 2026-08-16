from __future__ import annotations

import asyncio
import unittest

import httpx

from src.route_c_poc import (
    EgressRouter,
    build_internal_headers,
    create_egress_app,
    create_lease,
    strip_internal_headers,
    validate_upstream_url,
)
from src.route_c_poc.contracts import RouteContractError
from src.route_c_poc.monitor import app as monitor_app


class RouteCPoCTests(unittest.TestCase):
    def test_lease_capability_and_expiry(self) -> None:
        lease, capability = create_lease(1234, "2026-08-02T00:00:00Z", now=100.0)
        self.assertTrue(lease.verify(capability, now=110.0))
        self.assertFalse(lease.verify("wrong", now=110.0))
        self.assertFalse(lease.verify(capability, now=116.0))

    def test_internal_headers_are_removed(self) -> None:
        lease, capability = create_lease(1234, "start")
        headers = build_internal_headers(lease, capability, correlation_id="corr")
        headers["Authorization"] = "Bearer redacted"
        headers["X-Custom"] = "keep"
        clean = strip_internal_headers(headers)
        self.assertNotIn("x-route-c-capability", {key.lower() for key in clean})
        self.assertEqual(clean["Authorization"], "Bearer redacted")
        self.assertEqual(clean["X-Custom"], "keep")

    def test_self_cycle_upstreams_are_rejected(self) -> None:
        for url in (
            "http://127.0.0.1:18787/v1",
            "http://localhost:57321/v1",
            "http://127.0.0.1:57322/v1",
        ):
            with self.assertRaises(RouteContractError):
                validate_upstream_url(url)

    def test_real_upstream_url_is_accepted(self) -> None:
        self.assertEqual(validate_upstream_url("https://example.invalid/v1"), "https://example.invalid/v1")

    @staticmethod
    def _transport(status: int, body: bytes) -> httpx.MockTransport:
        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(status, content=body, request=request)

        return httpx.MockTransport(handler)

    def test_sse_completed_is_preserved_and_internal_headers_not_forwarded(self) -> None:
        seen: dict[str, str] = {}

        def handler(request: httpx.Request) -> httpx.Response:
            seen.update({key.lower(): value for key, value in request.headers.items()})
            return httpx.Response(
                200,
                content=b'data: {"type":"response.completed"}\n\n',
                request=request,
            )

        lease, capability = create_lease(1234, "start")
        router = EgressRouter(lease, capability, transport=httpx.MockTransport(handler))
        internal = build_internal_headers(lease, capability, correlation_id="corr")
        internal["X-Test"] = "yes"
        outcome = asyncio.run(
            router.forward(
                upstream_url="https://example.invalid/v1/responses",
                body=b"request",
                headers=internal,
            )
        )
        self.assertEqual(outcome.status_code, 200)
        self.assertTrue(outcome.terminal)
        self.assertFalse(outcome.passthrough)
        self.assertIn(b"response.completed", outcome.body)
        self.assertNotIn("x-route-c-capability", seen)
        self.assertEqual(seen["x-test"], "yes")

    def test_incomplete_sse_gets_one_failed_terminal(self) -> None:
        lease, capability = create_lease(1234, "start")
        router = EgressRouter(
            lease,
            capability,
            transport=self._transport(200, b'data: {"type":"response.output_text.delta"}\n\n'),
        )
        outcome = asyncio.run(
            router.forward(
                upstream_url="https://example.invalid/v1/responses",
                body=b"request",
                headers={},
            )
        )
        self.assertTrue(outcome.terminal)
        self.assertEqual(outcome.body.count(b"response.failed"), 1)

    def test_spaced_terminal_sse_is_not_duplicated(self) -> None:
        lease, capability = create_lease(1234, "start")
        router = EgressRouter(
            lease,
            capability,
            transport=self._transport(200, b'data: {"type": "response.completed"}\n\n'),
        )
        outcome = asyncio.run(
            router.forward(
                upstream_url="https://example.invalid/v1/responses",
                body=b"request",
                headers={},
            )
        )
        self.assertEqual(outcome.body.count(b"response.completed"), 1)
        self.assertNotIn(b"response.failed", outcome.body)

    def test_upstream_5xx_fails_open_without_retry(self) -> None:
        lease, capability = create_lease(1234, "start")
        router = EgressRouter(
            lease,
            capability,
            transport=self._transport(502, b"upstream failure"),
        )
        original = b"original-request"
        outcome = asyncio.run(
            router.forward(
                upstream_url="https://example.invalid/v1/responses",
                body=original,
                original_body=original,
                headers={},
            )
        )
        self.assertTrue(outcome.passthrough)
        self.assertEqual(outcome.body, original)
        self.assertEqual(outcome.request_count, 1)

    def test_upstream_network_error_fails_open_without_retry(self) -> None:
        def handler(request: httpx.Request) -> httpx.Response:
            raise httpx.ConnectError("synthetic network failure", request=request)

        lease, capability = create_lease(1234, "start")
        router = EgressRouter(lease, capability, transport=httpx.MockTransport(handler))
        original = b"original-request"
        outcome = asyncio.run(
            router.forward(
                upstream_url="https://example.invalid/v1/responses",
                body=original,
                original_body=original,
                headers={},
            )
        )
        self.assertTrue(outcome.passthrough)
        self.assertEqual(outcome.body, original)
        self.assertEqual(outcome.request_count, 1)

    def test_30_main_and_30_spawned_synthetic_streams(self) -> None:
        counts = {"main": 0, "spawned": 0}

        def handler(request: httpx.Request) -> httpx.Response:
            scope = request.headers.get("x-test-route-scope", "unknown")
            counts[scope] += 1
            body = f'data: {{"type":"response.completed","scope":"{scope}"}}\n\n'.encode()
            return httpx.Response(200, content=body, request=request)

        lease, capability = create_lease(1234, "start")
        router = EgressRouter(lease, capability, transport=httpx.MockTransport(handler))

        async def run() -> list[object]:
            outcomes = []
            for index in range(60):
                scope = "main" if index % 2 == 0 else "spawned"
                outcomes.append(
                    await router.forward(
                        upstream_url="https://example.invalid/v1/responses",
                        body=scope.encode(),
                        headers={"x-test-route-scope": scope},
                    )
                )
            return outcomes

        outcomes = asyncio.run(run())
        self.assertEqual(counts, {"main": 30, "spawned": 30})
        self.assertEqual(len(outcomes), 60)
        self.assertTrue(all(outcome.terminal for outcome in outcomes))
        self.assertTrue(all(not outcome.passthrough for outcome in outcomes))

    def test_asgi_health_is_explicitly_non_production(self) -> None:
        lease, capability = create_lease(1234, "start")
        app = create_egress_app(
            EgressRouter(lease, capability, transport=self._transport(200, b"")),
            "https://example.invalid",
        )

        async def run() -> None:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            ) as client:
                response = await client.get("/health")
                self.assertEqual(
                    response.json(), {"ready": True, "native": False, "production": False}
                )

        asyncio.run(run())

    def test_canary_monitor_is_redacted_and_isolated(self) -> None:
        async def run() -> None:
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=monitor_app), base_url="http://test"
            ) as client:
                response = await client.get("/health")
                self.assertEqual(response.status_code, 200)
                body = response.json()
                self.assertEqual(body["service"], "route-c-canary-monitor")
                self.assertEqual(body["route_scope"], "isolated")
                self.assertEqual(body["official_dataplane"], "not_proven")
                self.assertNotIn("credentials", body)
                self.assertNotIn("session", body)

        asyncio.run(run())


if __name__ == "__main__":
    unittest.main()

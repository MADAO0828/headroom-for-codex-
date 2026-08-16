from __future__ import annotations

import asyncio
import inspect
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any

import httpx

from kompress_broker.app import BrokerConfig, create_app


class FakeWorker:
    mode = "ok"

    def __init__(self, config: BrokerConfig) -> None:
        self.config = config
        self.provider = "FakeExecutionProvider"
        self.backend = "fake"

    def start(self) -> None:
        return None

    def stop(self) -> None:
        return None

    def request(self, payload: dict[str, Any], timeout: float) -> dict[str, Any]:
        if self.mode == "canary_malformed" and payload["content"].startswith("Headroom validates"):
            return {"id": payload["id"], "ok": True, "compressed": 123}
        if payload["op"] == "compress" and payload["content"].startswith("Headroom validates"):
            return {
                "id": payload["id"],
                "ok": True,
                "compressed": "canary",
                "original_tokens": 30,
                "compressed_tokens": 1,
            }
        if self.mode == "timeout":
            time.sleep(timeout * 4)
        if self.mode == "crash":
            raise RuntimeError("worker crashed")
        if self.mode == "decode":
            raise ValueError("worker response decode error")
        if self.mode == "error":
            return {"id": payload["id"], "ok": False, "error_code": "provider_error"}
        if self.mode == "device":
            return {"id": payload["id"], "ok": False, "error_code": "device_lost_887a0005"}
        if self.mode == "malformed":
            return {"id": payload["id"], "ok": True, "compressed": 123}
        return {
            "id": payload["id"],
            "ok": True,
            "compressed": "short result",
            "original_tokens": len(payload["content"].split()),
            "compressed_tokens": 2,
            "compression_ratio": 0.2,
            "provider": self.provider,
            "backend": self.backend,
            "model_used": "test",
        }


class BrokerContractTests(unittest.IsolatedAsyncioTestCase):
    async def _run_handlers(self, handlers: list[Any]) -> None:
        for handler in handlers:
            result = handler()
            if inspect.isawaitable(result):
                await result

    async def asyncSetUp(self) -> None:
        FakeWorker.mode = "ok"
        config = BrokerConfig(
            worker_python=Path(__file__),
            queue_limit=1,
            queue_wait_seconds=0.01,
            request_timeout_seconds=0.2,
            startup_timeout_seconds=1.0,
            max_content_bytes=4096,
        )
        self.app = create_app(config, worker_factory=FakeWorker)
        await self._run_handlers(self.app.router.on_startup)
        self.client = httpx.AsyncClient(
            transport=httpx.ASGITransport(app=self.app), base_url="http://test"
        )

    async def asyncTearDown(self) -> None:
        await self.client.aclose()
        await self._run_handlers(self.app.router.on_shutdown)

    async def test_ready_requires_real_canary(self) -> None:
        response = await self.client.get("/readyz")
        self.assertEqual(200, response.status_code)
        self.assertTrue(response.json()["ready"])
        self.assertEqual("FakeExecutionProvider", response.json()["provider"])

    async def test_compress_contract(self) -> None:
        response = await self.client.post(
            "/compress", json={"content": "one two three four five", "target_ratio": 0.5}
        )
        body = response.json()
        self.assertEqual(200, response.status_code)
        self.assertEqual("compressed", body["status"])
        self.assertEqual(5, body["original_tokens"])
        self.assertEqual(2, body["compressed_tokens"])
        self.assertNotIn("one two three", str(body))

    async def test_provider_error_fails_open(self) -> None:
        FakeWorker.mode = "error"
        content = "alpha beta gamma delta"
        response = await self.client.post("/compress", json={"content": content})
        body = response.json()
        self.assertEqual(200, response.status_code)
        self.assertEqual(content, body["compressed"])
        self.assertEqual("passthrough", body["status"])

    async def test_malformed_output_fails_open(self) -> None:
        FakeWorker.mode = "malformed"
        content = "alpha beta gamma delta"
        response = await self.client.post("/compress", json={"content": content})
        self.assertEqual(content, response.json()["compressed"])

    async def test_device_loss_opens_circuit(self) -> None:
        FakeWorker.mode = "device"
        content = "alpha beta gamma delta"
        first = await self.client.post("/compress", json={"content": content})
        second = await self.client.post("/compress", json={"content": content})
        self.assertEqual("device_lost_887a0005", first.json()["error_code"])
        self.assertEqual("provider_not_ready", second.json()["error_code"])

    async def test_invalid_payload_is_rejected_without_echo(self) -> None:
        response = await self.client.post("/compress", json={"content": 123})
        self.assertEqual(400, response.status_code)
        self.assertNotIn("123", response.text)

    async def test_invalid_json_and_ratio_are_rejected(self) -> None:
        invalid_json = await self.client.post("/compress", content=b"{not-json")
        self.assertEqual(400, invalid_json.status_code)
        self.assertNotIn("not-json", invalid_json.text)
        for ratio in (0, -0.1, 1.1, True, "not-a-number"):
            response = await self.client.post("/compress", json={"content": "safe", "target_ratio": ratio})
            self.assertEqual(400, response.status_code)

    async def test_malformed_canary_keeps_broker_not_ready(self) -> None:
        await self._run_handlers(self.app.router.on_shutdown)
        FakeWorker.mode = "canary_malformed"
        app = create_app(self.app.state.broker.config, worker_factory=FakeWorker)
        await self._run_handlers(app.router.on_startup)
        async with httpx.AsyncClient(
            transport=httpx.ASGITransport(app=app), base_url="http://test"
        ) as client:
            response = await client.get("/readyz")
        self.assertEqual(503, response.status_code)
        self.assertFalse(response.json()["ready"])
        await self._run_handlers(app.router.on_shutdown)

    async def test_timeout_crash_and_decode_fail_open(self) -> None:
        for mode, expected in (("timeout", "provider_timeout"), ("crash", "worker_crash"), ("decode", "decode_error")):
            FakeWorker.mode = mode
            content = f"{mode} body must pass through"
            response = await self.client.post("/compress", json={"content": content})
            body = response.json()
            self.assertEqual(200, response.status_code)
            self.assertEqual(content, body["compressed"])
            self.assertEqual("passthrough", body["status"])
            self.assertEqual(expected, body["error_code"])
            # A worker failure opens fail-open readiness until an explicit restart.
            next_response = await self.client.post("/compress", json={"content": content})
            self.assertEqual("provider_not_ready", next_response.json()["error_code"])
            await self._run_handlers(self.app.router.on_shutdown)
            FakeWorker.mode = "ok"
            await self._run_handlers(self.app.router.on_startup)

    async def test_state_file_never_contains_request_body(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            secret_body = "body-that-must-not-enter-state"
            config = BrokerConfig(
                worker_python=Path(__file__),
                queue_limit=1,
                queue_wait_seconds=0.01,
                request_timeout_seconds=0.2,
                startup_timeout_seconds=1.0,
                max_content_bytes=4096,
                state_path=Path(directory) / "state.json",
            )
            app = create_app(config, worker_factory=FakeWorker)
            await self._run_handlers(app.router.on_startup)
            async with httpx.AsyncClient(
                transport=httpx.ASGITransport(app=app), base_url="http://test"
            ) as client:
                response = await client.post("/compress", json={"content": secret_body})
                self.assertEqual(200, response.status_code)
            await self._run_handlers(app.router.on_shutdown)
            persisted = config.state_path.read_text(encoding="utf-8")
            self.assertNotIn(secret_body, persisted)

    async def test_correlation_receipt_is_returned_without_body(self) -> None:
        secret_body = "correlation-body-must-not-be-persisted"
        response = await self.client.post(
            "/compress",
            json={
                "content": secret_body,
                "request_id": "gw_request_123",
                "correlation_id": "corr_456",
            },
        )
        self.assertEqual(200, response.status_code)
        body = response.json()
        self.assertEqual("gw_request_123", body["request_id"])
        self.assertEqual("corr_456", body["correlation_id"])
        health = (await self.client.get("/health")).json()
        recent = health["recent_requests"][-1]
        self.assertEqual("gw_request_123", recent["request_id"])
        self.assertEqual("corr_456", recent["correlation_id"])
        self.assertNotIn(secret_body, str(health))

    async def test_queue_full_returns_passthrough(self) -> None:
        broker = self.app.state.broker
        await broker._capacity.acquire()
        await broker._capacity.acquire()
        try:
            content = "queue pressure input"
            response = await self.client.post("/compress", json={"content": content})
            self.assertEqual(content, response.json()["compressed"])
            self.assertEqual("queue_full", response.json()["error_code"])
        finally:
            broker._capacity.release()
            broker._capacity.release()


if __name__ == "__main__":
    unittest.main()

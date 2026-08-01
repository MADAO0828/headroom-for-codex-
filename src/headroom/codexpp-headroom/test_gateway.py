"""Mock-only contract tests for the local policy gateway."""

from __future__ import annotations

import asyncio
import gzip
import json
import tempfile
import unittest
from pathlib import Path
from typing import Any
from unittest.mock import patch

import httpx

import gateway


REAL_ASYNC_CLIENT = httpx.AsyncClient


class _Chunks(httpx.AsyncByteStream):
    async def __aiter__(self):
        yield b"data: first\n\n"
        yield b"data: second\n\n"


class _RawChunks(httpx.AsyncByteStream):
    def __init__(self, payload: bytes) -> None:
        self.payload = payload

    async def __aiter__(self):
        midpoint = max(1, len(self.payload) // 2)
        yield self.payload[:midpoint]
        yield self.payload[midpoint:]


class _TimeoutChunks(httpx.AsyncByteStream):
    async def __aiter__(self):
        yield b"data: first\n\n"
        raise httpx.ReadTimeout("upstream read timeout")


class _ErrorChunks(httpx.AsyncByteStream):
    async def __aiter__(self):
        yield b"data: first\n\n"
        raise RuntimeError("unexpected stream failure")


class _NonUtf8Chunks(httpx.AsyncByteStream):
    async def __aiter__(self):
        # Invalid UTF-8 is valid opaque upstream data for the gateway.  The
        # diagnostic probe must replace it only in its private copy.
        yield b"\xff\xfeopaque\n\n"
        yield b"data: still-open\n\n"


class FakeAsyncClient:
    """AsyncClient facade backed by a deterministic MockTransport."""

    handler = None
    instances: list["FakeAsyncClient"] = []
    raise_cancel = False
    raise_unexpected = False

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        transport = httpx.MockTransport(self.handler)
        self._client = REAL_ASYNC_CLIENT(*args, transport=transport, **kwargs)
        self.closed = False
        type(self).instances.append(self)

    async def __aenter__(self) -> "FakeAsyncClient":
        await self._client.__aenter__()
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self._client.__aexit__(*args)

    def build_request(self, *args: Any, **kwargs: Any) -> httpx.Request:
        return self._client.build_request(*args, **kwargs)

    async def send(self, *args: Any, **kwargs: Any) -> httpx.Response:
        if type(self).raise_cancel:
            raise asyncio.CancelledError
        if type(self).raise_unexpected:
            raise RuntimeError("unexpected upstream failure")
        return await self._client.send(*args, **kwargs)

    async def get(self, *args: Any, **kwargs: Any) -> httpx.Response:
        return await self._client.get(*args, **kwargs)

    async def aclose(self) -> None:
        self.closed = True
        await self._client.aclose()


class GatewayContractTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.requests: list[httpx.Request] = []
        self.mode = "ok"
        self.temp_dir = tempfile.TemporaryDirectory()
        self.state_path = Path(self.temp_dir.name) / "gateway-state.json"

        def handler(request: httpx.Request) -> httpx.Response:
            self.requests.append(request)
            if request.url.host == "headroom.test" and request.url.path == "/health":
                return httpx.Response(200, json={"status": "healthy", "ready": True}, request=request)
            if request.url.host == "helper.test" and request.url.path == "/health":
                if self.mode == "helper_down":
                    raise httpx.ConnectError("helper stopped", request=request)
                return httpx.Response(200, json={"status": "ok"}, request=request)
            if request.url.host == "helper.test" and request.url.path.startswith("/v1/"):
                if self.mode in {"timeout", "headroom_connect_error"}:
                    return httpx.Response(
                        200,
                        stream=_Chunks(),
                        headers={"content-type": "text/event-stream"},
                        request=request,
                    )
                return httpx.Response(404, request=request)
            if request.url.host == "headroom.test" and request.url.path.startswith("/v1/"):
                if self.mode == "upstream_down":
                    raise httpx.ConnectError("headroom stopped", request=request)
                if self.mode == "headroom_connect_error":
                    raise httpx.ConnectError("headroom connection unavailable", request=request)
                if self.mode == "timeout":
                    raise httpx.ReadTimeout("headroom timeout", request=request)
                if self.mode == "upstream_500":
                    return httpx.Response(500, text="sensitive upstream detail", request=request)
                if self.mode == "gzip":
                    return httpx.Response(
                        200,
                        stream=_RawChunks(gzip.compress(b"compressed payload")),
                        headers={"content-type": "application/octet-stream", "content-encoding": "gzip"},
                        request=request,
                    )
                if self.mode == "midstream_timeout":
                    return httpx.Response(
                        200,
                        stream=_TimeoutChunks(),
                        headers={"content-type": "text/event-stream"},
                        request=request,
                    )
                if self.mode == "midstream_error":
                    return httpx.Response(
                        200,
                        stream=_ErrorChunks(),
                        headers={"content-type": "text/event-stream"},
                        request=request,
                    )
                if self.mode == "non_utf8":
                    return httpx.Response(
                        200,
                        stream=_NonUtf8Chunks(),
                        headers={"content-type": "text/event-stream"},
                        request=request,
                    )
                if self.mode == "failed":
                    return httpx.Response(
                        200,
                        stream=_RawChunks(b'event: response.failed\ndata: {"type":"response.failed"}\n\n'),
                        headers={"content-type": "text/event-stream"},
                        request=request,
                    )
                if self.mode == "completed":
                    return httpx.Response(
                        200,
                        stream=_RawChunks(b'data: {"type":"response.completed"}\n\n'),
                        headers={"content-type": "text/event-stream"},
                        request=request,
                    )
                return httpx.Response(
                    200,
                    stream=_Chunks(),
                    headers={
                        "content-type": "text/event-stream",
                        "x-headroom-tokens-before": "100",
                        "x-headroom-tokens-after": "40",
                        "x-headroom-tokens-saved": "60",
                    },
                    request=request,
                )
            return httpx.Response(404, request=request)

        FakeAsyncClient.handler = staticmethod(handler)
        FakeAsyncClient.instances = []
        FakeAsyncClient.raise_cancel = False
        FakeAsyncClient.raise_unexpected = False
        self.original_client = gateway.httpx.AsyncClient
        gateway.httpx.AsyncClient = FakeAsyncClient  # type: ignore[assignment]
        self.app = gateway.create_app(
            gateway.GatewayConfig(
                headroom_url="http://headroom.test",
                helper_url="http://helper.test",
                connect_timeout=0.2,
                read_timeout=0.2,
                total_timeout=0.5,
                state_path=self.state_path,
            )
        )
        self.client = REAL_ASYNC_CLIENT(transport=httpx.ASGITransport(app=self.app), base_url="http://gateway.test")

    async def asyncTearDown(self) -> None:
        await self.client.aclose()
        gateway.httpx.AsyncClient = self.original_client
        FakeAsyncClient.raise_cancel = False
        FakeAsyncClient.raise_unexpected = False
        self.temp_dir.cleanup()

    async def test_streaming_main_task_compresses_and_records_tokens(self) -> None:
        response = await self.client.post(
            "/v1/responses",
            headers={"authorization": "Bearer secret", "x-headroom-bypass": "true"},
            json={"input": "main", "thread_source": "thread_spawn"},
        )
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"data: first", response.content)
        self.assertIn(b"response.failed", response.content)
        upstream = next(item for item in self.requests if item.url.path == "/v1/responses")
        self.assertNotIn("x-headroom-bypass", {key.lower() for key in upstream.headers})
        self.assertEqual(upstream.headers["authorization"], "Bearer secret")
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        metric = state["recent"][-1]
        self.assertEqual(metric["policy"], "main_compress")
        self.assertEqual(metric["token"], {"before": 100, "after": 40, "saved": 60})
        self.assertGreater(metric["cache_observation"]["input_size_bytes"], 0)
        self.assertEqual(metric["cache_observation"]["segment_hashes"][0]["key"], "input")
        self.assertEqual(state["token_accounting"]["completed_samples"], 1)
        self.assertEqual(state["token_accounting"]["saved"], 60)
        self.assertNotIn("secret", json.dumps(state))

    async def test_responses_midstream_timeout_emits_terminal_failure_event(self) -> None:
        self.mode = "midstream_timeout"
        response = await self.client.post("/v1/responses", json={"input": "timeout"})
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"data: first", response.content)
        self.assertIn(b"response.failed", response.content)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["recent"][-1]["result"], "timeout")

    async def test_responses_completed_event_is_not_replaced(self) -> None:
        self.mode = "completed"
        response = await self.client.post("/v1/responses", json={"input": "completed"})
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"response.completed", response.content)
        self.assertNotIn(b"response.failed", response.content)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["recent"][-1]["result"], "ok")

    async def test_responses_failed_event_is_recorded_as_failure(self) -> None:
        self.mode = "failed"
        response = await self.client.post("/v1/responses", json={"input": "failed"})
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"response.failed", response.content)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["recent"][-1]["result"], "upstream_failed")

    async def test_responses_unexpected_midstream_error_is_terminalized(self) -> None:
        self.mode = "midstream_error"
        response = await self.client.post("/v1/responses", json={"input": "error"})
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"response.failed", response.content)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["recent"][-1]["result"], "upstream_read_error")

    async def test_non_utf8_sse_bytes_are_preserved_and_eof_is_terminalized(self) -> None:
        self.mode = "non_utf8"
        response = await self.client.post("/v1/responses", json={"input": "non-utf8"})
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"\xff\xfeopaque\n\n", response.content)
        self.assertIn(b"data: still-open\n\n", response.content)
        self.assertIn(b"response.failed", response.content)

    async def test_sse_diagnostic_failure_does_not_truncate_raw_stream(self) -> None:
        with patch.object(gateway, "_sse_terminal_state", side_effect=RuntimeError("probe failed")):
            response = await self.client.post("/v1/responses", json={"input": "probe-failure"})
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"data: first\n\n", response.content)
        self.assertIn(b"data: second\n\n", response.content)
        self.assertIn(b"response.failed", response.content)

    async def test_metrics_failure_does_not_break_stream_or_cleanup(self) -> None:
        with patch.object(gateway.MetricsStore, "record", side_effect=RuntimeError("metrics unavailable")):
            response = await self.client.post("/v1/responses", json={"input": "metrics-failure"})
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"data: first\n\n", response.content)
        self.assertTrue(FakeAsyncClient.instances[-1].closed)

    async def test_gzip_content_encoding_and_body_are_preserved(self) -> None:
        self.mode = "gzip"
        response = await self.client.post("/v1/responses", json={"input": "gzip"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers.get("content-encoding"), "gzip")
        self.assertEqual(response.content, b"compressed payload")

    async def test_metrics_store_normalizes_corrupt_state_and_metric(self) -> None:
        path = Path(self.temp_dir.name) / "corrupt-state.json"
        path.write_text(
            json.dumps(
                {
                    "schema_version": "bad",
                    "service": {"bad": True},
                    "updated_at": 123,
                    "counters": {"total": "oops", "ok": None, "error": {"bad": True}, "timeout": "2"},
                    "recent": [{"result": "ok", "latency_ms": "nan", "token": {"before": "bad"}}, "bad"],
                }
            ),
            encoding="utf-8",
        )
        store = gateway.MetricsStore(path)
        store.record({"result": "ok", "latency_ms": object(), "token": {"before": object()}})
        state = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(state["counters"]["total"], 1)
        self.assertEqual(state["counters"]["ok"], 1)
        self.assertEqual(state["counters"]["timeout"], 2)
        self.assertIsNone(state["recent"][-1]["latency_ms"])
        self.assertIsNone(state["recent"][-1]["token"])
        self.assertTrue(state["recent"][-1]["token_invalid"])
        self.assertEqual(state["token_accounting"]["invalid_samples"], 1)

    def test_metrics_store_rejects_malformed_cache_observation(self) -> None:
        path = Path(self.temp_dir.name) / "malformed-cache-state.json"
        path.write_text(
            json.dumps({"recent": [{"cache_observation": {"segment_hashes": None, "transforms": None}}]}),
            encoding="utf-8",
        )
        store = gateway.MetricsStore(path)
        store.record({"result": "ok", "cache_observation": {"segment_hashes": None, "transforms": None}})
        state = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(state["recent"][-1]["cache_observation"]["segment_hashes"], [])
        self.assertEqual(state["recent"][-1]["cache_observation"]["transforms"], [])

    def test_metrics_store_does_not_count_all_malformed_token_fields_as_zero_savings(self) -> None:
        path = Path(self.temp_dir.name) / "malformed-token-state.json"
        store = gateway.MetricsStore(path)
        store.record({"result": "ok", "token": {"before": "bad", "after": "bad", "saved": "bad"}})
        state = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(state["token_accounting"]["completed_samples"], 0)
        self.assertEqual(state["token_accounting"]["invalid_samples"], 1)
        self.assertTrue(state["recent"][-1]["token_invalid"])

    async def test_metrics_store_tracks_exact_token_contract(self) -> None:
        path = Path(self.temp_dir.name) / "token-state.json"
        store = gateway.MetricsStore(path)
        store.record({"result": "ok", "token": {"before": 100, "after": 80, "saved": 20}})
        store.record({"result": "ok", "token": {"before": 100, "after": 90, "saved": 2}})
        store.record({"result": "ok", "token": None})
        state = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(state["token_accounting"]["completed_samples"], 1)
        self.assertEqual(state["token_accounting"]["saved"], 20)
        self.assertEqual(state["token_accounting"]["invalid_samples"], 1)
        self.assertEqual(state["token_accounting"]["missing_samples"], 1)

    def test_metrics_store_rejects_inconsistent_persisted_token_aggregate(self) -> None:
        path = Path(self.temp_dir.name) / "inconsistent-token-state.json"
        path.write_text(
            json.dumps(
                {
                    "token_accounting": {
                        "input_before": 100,
                        "input_after": 80,
                        "saved": 5,
                        "completed_samples": 1,
                        "missing_samples": 0,
                        "invalid_samples": 0,
                    }
                }
            ),
            encoding="utf-8",
        )
        store = gateway.MetricsStore(path)
        store.record({"result": "ok", "token": None})
        state = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(state["token_accounting"]["invalid_samples"], 1)

        missing_path = Path(self.temp_dir.name) / "missing-token-state.json"
        missing_path.write_text(
            json.dumps(
                {
                    "token_accounting": {
                        "input_before": 100,
                        "input_after": 80,
                        "completed_samples": 1,
                        "missing_samples": 0,
                        "invalid_samples": 0,
                    }
                }
            ),
            encoding="utf-8",
        )
        missing_store = gateway.MetricsStore(missing_path)
        missing_store.record({"result": "ok", "token": None})
        missing_state = json.loads(missing_path.read_text(encoding="utf-8"))
        self.assertGreaterEqual(missing_state["token_accounting"]["missing_samples"], 1)
        self.assertEqual(missing_state["token_accounting"]["invalid_samples"], 0)

    async def test_timeout_env_rejects_nonfinite_and_out_of_range_values(self) -> None:
        with patch.dict("os.environ", {"POLICY_GATEWAY_CONNECT_TIMEOUT": "nan"}, clear=False):
            self.assertEqual(gateway.GatewayConfig.from_env().connect_timeout, 2.0)
        with patch.dict("os.environ", {"POLICY_GATEWAY_CONNECT_TIMEOUT": "inf"}, clear=False):
            self.assertEqual(gateway.GatewayConfig.from_env().connect_timeout, 2.0)
        with patch.dict("os.environ", {"POLICY_GATEWAY_CONNECT_TIMEOUT": "3601"}, clear=False):
            self.assertEqual(gateway.GatewayConfig.from_env().connect_timeout, 2.0)

    async def test_unexpected_send_exception_closes_client_and_returns_stable_error(self) -> None:
        FakeAsyncClient.raise_unexpected = True
        response = await self.client.post("/v1/responses", json={"input": "unexpected"})
        self.assertEqual(response.status_code, 502)
        self.assertEqual(response.json()["error"]["message"], "policy_gateway_upstream_unavailable")
        self.assertTrue(FakeAsyncClient.instances[-1].closed)

    async def test_cancelled_send_closes_client_and_propagates_cancel(self) -> None:
        FakeAsyncClient.raise_cancel = True
        with self.assertRaises(asyncio.CancelledError):
            await self.client.post("/v1/responses", json={"input": "cancel"})
        self.assertTrue(FakeAsyncClient.instances[-1].closed)

    async def test_spawned_signals_bypass_but_thread_source_alone_does_not(self) -> None:
        await self.client.post("/v1/responses", headers={"x-openai-subagent": "collab_spawn"}, json={"input": "spawned"})
        spawned = next(item for item in reversed(self.requests) if item.url.path == "/v1/responses")
        self.assertEqual(spawned.headers["x-headroom-bypass"], "true")
        await self.client.post(
            "/v1/responses",
            headers={"x-codex-parent-thread-id": "parent-opaque" , "subagent_kind": "thread_spawn"},
            json={"input": "spawned"},
        )
        body_spawned = next(item for item in reversed(self.requests) if item.url.path == "/v1/responses")
        self.assertEqual(body_spawned.headers["x-headroom-bypass"], "true")
        await self.client.post("/v1/responses", json={"thread_source": "thread_spawn", "input": "normal"})
        normal = next(item for item in reversed(self.requests) if item.url.path == "/v1/responses")
        self.assertNotIn("x-headroom-bypass", {key.lower() for key in normal.headers})
        await self.client.post("/v1/responses", headers={"x-openai-subagent": "false"}, json={"input": "normal"})
        explicit_false = next(item for item in reversed(self.requests) if item.url.path == "/v1/responses")
        self.assertNotIn("x-headroom-bypass", {key.lower() for key in explicit_false.headers})

        await self.client.post("/v1/responses", headers={"x-openai-subagent": "mystery"}, json={"input": "normal"})
        unknown = next(item for item in reversed(self.requests) if item.url.path == "/v1/responses")
        self.assertNotIn("x-headroom-bypass", {key.lower() for key in unknown.headers})
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["classification_diagnostics"]["unknown_turn_metadata"], 1)

    async def test_structured_metadata_and_collab_spawn_bypass(self) -> None:
        metadata = json.dumps({"subagent_kind": "thread_spawn", "parent_thread_id": "opaque-parent"})
        await self.client.post("/v1/responses", headers={"x-codex-turn-metadata": metadata}, json={"input": "metadata"})
        metadata_request = next(item for item in reversed(self.requests) if item.url.path == "/v1/responses")
        self.assertEqual(metadata_request.headers["x-headroom-bypass"], "true")

        await self.client.post("/v1/responses", headers={"x-openai-subagent": "collab_spawn"}, json={"input": "collab"})
        collab_request = next(item for item in reversed(self.requests) if item.url.path == "/v1/responses")
        self.assertEqual(collab_request.headers["x-headroom-bypass"], "true")

    async def test_metadata_without_parent_or_malformed_is_main_with_diagnostics(self) -> None:
        await self.client.post(
            "/v1/responses",
            headers={"x-codex-turn-metadata": json.dumps({"subagent_kind": "thread_spawn"})},
            json={"input": "missing-parent"},
        )
        missing = next(item for item in reversed(self.requests) if item.url.path == "/v1/responses")
        self.assertNotIn("x-headroom-bypass", {key.lower() for key in missing.headers})

        await self.client.post(
            "/v1/responses",
            headers={"x-codex-turn-metadata": "{bad"},
            json={"input": "malformed"},
        )
        malformed = next(item for item in reversed(self.requests) if item.url.path == "/v1/responses")
        self.assertNotIn("x-headroom-bypass", {key.lower() for key in malformed.headers})
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["classification_diagnostics"]["missing_parent_thread_id"], 1)
        self.assertEqual(state["classification_diagnostics"]["malformed_turn_metadata"], 1)
        await self.client.post(
            "/v1/responses",
            headers={"x-codex-turn-metadata": json.dumps({"subagent_kind": "future_kind", "parent_thread_id": "opaque"})},
            json={"input": "unknown"},
        )
        unknown = next(item for item in reversed(self.requests) if item.url.path == "/v1/responses")
        self.assertNotIn("x-headroom-bypass", {key.lower() for key in unknown.headers})
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["classification_diagnostics"]["unknown_turn_metadata"], 1)
        self.assertNotIn("opaque-parent", json.dumps(state))

        await self.client.post(
            "/v1/responses",
            headers={
                "x-codex-turn-metadata": json.dumps(
                    {"subagent_kind": "thread_spawn", "parent_thread_id": 123}
                )
            },
            json={"input": "unknown-parent-type"},
        )
        unknown_parent_type = next(
            item for item in reversed(self.requests) if item.url.path == "/v1/responses"
        )
        self.assertNotIn("x-headroom-bypass", {key.lower() for key in unknown_parent_type.headers})
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["classification_diagnostics"]["unknown_turn_metadata"], 2)

    async def test_damaged_metadata_cannot_be_upgraded_by_legacy_spawn_signals(self) -> None:
        await self.client.post(
            "/v1/responses",
            headers={
                "x-codex-turn-metadata": "{bad",
                "x-openai-subagent": "collab_spawn",
                "subagent_kind": "thread_spawn",
                "x-codex-parent-thread-id": "legacy-parent",
            },
            json={"input": "damaged-metadata"},
        )
        forwarded = next(item for item in reversed(self.requests) if item.url.path == "/v1/responses")
        self.assertNotIn("x-headroom-bypass", {key.lower() for key in forwarded.headers})
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["recent"][-1]["request_class"], "main")
        self.assertEqual(state["recent"][-1]["policy_mode"], "compress")
        self.assertEqual(state["classification_diagnostics"]["malformed_turn_metadata"], 1)

    async def test_stable_errors_and_dependency_health(self) -> None:
        self.mode = "upstream_down"
        response = await self.client.post("/v1/chat/completions", json={"input": "x"})
        self.assertEqual(response.status_code, 502)
        self.assertEqual(response.json()["error"]["message"], "policy_gateway_upstream_unavailable")
        self.assertNotIn("sensitive", response.text)
        self.mode = "helper_down"
        response = await self.client.get("/health")
        self.assertEqual(response.status_code, 503)
        self.assertFalse(response.json()["ready"])

    async def test_connect_error_before_connect_falls_back_once(self) -> None:
        self.mode = "headroom_connect_error"
        response = await self.client.post("/v1/responses", json={"input": "connect-error"})
        self.assertEqual(response.status_code, 200)
        self.assertIn(b"data: first\n\n", response.content)
        self.assertEqual(response.content.count(b"event: response.failed\n"), 1)
        headroom_requests = [
            item for item in self.requests if item.url.host == "headroom.test" and item.url.path == "/v1/responses"
        ]
        helper_requests = [
            item for item in self.requests if item.url.host == "helper.test" and item.url.path == "/v1/responses"
        ]
        self.assertEqual(len(headroom_requests), 1)
        self.assertEqual(len(helper_requests), 1)
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["recent"][-1]["fallback"], "headroom_connect_error")

    async def test_headroom_http_500_does_not_retry_non_idempotent_post(self) -> None:
        self.mode = "upstream_500"
        response = await self.client.post("/v1/responses", json={"input": "server-error"})
        self.assertEqual(response.status_code, 502)
        self.assertNotIn("sensitive", response.text)
        headroom_requests = [
            item for item in self.requests if item.url.host == "headroom.test" and item.url.path == "/v1/responses"
        ]
        helper_requests = [
            item for item in self.requests if item.url.host == "helper.test" and item.url.path == "/v1/responses"
        ]
        self.assertEqual(len(headroom_requests), 1)
        self.assertEqual(helper_requests, [])
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["recent"][-1]["fallback"], "headroom_http_500")

    async def test_headroom_read_timeout_does_not_retry_non_idempotent_post(self) -> None:
        self.mode = "timeout"
        response = await self.client.post("/v1/chat/completions", json={"input": "read-timeout"})
        self.assertEqual(response.status_code, 504)
        headroom_requests = [
            item for item in self.requests if item.url.host == "headroom.test" and item.url.path == "/v1/chat/completions"
        ]
        helper_requests = [
            item for item in self.requests if item.url.host == "helper.test" and item.url.path == "/v1/chat/completions"
        ]
        self.assertEqual(len(headroom_requests), 1)
        self.assertEqual(helper_requests, [])
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["recent"][-1]["result"], "timeout")
        self.assertEqual(state["recent"][-1]["fallback"], "headroom_timeout")

    async def test_compress_contract_times_out_to_zero_change_passthrough(self) -> None:
        self.mode = "timeout"
        response = await self.client.post(
            "/v1/compress",
            json={"model": "gpt-5", "messages": [{"role": "user", "content": "x"}]},
        )
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertEqual(payload["tokens_before"], 0)
        self.assertEqual(payload["tokens_after"], 0)
        self.assertEqual(payload["tokens_saved"], 0)
        self.assertTrue(payload["passthrough"])
        state = json.loads(self.state_path.read_text(encoding="utf-8"))
        self.assertEqual(state["recent"][-1]["fallback"], "compression_passthrough")

    async def test_livez_is_process_only_and_headroom_strips_bypass(self) -> None:
        response = await self.client.get("/livez")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(self.requests), 0)
        from headroom.proxy.internal_header_policy import strip_internal_headers

        forwarded = strip_internal_headers({"x-headroom-bypass": "true", "authorization": "Bearer x"}, mode="enabled")
        self.assertNotIn("x-headroom-bypass", forwarded)
        self.assertEqual(forwarded["authorization"], "Bearer x")


if __name__ == "__main__":  # pragma: no cover
    unittest.main()

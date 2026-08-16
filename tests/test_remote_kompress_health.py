from __future__ import annotations

import importlib.util
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import patch

import httpx


ROOT = Path(__file__).resolve().parents[1]


def _load_remote_patch():
    """Load the source overlay instead of the unpatched runtime copy."""

    module_name = "headroom.transforms.kompress_remote"
    sys.modules.pop(module_name, None)
    module_path = (
        ROOT
        / "src"
        / "headroom"
        / "site-packages-patches"
        / "headroom"
        / "transforms"
        / "kompress_remote.py"
    )
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("remote_patch_spec_missing")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def _load_content_router_patch():
    module_name = "headroom.transforms.content_router"
    sys.modules.pop(module_name, None)
    module_path = (
        ROOT
        / "src"
        / "headroom"
        / "site-packages-patches"
        / "headroom"
        / "transforms"
        / "content_router.py"
    )
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("content_router_patch_spec_missing")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


class _FakeResponse:
    def __init__(self, payload: object, status_code: int = 200) -> None:
        self._payload = payload
        self.status_code = status_code

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            request = httpx.Request("GET", "http://broker/readyz")
            response = httpx.Response(self.status_code, request=request)
            raise httpx.HTTPStatusError("status", request=request, response=response)

    def json(self) -> object:
        if isinstance(self._payload, BaseException):
            raise self._payload
        return self._payload


class _FakeClient:
    def __init__(self, *, ready: object = None, post: object = None) -> None:
        self.ready = ready
        self.post_result = post
        self.get_calls: list[dict[str, object]] = []
        self.post_calls: list[dict[str, object]] = []

    def get(self, url: str, **kwargs: object) -> _FakeResponse:
        self.get_calls.append({"url": url, **kwargs})
        if isinstance(self.ready, BaseException):
            raise self.ready
        return self.ready  # type: ignore[return-value]

    def post(self, url: str, **kwargs: object) -> _FakeResponse:
        self.post_calls.append({"url": url, **kwargs})
        if isinstance(self.post_result, BaseException):
            raise self.post_result
        return self.post_result  # type: ignore[return-value]

    def close(self) -> None:
        return None


class RemoteKompressReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.remote = _load_remote_patch()
        from headroom.transforms.kompress_compressor import KompressConfig

        cls.config_type = KompressConfig

    def _compressor(self, fake: _FakeClient, *, timeout: float = 20.0):
        with patch.object(self.remote.httpx, "Client", return_value=fake):
            return self.remote.RemoteKompressCompressor(
                "http://127.0.0.1:18889",
                token="test-token",
                config=self.config_type(enable_ccr=False),
                timeout=timeout,
            )

    def test_preload_requires_healthy_ready_contract_and_exposes_metadata(self) -> None:
        fake = _FakeClient(
            ready=_FakeResponse(
                {
                    "service": "kompress-broker",
                    "status": "healthy",
                    "ready": True,
                    "provider": "CPUExecutionProvider",
                    "backend": "onnx_cpu",
                }
            )
        )
        compressor = self._compressor(fake, timeout=30.0)

        self.assertEqual("loaded", compressor.preload(allow_download=False))
        self.assertTrue(compressor.is_ready())
        self.assertEqual("CPUExecutionProvider", compressor.provider)
        self.assertEqual("onnx_cpu", compressor.backend)
        self.assertEqual(3.0, compressor._readiness_timeout)
        self.assertEqual("http://127.0.0.1:18889/readyz", fake.get_calls[0]["url"])
        self.assertNotIn("json", fake.get_calls[0])
        self.assertNotIn("content", fake.get_calls[0])

    def test_unreachable_broker_is_non_ready_and_compress_fails_open(self) -> None:
        error = httpx.ConnectError("connection refused")
        fake = _FakeClient(ready=error, post=error)
        compressor = self._compressor(fake)

        self.assertEqual("unavailable", compressor.preload())
        self.assertFalse(compressor.is_ready())
        self.assertEqual("broker_unreachable", compressor.preload_error)

        original = "one two three four five six seven eight nine ten eleven twelve"
        result = compressor.compress(original)
        self.assertEqual(original, result.compressed)
        self.assertFalse(compressor.is_ready())

    def test_malformed_readiness_and_compress_payloads_fail_open(self) -> None:
        malformed_ready = _FakeClient(
            ready=_FakeResponse(
                {"status": "healthy", "ready": True, "provider": "", "backend": "onnx_cpu"}
            )
        )
        compressor = self._compressor(malformed_ready)
        self.assertEqual("unavailable", compressor.preload())
        self.assertFalse(compressor.is_ready())
        self.assertEqual("broker_contract_error", compressor.preload_error)

        malformed_response = _FakeClient(
            ready=_FakeResponse(
                {
                    "service": "kompress-broker",
                    "status": "healthy",
                    "ready": True,
                    "provider": "CPUExecutionProvider",
                    "backend": "onnx_cpu",
                }
            ),
            post=_FakeResponse({"compressed": 123}),
        )
        compressor = self._compressor(malformed_response)
        self.assertEqual("loaded", compressor.preload())
        original = "one two three four five six seven eight nine ten eleven twelve"
        result = compressor.compress(original)
        self.assertEqual(original, result.compressed)
        self.assertFalse(compressor.is_ready())

    def test_content_router_eager_probe_bridges_remote_metadata(self) -> None:
        router_module = _load_content_router_patch()

        class FakeRemote:
            is_remote = True
            provider = "CPUExecutionProvider"
            backend = "onnx_cpu"
            preload_error = None

            def preload(self, *, allow_download: bool) -> str:
                self.allow_download = allow_download
                return "loaded"

        compressor = FakeRemote()
        router = object.__new__(router_module.ContentRouter)
        router.config = router_module.ContentRouterConfig(enable_code_aware=False)
        router._get_kompress = lambda: compressor
        router._get_smart_crusher = lambda: None

        status = router.eager_load_compressors()
        self.assertEqual("loaded", status["kompress"])
        self.assertEqual("CPUExecutionProvider", status["kompress_provider"])
        self.assertEqual("onnx_cpu", status["kompress_backend"])
        self.assertFalse(compressor.allow_download)

    def test_failed_request_recovers_through_single_flight_background_probe(self) -> None:
        healthy = _FakeResponse(
            {
                "service": "kompress-broker",
                "status": "healthy",
                "ready": True,
                "provider": "CPUExecutionProvider",
                "backend": "onnx_cpu",
            }
        )
        fake = _FakeClient(ready=healthy, post=httpx.ConnectError("connection refused"))
        compressor = self._compressor(fake)
        self.assertEqual("loaded", compressor.preload())

        original = "one two three four five six seven eight nine ten eleven twelve"
        self.assertEqual(original, compressor.compress(original).compressed)
        self.assertFalse(compressor.is_ready())

        for _ in range(5):
            compressor.ensure_background_load()
        deadline = time.monotonic() + 2.0
        while not compressor.is_ready() and time.monotonic() < deadline:
            time.sleep(0.01)

        self.assertTrue(compressor.is_ready())
        self.assertEqual("CPUExecutionProvider", compressor.provider)
        self.assertEqual(2, len(fake.get_calls))

    def test_request_context_is_forwarded_as_opaque_correlation(self) -> None:
        fake = _FakeClient(
            ready=_FakeResponse(
                {
                    "service": "kompress-broker",
                    "status": "healthy",
                    "ready": True,
                    "provider": "CPUExecutionProvider",
                    "backend": "onnx_cpu",
                }
            ),
            post=_FakeResponse(
                {
                    "compressed": "short result",
                    "original_tokens": 12,
                    "compressed_tokens": 2,
                    "compression_ratio": 0.2,
                }
            ),
        )
        compressor = self._compressor(fake)
        self.assertEqual("loaded", compressor.preload())
        token = self.remote.set_compression_request_context("gw_123", "corr_456")
        try:
            result = compressor.compress(
                "one two three four five six seven eight nine ten eleven twelve"
            )
        finally:
            self.remote.reset_compression_request_context(token)
        self.assertEqual("short result", result.compressed)
        call = fake.post_calls[0]
        self.assertEqual("gw_123", call["json"]["request_id"])
        self.assertEqual("corr_456", call["json"]["correlation_id"])
        self.assertEqual("corr_456", call["headers"]["x-headroom-correlation-id"])


if __name__ == "__main__":
    unittest.main()

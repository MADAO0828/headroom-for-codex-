from __future__ import annotations

import asyncio
import importlib.util
import os
import sys
import types
import unittest
import time
from pathlib import Path
from unittest.mock import patch

from fastapi.responses import Response, StreamingResponse


ROOT = Path(__file__).resolve().parents[1]
PATCH_ROOT = ROOT / "src" / "headroom" / "site-packages-patches"
if str(PATCH_ROOT) not in sys.path:
    sys.path.insert(0, str(PATCH_ROOT))


def _load_openai_patch():
    """Load the project OpenAI handler overlay, not the installed wheel copy."""
    import headroom.proxy.handlers as handlers

    module_name = "headroom.proxy.handlers.openai"
    module_path = PATCH_ROOT / "headroom" / "proxy" / "handlers" / "openai.py"
    sys.modules.pop(module_name, None)
    spec = importlib.util.spec_from_file_location(module_name, module_path)
    if spec is None or spec.loader is None:
        raise RuntimeError("openai_patch_spec_missing")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    handlers.openai = module
    return module


openai_module = _load_openai_patch()
from headroom.transforms import compression_units


class _Tokenizer:
    @staticmethod
    def count_text(value: str) -> int:
        return len(value.split())


class _Provider:
    @staticmethod
    def get_token_counter(_model: str) -> _Tokenizer:
        return _Tokenizer()


class _Router:
    def __init__(self) -> None:
        self.config = types.SimpleNamespace(exclude_tools=None)
        self._cross_turn_dedup_enabled = False

    @staticmethod
    def _lossless_compact_excluded(_text: str):
        return None


def _fake_compress(unit, *, router, tokenizer, target_ratio=None):
    del router, target_ratio
    compressed = f"compressed:{unit.text[:12]}"
    before = tokenizer.count_text(unit.text)
    after = tokenizer.count_text(compressed)
    return compression_units.UnitCompressionResult(
        original=unit.text,
        compressed=compressed,
        modified=True,
        tokens_before=before,
        tokens_after=after,
        tokens_saved=max(0, before - after),
        transforms_applied=["fake:kompress"],
        strategy="fake",
        text_bytes=len(unit.text.encode("utf-8")),
        min_bytes=unit.min_bytes,
        reason_category="applied",
    )


class ResponsesCacheAwareCompressionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.handler = object.__new__(openai_module.OpenAIHandlerMixin)
        self.handler.openai_provider = _Provider()
        self.handler.openai_pipeline = types.SimpleNamespace(transforms=[_Router()])
        self.handler.config = types.SimpleNamespace()
        self.handler.OPENAI_RESPONSES_ROUTER_MIN_BYTES = 1
        self.calls = 0

        def counted(unit, *, router, tokenizer, target_ratio=None):
            self.calls += 1
            return _fake_compress(
                unit,
                router=router,
                tokenizer=tokenizer,
                target_ratio=target_ratio,
            )

        self.compress = counted
        self.patches = [
            patch.object(openai_module, "proxy_pipeline_kwargs", lambda _config: {}),
            patch.object(compression_units, "find_content_router", lambda _transforms: self.handler.openai_pipeline.transforms[0]),
            patch.object(compression_units, "compress_unit_with_router", self.compress),
        ]
        for item in self.patches:
            item.start()

    def tearDown(self) -> None:
        for item in reversed(self.patches):
            item.stop()

    def _compress(self, payload: dict) -> dict:
        result = self.handler._compress_openai_responses_live_text_units_with_router(
            payload,
            model="test-model",
            request_id="hr_test",
            correlation_id="corr_test",
        )
        return result[0]

    @staticmethod
    def _message(text: str) -> dict:
        return {
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": text}],
        }

    def test_historical_input_text_reuses_only_previous_live_result(self) -> None:
        history = "history " * 80
        first = self._compress({"input": [self._message(history)]})
        first_latest = first["input"][0]["content"][0]["text"]
        self.assertTrue(first_latest.startswith("compressed:"))
        self.assertEqual(1, self.calls)

        second = self._compress(
            {"input": [self._message(history), self._message("new latest " * 80)]}
        )
        self.assertEqual(first_latest, second["input"][0]["content"][0]["text"])
        self.assertTrue(second["input"][1]["content"][0]["text"].startswith("compressed:"))
        # The historical prefix is a cache hit; only the new live tail enters
        # the compressor again.
        self.assertEqual(2, self.calls)

    def test_historical_cache_miss_keeps_prefix_byte_stable(self) -> None:
        history = "unseen historical text " * 80
        payload = {"input": [self._message(history), self._message("latest " * 80)]}
        output = self._compress(payload)
        self.assertEqual(history, output["input"][0]["content"][0]["text"])
        self.assertEqual(1, self.calls)

    def test_string_input_keeps_wire_shape(self) -> None:
        text = "string input " * 80
        output = self._compress({"input": text})
        self.assertIsInstance(output["input"], str)
        self.assertTrue(output["input"].startswith("compressed:"))

    def test_single_unit_still_compresses_inside_soft_budget(self) -> None:
        payload = {
            "input": [
                {
                    "type": "function_call_output",
                    "call_id": "soft-budget-single",
                    "output": "single unit remains eligible " * 80,
                }
            ]
        }
        with patch.dict(
            os.environ,
            {
                openai_module._OPENAI_RESPONSES_SOFT_BUDGET_ENV: "0.05",
                openai_module._OPENAI_RESPONSES_UNIT_PARALLELISM_ENV: "1",
            },
            clear=False,
        ), patch.object(openai_module, "COMPRESSION_TIMEOUT_SECONDS", 1.0):
            output = self._compress(payload)
        self.assertTrue(output["input"][0]["output"].startswith("compressed:"))
        self.assertEqual(1, self.calls)

    def test_soft_budget_leaves_unscheduled_units_untouched(self) -> None:
        original_compress = self.compress

        def slow_first(unit, *, router, tokenizer, target_ratio=None):
            if self.calls == 0:
                time.sleep(0.04)
            return original_compress(
                unit,
                router=router,
                tokenizer=tokenizer,
                target_ratio=target_ratio,
            )

        payload = {
            "input": [
                {
                    "type": "function_call_output",
                    "call_id": "soft-budget-a",
                    "output": "first body stays compressed " * 80,
                },
                {
                    "type": "function_call_output",
                    "call_id": "soft-budget-b",
                    "output": "second body stays original " * 80,
                },
                {
                    "type": "function_call_output",
                    "call_id": "soft-budget-c",
                    "output": "third body stays original " * 80,
                },
            ]
        }
        with patch.dict(
            os.environ,
            {
                openai_module._OPENAI_RESPONSES_SOFT_BUDGET_ENV: "0.02",
                openai_module._OPENAI_RESPONSES_UNIT_PARALLELISM_ENV: "1",
            },
            clear=False,
        ), patch.object(openai_module, "COMPRESSION_TIMEOUT_SECONDS", 1.0), patch.object(
            compression_units,
            "compress_unit_with_router",
            slow_first,
        ), self.assertLogs(openai_module.logger, level="INFO") as captured:
            output = self._compress(payload)

        self.assertEqual(1, self.calls)
        self.assertTrue(output["input"][0]["output"].startswith("compressed:"))
        self.assertEqual(payload["input"][1]["output"], output["input"][1]["output"])
        self.assertEqual(payload["input"][2]["output"], output["input"][2]["output"])
        joined_logs = "\n".join(captured.output)
        self.assertIn("soft budget exhausted", joined_logs)
        self.assertNotIn("second body stays original", joined_logs)
        self.assertNotIn("third body stays original", joined_logs)


class ResponsesSoftBudgetContractTests(unittest.TestCase):
    def test_env_default_and_clamp_stay_below_executor_timeout(self) -> None:
        env_name = openai_module._OPENAI_RESPONSES_SOFT_BUDGET_ENV
        with patch.dict(os.environ, {env_name: ""}, clear=False), patch.object(
            openai_module, "COMPRESSION_TIMEOUT_SECONDS", 30.0
        ):
            self.assertEqual(20.0, openai_module._openai_responses_soft_budget_seconds())

        with patch.dict(os.environ, {env_name: "90"}, clear=False), patch.object(
            openai_module, "COMPRESSION_TIMEOUT_SECONDS", 30.0
        ):
            clamped = openai_module._openai_responses_soft_budget_seconds()
        self.assertLess(clamped, 30.0)
        self.assertGreaterEqual(clamped, 0.0)

        with patch.dict(os.environ, {env_name: "-2"}, clear=False), patch.object(
            openai_module, "COMPRESSION_TIMEOUT_SECONDS", 30.0
        ):
            self.assertEqual(0.0, openai_module._openai_responses_soft_budget_seconds())


class ResponsesTokenHeaderContractTests(unittest.TestCase):
    def test_valid_metrics_are_emitted_as_an_exact_triplet(self) -> None:
        headers = openai_module._openai_responses_token_headers(100, 40, 60)

        self.assertEqual(
            {
                "x-headroom-tokens-before": "100",
                "x-headroom-tokens-after": "40",
                "x-headroom-tokens-saved": "60",
            },
            headers,
        )

    def test_inconsistent_metrics_fall_back_to_no_compression(self) -> None:
        headers = openai_module._openai_responses_token_headers(100, 120, 0)

        self.assertEqual("100", headers["x-headroom-tokens-before"])
        self.assertEqual("100", headers["x-headroom-tokens-after"])
        self.assertEqual("0", headers["x-headroom-tokens-saved"])

    def test_invalid_metrics_fall_back_to_zero_triplet(self) -> None:
        headers = openai_module._openai_responses_token_headers(None, 40, 60)

        self.assertEqual(
            {
                "x-headroom-tokens-before": "0",
                "x-headroom-tokens-after": "0",
                "x-headroom-tokens-saved": "0",
            },
            headers,
        )

    def test_negative_metrics_fall_back_to_nonnegative_triplet(self) -> None:
        cases = (
            ("before", -1, 40, 60, ("0", "0", "0")),
            ("after", 100, -1, 101, ("100", "100", "0")),
            ("saved", 100, 40, -1, ("100", "100", "0")),
        )
        for field, before, after, saved, expected in cases:
            with self.subTest(field=field):
                headers = openai_module._openai_responses_token_headers(
                    before,
                    after,
                    saved,
                )
                self.assertEqual(expected[0], headers["x-headroom-tokens-before"])
                self.assertEqual(expected[1], headers["x-headroom-tokens-after"])
                self.assertEqual(expected[2], headers["x-headroom-tokens-saved"])

    def test_missing_after_or_saved_uses_known_before_as_fallback(self) -> None:
        headers = openai_module._openai_responses_token_headers(100, None, None)

        self.assertEqual("100", headers["x-headroom-tokens-before"])
        self.assertEqual("100", headers["x-headroom-tokens-after"])
        self.assertEqual("0", headers["x-headroom-tokens-saved"])

    def test_response_header_injection_preserves_json_body(self) -> None:
        expected = b'{"type":"response.completed"}'
        response = Response(content=expected, media_type="application/json")
        injected = openai_module._attach_openai_responses_token_headers(
            response,
            tokens_before=100,
            tokens_after=40,
            tokens_saved=60,
        )

        self.assertEqual(expected, injected.body)
        self.assertEqual("100", injected.headers["x-headroom-tokens-before"])
        self.assertEqual("40", injected.headers["x-headroom-tokens-after"])
        self.assertEqual("60", injected.headers["x-headroom-tokens-saved"])

    def test_stream_header_injection_preserves_sse_bytes(self) -> None:
        expected = b'data: {"type":"response.completed"}\n\n'

        async def source():
            yield expected

        response = StreamingResponse(source(), media_type="text/event-stream")
        injected = openai_module._attach_openai_responses_token_headers(
            response,
            tokens_before=100,
            tokens_after=40,
            tokens_saved=60,
        )

        async def collect() -> list[bytes]:
            return [chunk async for chunk in injected.body_iterator]

        self.assertEqual([expected], asyncio.run(collect()))
        self.assertEqual("100", injected.headers["x-headroom-tokens-before"])
        self.assertEqual("40", injected.headers["x-headroom-tokens-after"])
        self.assertEqual("60", injected.headers["x-headroom-tokens-saved"])


if __name__ == "__main__":
    unittest.main()

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path
from unittest import mock


_LAUNCHER_PATH = Path(__file__).with_name("headroom-launcher.py")
_SPEC = importlib.util.spec_from_file_location("headroom_launcher", _LAUNCHER_PATH)
assert _SPEC is not None and _SPEC.loader is not None
launcher = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(launcher)


class HeadroomLauncherTests(unittest.TestCase):
    def test_worker_count_accepts_cli_forms_and_environment_fallback(self) -> None:
        self.assertEqual(launcher._requested_worker_count(["proxy", "--workers", "2"]), 2)
        self.assertEqual(launcher._requested_worker_count(["proxy", "--workers=2"]), 2)
        with mock.patch.dict("os.environ", {"HEADROOM_WORKERS": "2"}, clear=False):
            self.assertEqual(launcher._requested_worker_count(["proxy"]), 2)

    def test_multi_worker_does_not_warm_supervisor(self) -> None:
        from headroom.cli import main as cli_module

        with mock.patch.object(launcher, "_warm_kompress") as warm:
            with mock.patch.object(cli_module, "main") as cli_main:
                launcher.main(["proxy", "--workers", "2"])

        warm.assert_not_called()
        cli_main.assert_called_once_with(args=["proxy", "--workers", "2"], prog_name="headroom")

    def test_single_worker_keeps_warmup(self) -> None:
        from headroom.cli import main as cli_module

        with mock.patch.object(launcher, "_warm_kompress") as warm:
            with mock.patch.object(cli_module, "main") as cli_main:
                launcher.main(["proxy", "--workers", "1"])

        warm.assert_called_once_with()
        cli_main.assert_called_once_with(args=["proxy", "--workers", "1"], prog_name="headroom")


if __name__ == "__main__":
    unittest.main()

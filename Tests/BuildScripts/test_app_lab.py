"""Verify that lab setup cannot launch an existing app or a second server."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location(
    "app_lab", Path(__file__).resolve().parents[2] / "scripts/app-lab.py"
)
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


class AppLabTests(unittest.TestCase):
    def test_stale_socket_cannot_prove_process_readiness(self):
        socket = self.root / "stale.sock"
        socket.touch()
        process = Mock(pid=123)
        process.poll.return_value = 1
        with patch.object(lab.subprocess, "run") as probe:
            with self.assertRaisesRegex(RuntimeError, "exited"):
                lab.wait_for_socket(process, str(socket), "herdr")
            probe.assert_not_called()
            process.poll.return_value = None
            probe.return_value = subprocess.CompletedProcess([], 0, f"p456\nn{socket}\n")
            with patch.object(lab.time, "sleep"):
                with self.assertRaisesRegex(RuntimeError, "did not appear"):
                    lab.wait_for_socket(process, str(socket), "herdr")
            probe.return_value = subprocess.CompletedProcess([], 0, f"p123\nn{socket}\n")
            lab.wait_for_socket(process, str(socket), "herdr")
            alias = self.root / "alias"
            alias.symlink_to(self.root, target_is_directory=True)
            probe.return_value = subprocess.CompletedProcess([], 0, f"p123\nn{alias / socket.name}\n")
            lab.wait_for_socket(process, str(socket), "herdr")

    def test_bridge_requires_listener_owned_by_the_test_app(self):
        process = Mock(pid=123)
        process.poll.return_value = None
        with patch.object(lab.subprocess, "run") as probe:
            probe.return_value = subprocess.CompletedProcess([], 0, "p123\n")
            lab.wait_for_bridge(process, "53810")
            self.assertIn("-iTCP:53810", probe.call_args.args[0])
            probe.return_value = subprocess.CompletedProcess([], 0, "p456\n")
            with patch.object(lab.time, "sleep"):
                with self.assertRaisesRegex(RuntimeError, "does not own"):
                    lab.wait_for_bridge(process, "53810")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rai-lab-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / "root_with_underscores"
        self.root.mkdir()
        binary = Path(self.temp.name) / "herdr"
        binary.write_text("#!/bin/sh\nexit 0\n")
        with patch.object(lab.tempfile, "mkdtemp", return_value=str(self.root)):
            with contextlib.redirect_stdout(io.StringIO()):
                lab.prepare(binary)
        self.manifest = json.loads((self.root / "lab.json").read_text())

    def test_prepared_lab_has_valid_identity_and_private_hook_route(self):
        self.assertRegex(self.manifest["lab_id"], r"^[a-z0-9][a-z0-9-]{0,31}$")
        environment = self.manifest["environment"]
        self.assertEqual(environment["RAI_HOOK_SOCKET_PATH"], str(self.root / "support/hooks.sock"))
        self.assertEqual(environment["ZDOTDIR"], str(self.root / "shell"))
        self.assertEqual(environment["CODEX_HOME"], str(self.root / "codex"))
        self.assertEqual(Path(environment["TMPDIR"]), self.root / "tmp")
        self.assertTrue(Path(environment["HERDR_BIN_PATH"]).is_file())
        self.assertNotEqual(environment["RAI_BRIDGE_PORT"], "47837")

    def test_foreign_ownership_stops_before_launch(self):
        (self.root / ".rai-lab-owned").write_text("gr.krig.rai")
        with patch.object(lab.subprocess, "Popen") as spawn:
            with self.assertRaisesRegex(ValueError, "ownership"):
                lab.launch(self.root, "/Applications/Rai.app")
            spawn.assert_not_called()

    def test_missing_install_lab_has_no_binary_and_uses_default_session(self):
        root = Path(self.temp.name).resolve() / "missing"
        root.mkdir()
        with patch.object(lab.tempfile, "mkdtemp", return_value=str(root)):
            with contextlib.redirect_stdout(io.StringIO()):
                lab.prepare()
        environment = json.loads((root / "lab.json").read_text())["environment"]
        self.assertEqual(environment["RAI_LAB_ALLOW_MISSING_HERDR"], "1")
        self.assertFalse(Path(environment["HERDR_BIN_PATH"]).exists())
        self.assertEqual(environment["HERDR_SOCKET_PATH"], str(root / "config/herdr/herdr.sock"))

    def test_recorded_app_prevents_starting_another_server(self):
        app = self.root / "apps/Lab.app"
        (app / "Contents").mkdir(parents=True)
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": self.manifest["bundle_id"]}, handle)
        for name in ("app.pid", "herdr-123.json"):
            record = self.root / name
            record.write_text("123")
            with patch.object(lab.subprocess, "Popen") as spawn:
                with self.assertRaisesRegex(ValueError, "recorded process"):
                    lab.launch(self.root, app)
                spawn.assert_not_called()
            record.unlink()

    def test_outside_bundle_stops_before_launch(self):
        with patch.object(lab.subprocess, "Popen") as spawn:
            with self.assertRaisesRegex(ValueError, "apps directory"):
                lab.launch(self.root, "/Applications/Rai.app")
            spawn.assert_not_called()

    def test_app_validation_failure_prevents_server_launch(self):
        app = self.root / "apps/Lab.app"
        (app / "Contents").mkdir(parents=True)
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleIdentifier": self.manifest["bundle_id"], "CFBundleExecutable": "rai"}, handle)
        with patch.object(lab.subprocess, "run", side_effect=subprocess.CalledProcessError(2, "rai")) as validate:
            with patch.object(lab.subprocess, "Popen") as spawn:
                with self.assertRaises(subprocess.CalledProcessError):
                    lab.launch(self.root, app)
                self.assertEqual(validate.call_args.args[0][-1], "--validate-lab")
                spawn.assert_not_called()


if __name__ == "__main__":
    unittest.main()

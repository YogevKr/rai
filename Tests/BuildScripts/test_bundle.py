"""Exercise bundle.sh with fake build/sign tools and real temporary app folders."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="rai-bundle-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copy(REPO / "scripts/bundle.sh", self.root / "scripts/bundle.sh")
        self.tools = self.root / "tools"
        self.tools.mkdir()
        self.build = self.root / "bin"
        self.build.mkdir()
        for name in ["rai", "rai-updater"]:
            binary = self.build / name
            binary.write_text("#!/bin/sh\nexit 0\n")
            binary.chmod(0o755)
        self.dest = self.root / "apps"
        self.dest.mkdir()
        self.release = self.dest / "Rai.app"
        self.release.mkdir()
        (self.release / "keep").write_text("installed release")
        self.tool("swift", 'echo swift >> "$TEST_LOG"\necho "$TEST_BIN"')
        self.tool("security", 'printf \'1) ABC "%s"\\n\' "$TEST_IDENTITY"')
        self.tool("codesign", 'echo "codesign $*" >> "$TEST_LOG"\nexit "${TEST_SIGN_EXIT:-0}"')
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("RAI_")}
        self.env.update(
            PATH=str(self.tools) + ":" + os.environ["PATH"],
            RAI_APP_DEST=str(self.dest), TEST_BIN=str(self.build),
            TEST_LOG=str(self.root / "calls"), TEST_IDENTITY="rai-dev-signing",
        )

    def tool(self, name, body):
        path = self.tools / name
        path.write_text("#!/bin/bash\n" + body + "\n")
        path.chmod(0o755)

    def run_bundle(self, **env):
        return subprocess.run(
            ["bash", str(self.root / "scripts/bundle.sh")],
            env=self.env | env, text=True, capture_output=True,
        )

    def test_development_install_preserves_release_and_uses_separate_identity(self):
        result = self.run_bundle()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.release / "keep").exists())
        with (self.dest / "Rai Dev.app/Contents/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        self.assertEqual(info["CFBundleIdentifier"], "gr.krig.rai.dev")
        self.assertEqual(info["CFBundleName"], "Rai Dev")

    def test_missing_or_wrong_release_identity_stops_before_build_or_install(self):
        for identity in ["", "rai-dev-signing", "-"]:
            with self.subTest(identity=identity):
                result = self.run_bundle(RAI_BUILD_CHANNEL="release", RAI_SIGN_IDENTITY=identity)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "calls").exists())
                self.assertTrue((self.release / "keep").exists())

    def test_lab_build_has_its_own_identity(self):
        result = self.run_bundle(RAI_BUILD_CHANNEL="lab", RAI_LAB_ID="e2e-a")
        self.assertEqual(result.returncode, 0, result.stderr)
        with (self.dest / "Rai Lab e2e-a.app/Contents/Info.plist").open("rb") as handle:
            self.assertEqual(plistlib.load(handle)["CFBundleIdentifier"], "gr.krig.rai.lab.e2e-a")
        self.assertTrue((self.release / "keep").exists())

    def test_lab_rejects_invalid_identity_before_build(self):
        for identifier in ["", "../live", "UPPER", "has space"]:
            result = self.run_bundle(RAI_BUILD_CHANNEL="lab", RAI_LAB_ID=identifier)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((self.root / "calls").exists())

    def test_missing_development_identity_does_not_fall_back_to_ad_hoc(self):
        result = self.run_bundle(TEST_IDENTITY="another identity")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "calls").exists())

    def test_release_install_requires_publisher_verification(self):
        identity = "Developer ID Application: Test (T2XB37WVYD)"
        result = self.run_bundle(
            RAI_BUILD_CHANNEL="release", RAI_SIGN_IDENTITY=identity, TEST_IDENTITY=identity,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        with (self.release / "Contents/Info.plist").open("rb") as handle:
            self.assertEqual(plistlib.load(handle)["CFBundleIdentifier"], "gr.krig.rai")
        calls = (self.root / "calls").read_text()
        self.assertIn("--verify --strict", calls)
        self.assertIn('certificate leaf[subject.OU] = "T2XB37WVYD"', calls)
        self.assertIn("--options runtime --timestamp", calls)

    def test_signature_failure_preserves_installed_release(self):
        identity = "Developer ID Application: Test (T2XB37WVYD)"
        result = self.run_bundle(
            RAI_BUILD_CHANNEL="release", RAI_SIGN_IDENTITY=identity,
            TEST_IDENTITY=identity, TEST_SIGN_EXIT="1",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.release / "keep").exists())

    def test_rejected_publisher_preserves_installed_release(self):
        self.tool("codesign", 'if [[ "$*" == *--verify* ]]; then exit 1; fi')
        identity = "Developer ID Application: Wrong publisher"
        result = self.run_bundle(
            RAI_BUILD_CHANNEL="release", RAI_SIGN_IDENTITY=identity, TEST_IDENTITY=identity,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.release / "keep").exists())


if __name__ == "__main__":
    unittest.main()

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/wait-ios-build.sh'


class IOSBuildStatusTests(unittest.TestCase):
    def run_query(self, behavior):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cli = root / 'asc'
            cli.write_text('#!/bin/bash\nset -eu\n' + behavior)
            cli.chmod(0o700)
            sleep = root / 'sleep'
            sleep.write_text('#!/bin/sh\nexit 0\n')
            sleep.chmod(0o700)
            env = dict(os.environ, RUNNER_TEMP=directory, BUILD_NUMBER='45', MARKETING_VERSION='1.0',
                       PATH=str(root) + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['bash', str(SCRIPT), str(cli)], env=env, capture_output=True, text=True)
            data = (root / 'build.json').read_text()
            return result, data

    def test_waits_for_new_build_then_preserves_json(self):
        result, data = self.run_query('''
if [ ! -f "$RUNNER_TEMP/seen" ]; then
  touch "$RUNNER_TEMP/seen"
  echo 'Error: builds info: no build found for app 1' >&2
  exit 1
fi
printf '%s' '{"data":{"id":"build-45"}}'
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Retrying', result.stderr)
        self.assertEqual(data, '{"data":{"id":"build-45"}}')

    def test_authentication_failure_stops_without_retry(self):
        result, _ = self.run_query("echo 'Unauthorized' >&2\nexit 1\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('Retrying', result.stderr)
        self.assertIn('Unauthorized', result.stderr)

    def test_missing_build_has_bounded_retries(self):
        result, _ = self.run_query("echo 'no build found for app 1' >&2\nexit 1\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr.count('Retrying'), 7)

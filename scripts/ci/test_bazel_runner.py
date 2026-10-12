"""Execute the SDK wrapper against a disposable installed-boundary fixture."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.checkout = self.root / 'checkout'
        (self.checkout / 'scripts/bazel').mkdir(parents=True)
        (self.checkout / 'scripts/ci').mkdir()
        for name in ('bazel.sh', 'cache.py', 'remote-cache.sh', 'remote-cache.py', 'cache-tls-pin.py'):
            shutil.copyfile(ROOT / 'scripts/bazel' / name, self.checkout / 'scripts/bazel' / name)
        helper = self.root / 'installed.py'
        helper.write_text('''import json, os, subprocess, sys
if sys.argv[1] == 'environment':
    values = {'NUXIE_BAZEL_JOBS': 3, 'NUXIE_BAZEL_CPU': 4, 'NUXIE_BAZEL_MEMORY': 8192,
              'NUXIE_BAZEL_LOCAL_TEST_JOBS': 1, 'NUXIE_BAZEL_BOOTSTRAP_JOBS': 2,
              'NUXIE_BAZEL_BATCH': 1, 'NUXIE_BAZEL_CACHE_DIR': os.environ['OWNED_CACHE'],
              'NUXIE_BAZEL_OUTPUT_USER_ROOT': os.environ['OWNED_CACHE'] + '/outputs',
              'NUXIE_BAZEL_REMOTE_CACHE_MODE': 'off'}
    for key, value in values.items(): print('export ' + key + '=' + str(value))
elif sys.argv[1:3] == ['run', '--']:
    with open(os.environ['CALLS'], 'w') as log: json.dump(sys.argv[4:], log)
    sys.exit(int(os.environ.get('STATUS', '0')))
else: sys.exit(99)
''')
        # The fixture substitutes only filesystem installation trust. Production
        # has fixed root-controlled paths and no configurable trust bypass.
        shell = 'nuxie_runner_policy_verify() { NUXIE_RUNNER_POLICY_HELPER=' + str(helper) + '; }\n'
        shell += 'nuxie_runner_policy_environment() { nuxie_runner_policy_verify; eval "$(/usr/bin/python3 -I "$NUXIE_RUNNER_POLICY_HELPER" environment)"; }\n'
        (self.checkout / 'scripts/ci/runner-policy.sh').write_text(shell)
        self.bazel = self.root / 'bazel'
        self.calls = self.root / 'calls.json'
        self.bazel.write_text('#!/usr/bin/env python3\nimport json,os,sys\nwith open(os.environ["CALLS"],"w") as log: json.dump(sys.argv[1:],log)\nsys.exit(int(os.environ.get("STATUS","0")))\n')
        self.bazel.chmod(0o755)
        self.environment = {**os.environ, 'NUXIE_CI_RUNNER_POLICY_VERSION': '2',
                            'NUXIE_BAZEL_BIN': str(self.bazel), 'CALLS': str(self.calls),
                            'OWNED_CACHE': str(self.root / 'owned-cache'),
                            'NUXIE_BAZEL_JOBS': '100', 'NUXIE_BAZEL_CPU': '100'}

    def run_wrapper(self, arguments):
        return subprocess.run(['/bin/bash', str(self.checkout / 'scripts/bazel/bazel.sh'), *arguments],
                              env=self.environment, text=True, capture_output=True, timeout=10)

    def test_installed_limits_follow_configs_and_keep_application_boundary(self):
        result = self.run_wrapper(['run', '--config=caller', '//fixture', '--', '--jobs=100'])
        self.assertEqual(result.returncode, 0, result.stderr)
        received = json.loads(self.calls.read_text())
        boundary = received.index('--')
        self.assertEqual(received[boundary:], ['--', '--jobs=100'])
        for argument in ('--jobs=3', '--local_resources=cpu=4', '--local_resources=memory=8192',
                         '--local_test_jobs=1', '--repo_env=NUXIE_BAZEL_BOOTSTRAP_JOBS=2', '--remote_cache='):
            self.assertIn(argument, received[:boundary])
            self.assertGreater(received.index(argument), received.index('--config=caller'))
        self.assertTrue(any(argument.startswith('--profile=' + str(self.checkout / 'output/pipeline/bazel')) for argument in received))
        self.assertTrue(any(argument.startswith('--build_event_json_file=') for argument in received))
        self.assertIn('--disk_cache=' + self.environment['OWNED_CACHE'] + '/actions', received)

    def test_caller_cannot_replace_budgets_outputs_or_evidence(self):
        for option in ('--jobs=100', '-j100', '--local_resources=memory=65536', '--disk_cache=/other',
                       '--repo_env=NUXIE_BAZEL_BOOTSTRAP_JOBS=100', '--profile=/other'):
            with self.subTest(option=option):
                result = self.run_wrapper(['build', '//fixture', option])
                self.assertEqual(result.returncode, 1)
                self.assertFalse(self.calls.exists())
        self.assertEqual(self.run_wrapper(['--output_user_root=/other', 'build', '//fixture']).returncode, 1)
        self.assertFalse(self.calls.exists())

    def test_binary_failure_preserves_exit_status(self):
        self.environment['STATUS'] = '17'
        self.assertEqual(self.run_wrapper(['test', '//fixture']).returncode, 17)



if __name__ == '__main__':
    unittest.main()

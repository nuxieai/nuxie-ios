"""Parse emitted pipeline objects against platform admission and readiness contracts."""
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
SDK = 'ios'


class PipelineTests(unittest.TestCase):
    def render(self, version='1', split='0', topology='consolidated'):
        env = dict(os.environ, NUXIE_CI_RUNNER_POLICY_VERSION=version,
                   NUXIE_SDK_SPLIT_LANES=split, NUXIE_CI_RUNNER_TOPOLOGY=topology)
        return subprocess.run([sys.executable, str(ROOT / 'scripts/ci/pipeline.py')], env=env,
                              capture_output=True, text=True, timeout=10)

    def test_legacy_preserves_full_readiness_checks(self):
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        steps = json.loads(result.stdout)['steps']
        if SDK == 'ios':
            self.assertEqual(len(steps), 1)
            for command in ('make test', 'make build-ios-device', 'make fetch-runtime-xcframework-clean',
                            'make check-runtime-consumer-boundary check-runtime-package-pin'):
                self.assertIn(command, steps[0]['command'].splitlines())
            self.assertEqual(steps[0]['agents']['nuxie-platform'], 'macos')
        elif SDK == 'unity':
            self.assertEqual(len(steps), 2)
            self.assertNotIn('nuxie-platform', steps[0]['agents'])
            for command in ('python3 scripts/prepare-native.py', 'python3 scripts/check-ios.py', 'python3 scripts/pack.py'):
                self.assertIn(command, steps[1]['command'].splitlines())
        else:
            self.assertEqual([(step['command'], step['agents']['nuxie-platform']) for step in steps],
                             [('bash scripts/ci.sh', 'macos')])
        self.assertTrue(all('nuxie-resources' not in step['agents'] for step in steps))

    def test_every_v2_graph_has_precheckout_profile_capability_and_physical_mutex(self):
        for split in ('0', '1'):
            result = self.render('2', split)
            self.assertEqual(result.returncode, 0, result.stderr)
            for step in json.loads(result.stdout)['steps']:
                mac = step['agents']['nuxie-platform'] == 'macos'
                self.assertEqual(step['agents']['nuxie-resources'], 'mac-64g-v2' if mac else 'linux-16g-v2')
                self.assertEqual(step['env']['NUXIE_CI_RUNNER_POLICY_VERSION'], '2')
                self.assertEqual(step['env']['NUXIE_BAZEL_REMOTE_CACHE_MODE'], 'off')
                self.assertIn(step['env']['NUXIE_CI_RUNNER_PROFILE'], ('macos-apple',) if mac else ('linux-portable', 'linux-native'))
                self.assertEqual(step['concurrency'], 1)
                self.assertEqual(step['concurrency_method'], 'eager')
                self.assertEqual(step['concurrency_group'], 'nuxie/physical/mac-m2' if mac else 'nuxie/physical/proxmox-heavy')
                self.assertIn('output/pipeline/**/*', step['artifact_paths'])

    def test_split_routes_platforms_and_pins_the_godot_join_to_same_build_producer(self):
        steps = json.loads(self.render('2', '1').stdout)['steps']
        self.assertEqual([step['agents']['nuxie-platform'] for step in steps],
                         {'ios': ['macos'], 'unity': ['linux', 'linux', 'macos'], 'godot': ['linux', 'macos']}[SDK])
        if SDK == 'unity':
            self.assertIn('python3 scripts/pack.py', steps[1]['command'].splitlines())
            self.assertEqual(steps[2]['command'].splitlines()[-1], 'python3 scripts/check-ios.py')
            self.assertTrue(all('depends_on' not in step for step in steps))
        if SDK == 'godot':
            self.assertEqual(steps[1]['depends_on'], 'godot-android')
            download = steps[1]['command'].splitlines()[2]
            self.assertEqual(download, 'buildkite-agent artifact download "output/pipeline/android-products/**/*" "$PWD" --step godot-android --build "${BUILDKITE_BUILD_ID:?}"')
            self.assertLess(steps[1]['command'].index('lane_artifacts.py restore'), steps[1]['command'].index('ci.sh --platform ios'))

    def test_activation_rejects_policy_fallback_or_invalid_values(self):
        for version, split, topology in [('1', '1', 'consolidated'), ('2', '1', 'fallback'),
                                          ('2', '0', 'fallback'), ('3', '0', 'consolidated'), ('2', 'yes', 'consolidated')]:
            self.assertNotEqual(self.render(version, split, topology).returncode, 0)

    def test_repository_upload_v2_selector_has_initial_profile(self):
        steps = json.loads((ROOT / '.buildkite/pipeline.yml').read_text())['steps']
        self.assertEqual(len(steps), 2)
        uploader = steps[1]
        self.assertEqual(uploader['agents'], {'queue': 'nuxie-pr', 'nuxie-platform': 'linux', 'nuxie-resources': 'linux-16g-v2'})
        self.assertEqual(uploader['env'], {'NUXIE_CI_RUNNER_POLICY_VERSION': '2', 'NUXIE_CI_RUNNER_PROFILE': 'linux-portable', 'NUXIE_BAZEL_REMOTE_CACHE_MODE': 'off'})
        self.assertIn('buildkite-agent pipeline upload --replace --no-interpolation', uploader['command'])


if __name__ == '__main__':
    unittest.main()

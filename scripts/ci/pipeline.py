#!/usr/bin/env python3
"""Render dormant platform lanes from the repository's full readiness graph."""
import copy
import json
import os
from pathlib import Path
from cache_policy import cache_environment

ROOT = Path(__file__).resolve().parents[2]
SDK = 'ios'


def lane(label, key, platform, commands, timeout=120, **extra):
    return dict(label=label, key=key, agents={'queue': 'nuxie-pr', 'nuxie-platform': platform},
                command='set -euo pipefail\nsource scripts/bazel/ci-cache.sh\n' + '\n'.join(commands) + '\n',
                timeout_in_minutes=timeout, **extra)


def pipeline(environment=None):
    environment = os.environ if environment is None else environment
    version = environment.get('NUXIE_CI_RUNNER_POLICY_VERSION', '1')
    split = environment.get('NUXIE_SDK_SPLIT_LANES', '0')
    if version not in ('1', '2') or split not in ('0', '1'):
        raise ValueError('Unsupported runner policy or SDK split setting')
    if split == '1' and version != '2':
        raise ValueError('SDK split requires installed runner policy v2')
    if version == '2' and environment.get('NUXIE_CI_RUNNER_TOPOLOGY') == 'fallback':
        raise ValueError('SDK native lanes require the consolidated runner topology')
    document = json.loads((ROOT / '.buildkite/lanes.json').read_text())
    if split == '1' and SDK == 'unity':
        document['steps'][0]['agents']['nuxie-platform'] = 'linux'
        document['steps'][1:] = [
            lane(':android: Unity Android products and UPM package', 'unity-android', 'linux', [
                'python3 scripts/ci/android-toolchain.py',
                'python3 scripts/prepare-native.py', 'python3 scripts/pack.py']),
            lane(':apple: Unity Apple bridge', 'unity-apple', 'macos', ['python3 scripts/check-ios.py']),
        ]
    elif split == '1' and SDK == 'godot':
        document['steps'] = [
            lane(':android: Godot portable and Android confidence', 'godot-android', 'linux', [
                'python3 scripts/ci/android-toolchain.py',
                'python3 scripts/check.py --platform android',
                'python3 scripts/bazel/lane_artifacts.py export --output output/pipeline/android-products']),
            lane(':apple: Godot Apple confidence and exact dual package', 'godot-apple', 'macos', [
                'buildkite-agent artifact download "output/pipeline/android-products/**/*" "$PWD" --step godot-android --build "${BUILDKITE_BUILD_ID:?}"',
                'python3 scripts/bazel/lane_artifacts.py restore --input output/pipeline/android-products',
                'bash scripts/ci.sh --platform ios'], depends_on='godot-android'),
        ]
    if version == '2':
        for index, step in enumerate(document['steps']):
            selected = step['agents'].get('nuxie-platform', 'linux')
            step['agents']['nuxie-platform'] = selected
            step['agents']['nuxie-resources'] = 'mac-64g-v2' if selected == 'macos' else 'linux-16g-v2'
            step.update(concurrency=1, concurrency_method='eager',
                        concurrency_group='nuxie/physical/mac-m2' if selected == 'macos' else 'nuxie/physical/proxmox-heavy')
            step['env'] = {'NUXIE_CI_RUNNER_POLICY_VERSION': '2',
                           'NUXIE_CI_RUNNER_PROFILE': 'macos-apple' if selected == 'macos' else 'linux-portable' if SDK == 'unity' and index == 0 else 'linux-native',
                           **cache_environment(environment, 'macos-apple' if selected == 'macos' else 'linux-portable' if SDK == 'unity' and index == 0 else 'linux-native')}
            step['command'] = step['command'].replace('export NUXIE_BAZEL_JOBS=2\n', '')
            if SDK == 'ios':
                step['command'] = step['command'].replace('python3 scripts/bazel/launcher.py --version', 'scripts/bazel/bazel.sh version')
            step['artifact_paths'] = list(dict.fromkeys([*step.get('artifact_paths', []), 'output/pipeline/**/*', 'bazel-testlogs/**/*']))
    return copy.deepcopy(document)


if __name__ == '__main__':
    print(json.dumps(pipeline()))

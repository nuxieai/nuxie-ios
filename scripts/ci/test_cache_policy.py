"""Read activation requires the exact separately qualified profile/domain."""
import unittest
from cache_policy import cache_environment


class CachePolicyTests(unittest.TestCase):
    def environment(self, **changes):
        return {
            'NUXIE_CI_RUNNER_POLICY_VERSION': '2', 'NUXIE_CI_BAZEL_REMOTE_CACHE_MODE': 'read',
            'NUXIE_CI_BAZEL_CACHE_PROFILES': 'linux-native', 'NUXIE_BAZEL_REMOTE_CACHE_ELIGIBLE': '1',
            'NUXIE_BAZEL_REMOTE_CACHE_DOMAIN': 'sha256:' + 'a' * 64,
            'NUXIE_BAZEL_REMOTE_CACHE_URL': 'https://cache.example.test',
            'NUXIE_BAZEL_REMOTE_CACHE_CA_FILE': '/opt/cache/leaf.pem',
            'NUXIE_BAZEL_REMOTE_CACHE_TLS_PIN_FILE': '/opt/cache/pin.json',
            'NUXIE_BAZEL_REMOTE_CACHE_CREDENTIAL_FILE': '/home/ci/reader/credential.json', **changes,
        }

    def test_only_explicit_qualified_read_profile_receives_transport(self):
        result = cache_environment(self.environment(), 'linux-native')
        self.assertEqual(result['NUXIE_BAZEL_REMOTE_CACHE_MODE'], 'read')
        self.assertEqual(result['NUXIE_BAZEL_REMOTE_CACHE_DOMAIN'], 'sha256:' + 'a' * 64)
        self.assertEqual(result['NUXIE_BAZEL_REMOTE_CACHE_TLS_PIN_FILE'], '/opt/cache/pin.json')
        self.assertNotIn('NUXIE_BAZEL_REMOTE_CACHE_WRITER_JSON', result)
        self.assertEqual(cache_environment(self.environment(), 'macos-apple'), {'NUXIE_BAZEL_REMOTE_CACHE_MODE': 'off'})

    def test_unqualified_missing_or_write_activation_remains_off(self):
        for changes in ({'NUXIE_CI_BAZEL_REMOTE_CACHE_MODE': 'write'}, {'NUXIE_CI_RUNNER_POLICY_VERSION': '1'},
                        {'NUXIE_CI_BAZEL_CACHE_PROFILES': ''}, {'NUXIE_BAZEL_REMOTE_CACHE_ELIGIBLE': '0'},
                        {'NUXIE_BAZEL_REMOTE_CACHE_DOMAIN': 'unknown'}, {'NUXIE_BAZEL_REMOTE_CACHE_CA_FILE': ''}):
            with self.subTest(changes=changes):
                self.assertEqual(cache_environment(self.environment(**changes), 'linux-native'),
                                 {'NUXIE_BAZEL_REMOTE_CACHE_MODE': 'off'})

    def test_unknown_profiles_and_unsafe_paths_are_rejected(self):
        for changes in ({'NUXIE_CI_BAZEL_CACHE_PROFILES': 'deploy'},
                        {'NUXIE_BAZEL_REMOTE_CACHE_CA_FILE': 'relative'},
                        {'NUXIE_BAZEL_REMOTE_CACHE_TLS_PIN_FILE': '/opt/cache/pin\n.json'}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                cache_environment(self.environment(**changes), 'linux-native')


if __name__ == '__main__':
    unittest.main()

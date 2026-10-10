"""Cache override regressions; no compiler or external service is required."""

import os
from pathlib import Path
import tempfile
import subprocess
import unittest
from unittest.mock import patch

from cache import startup_options


class CacheTest(unittest.TestCase):
    def ci_caches(self, variables):
        environment = {"PATH": os.environ["PATH"], "HOME": str(Path.home()), **variables}
        result = subprocess.run(["bash", "--noprofile", "--norc", "-c",
                                 'set -euo pipefail; source "$1"; printf "%s\\n" "$BAZELISK_HOME" '
                                 '"$NUXIE_BAZEL_OUTPUT_USER_ROOT" "$NUXIE_BAZEL_CACHE_DIR" "$NUXIE_BAZEL_BATCH"',
                                 "ci-cache-test", str(Path(__file__).with_name("ci-cache.sh"))],
                                env=environment, check=True, text=True, capture_output=True)
        return result.stdout.splitlines()

    def test_standalone_buildkite_reuses_the_guarded_root_runtime_cache_paths(self):
        root = Path.home() / ".nuxie-ci/editor-cargo-target/runner-mac-one"
        self.assertEqual(self.ci_caches({"BUILDKITE_AGENT_NAME": "runner mac/one", "RUNNER_NAME": "unused"}),
                         [str(root / "bazelisk"), str(root / "bazel"), str(root / "bazel-shared-cache"), "1"])
        for name in ("", ".", ".."):
            self.assertIn("/editor-cargo-target/default/bazel", self.ci_caches({"RUNNER_NAME": name})[1])

    def test_standalone_buildkite_preserves_explicit_cache_and_output_overrides(self):
        expected = ["/selected/launcher cache", "/selected/output state", "/selected/shared cache"]
        variables = dict(zip(("BAZELISK_HOME", "NUXIE_BAZEL_OUTPUT_USER_ROOT", "NUXIE_BAZEL_CACHE_DIR"), expected))
        variables["NUXIE_BAZEL_BATCH"] = "0"
        self.assertEqual(self.ci_caches(variables), expected + ["0"])
        self.assertEqual(self.ci_caches({"NUXIE_BAZEL_CACHE_DIR": ""})[2], "")

    def test_default_keeps_bazel_output_base_and_repository_configuration(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            self.assertEqual(startup_options(Path(directory)), [])
            self.assertEqual(list(Path(directory).iterdir()), [])

    def test_shared_cache_does_not_share_generated_configuration_or_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shared = root / "shared cache with 'quotes'"
            with patch.dict(os.environ, {"NUXIE_BAZEL_CACHE_DIR": str(shared)}, clear=True):
                for name in ("first", "second"):
                    checkout = root / name
                    checkout.mkdir()
                    self.assertEqual(startup_options(checkout), ["--bazelrc=" + str(checkout / ".bazel-cache.local.bazelrc")])
                first = root / "first/.bazel-cache.local.bazelrc"
                second = root / "second/.bazel-cache.local.bazelrc"
                self.assertEqual(first.read_bytes(), second.read_bytes())
                self.assertFalse(first.samefile(second))
                self.assertNotIn("output_base", first.read_text())
                self.assertNotIn("output_user_root", first.read_text())
                before = first.stat().st_mtime_ns
                startup_options(first.parent)
                self.assertEqual(first.stat().st_mtime_ns, before)

    def test_rejects_invalid_overrides_without_writing_configuration(self):
        for value in ("", "relative", "/tmp/cache\nline", "/tmp/cache\0line", "/tmp/cache\rline"):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                with patch("cache.os.environ", {"NUXIE_BAZEL_CACHE_DIR": value}):
                    with self.assertRaisesRegex(ValueError, "absolute path on one line"):
                        startup_options(Path(directory))
                self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == "__main__":
    unittest.main()

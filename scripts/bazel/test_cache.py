"""Cache override regressions; no compiler or external service is required."""

import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from cache import startup_options


class CacheTest(unittest.TestCase):
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

import hashlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import launcher


class BazeliskInstallationTests(unittest.TestCase):
    def test_verified_launcher_is_reused_across_checkouts_without_a_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "nuxie-tools/bazelisk" / launcher.VERSION / "bazelisk-darwin-arm64"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"verified launcher")
            with patch.dict("os.environ", {"XDG_CACHE_HOME": directory}), \
                    patch.object(launcher.platform, "system", return_value="Darwin"), \
                    patch.object(launcher.platform, "machine", return_value="arm64"), \
                    patch.dict(launcher.DIGESTS, {"darwin-arm64": hashlib.sha256(binary.read_bytes()).hexdigest()}), \
                    patch.object(launcher.urllib.request, "urlopen") as download:
                self.assertEqual(launcher.executable(), str(binary))
                self.assertEqual(launcher.executable(), str(binary))
                download.assert_not_called()

    def test_bad_download_does_not_replace_the_existing_launcher(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "nuxie-tools/bazelisk" / launcher.VERSION / "bazelisk-darwin-arm64"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"previous launcher")
            with patch.dict("os.environ", {"XDG_CACHE_HOME": directory}), \
                    patch.object(launcher.platform, "system", return_value="Darwin"), \
                    patch.object(launcher.platform, "machine", return_value="arm64"), \
                    patch.object(launcher.shutil, "disk_usage", return_value=type("Disk", (), {"free": 10 * 1024**3})()), \
                    patch.object(launcher.urllib.request, "urlopen", return_value=io.BytesIO(b"bad download")):
                with self.assertRaisesRegex(ValueError, "SHA-256"):
                    launcher.executable()
            self.assertEqual(binary.read_bytes(), b"previous launcher")
            self.assertFalse(list(binary.parent.glob(".install-*")))


if __name__ == "__main__":
    unittest.main()

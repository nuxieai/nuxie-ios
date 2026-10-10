from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class RuntimeOwnershipTests(unittest.TestCase):
    def test_sdk_does_not_admit_new_native_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            script = root / "scripts/check-runtime-consumer-boundary.sh"
            script.parent.mkdir()
            shutil.copy2(Path(__file__).parents[1] / script.name, script)
            def check():
                return subprocess.run(["bash", str(script)], cwd=root, text=True, capture_output=True)
            result = check()
            self.assertEqual(result.returncode, 0, result.stderr)
            for name in ("Sources/NuxieRuntime/native.rs", "Sources/Cargo.toml", "fixtures/new/generate.rs"):
                with self.subTest(name=name):
                    source = root / name
                    source.parent.mkdir(parents=True, exist_ok=True)
                    source.write_text("unexpected SDK native source")
                    result = check()
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("must not own Cargo manifests, Rust source", result.stderr)
                    source.unlink()

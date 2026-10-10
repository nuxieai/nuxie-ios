import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("macos_test_home", Path(__file__).with_name("macos-test-home.py"))
home_runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(home_runner)


class MacOSHomeContractTests(unittest.TestCase):
    def test_private_home_preserves_runner_metadata_and_injected_libraries(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory).resolve()
            xctestrun = scratch / "test_tmp_dir.fixture/tests.xctestrun"
            xctestrun.parent.mkdir()
            original = {"BazelMacOSTests": {
                "TestBundlePath": "private-tests.xctest",
                "TestingEnvironmentVariables": {"DYLD_INSERT_LIBRARIES": "XCTestInject", "HOME": "/shared"},
            }}
            xctestrun.write_bytes(plistlib.dumps(original))
            xctestrun.chmod(0o444)
            home = home_runner.configure_home(scratch)
            result = plistlib.loads(xctestrun.read_bytes())["BazelMacOSTests"]
            self.assertEqual(result["TestBundlePath"], "private-tests.xctest")
            self.assertEqual(result["TestingEnvironmentVariables"], {
                "DYLD_INSERT_LIBRARIES": "XCTestInject", "HOME": str(home),
                "CFFIXED_USER_HOME": str(home), "NUXIE_MACOS_TEST_HOME": str(home),
                "NUXIE_MACOS_TEST_TMPDIR": str(scratch),
            })
            self.assertTrue(home.is_dir())
            self.assertTrue(home.is_relative_to(scratch))

    def test_missing_or_ambiguous_owned_plist_fails_before_modification(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            with self.assertRaises(ValueError):
                home_runner.configure_home(scratch)
            for suffix in ("first", "second"):
                xctestrun = scratch / ("test_tmp_dir." + suffix) / "tests.xctestrun"
                xctestrun.parent.mkdir()
                xctestrun.write_bytes(b"retain this file")
            with self.assertRaises(ValueError):
                home_runner.configure_home(scratch)
            self.assertEqual([p.read_bytes() for p in scratch.glob("*/tests.xctestrun")],
                             [b"retain this file", b"retain this file"])

    def test_invalid_environment_fails_before_creating_home(self):
        with tempfile.TemporaryDirectory() as directory:
            xctestrun = Path(directory) / "test_tmp_dir.fixture/tests.xctestrun"
            xctestrun.parent.mkdir()
            contents = plistlib.dumps({"BazelMacOSTests": {"TestingEnvironmentVariables": "invalid"}})
            xctestrun.write_bytes(contents)
            with self.assertRaises(ValueError):
                home_runner.configure_home(Path(directory))
            self.assertEqual(xctestrun.read_bytes(), contents)
            self.assertFalse((xctestrun.parent / "private-home").exists())

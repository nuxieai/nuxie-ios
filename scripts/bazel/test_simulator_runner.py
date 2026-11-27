"""Run the pinned Apple shell runner with inert simulator/Xcode commands."""
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
import unittest


def runner_template():
    root = Path(os.environ["TEST_SRCDIR"])
    paths = [p / "apple/testing/default_runner/ios_xctestrun_runner.template.sh"
             for p in (root, *root.iterdir())]
    return next(p for p in paths if p.is_file()).read_text()


@unittest.skipUnless(os.environ.get("TEST_SRCDIR"), "requires the declared Bazel Apple runner template")
class SimulatorRunnerTests(unittest.TestCase):
    def run_fixture(self, pre_exit=0, post_exit=0, test_exit=0, cancel=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); binaries = root / "bin"; binaries.mkdir()
            events = root / "events"; ready = root / "ready"
            def program(name, body):
                path = binaries / name
                path.write_text("#!/bin/bash\n" + body + "\n"); path.chmod(0o755)
                return str(path)
            create = program("create", 'echo create >> "$EVENTS"; echo owned-simulator')
            cleanup = program("cleanup", 'echo "cleanup:$SIMULATOR_UDID" >> "$EVENTS"')
            pre = program("pre", 'touch "$READY"; ' + ("sleep 60" if cancel else "exit " + str(pre_exit)))
            post = program("post", "exit " + str(post_exit))
            program("file", "echo 'Mach-O 64-bit arm64'")
            program("xcodebuild", "echo 'Executed 1 test, with 0 failures'; exit " + str(test_exit))
            bundle = root / "Fixture.xctest"; bundle.mkdir(); (bundle / "Fixture").touch()
            xctestrun = root / "template.xctestrun"; xctestrun.touch()
            values = {"test_bundle_path": str(bundle), "test_type": "XCTEST", "create_xcresult_bundle": "true",
                      "reuse_simulator": "false", "pre_action_binary": pre, "post_action_binary": post,
                      "post_action_determines_exit_code": "true" if post_exit else "false", "create_simulator_action_binary": create,
                      "clean_up_simulator_action_binary": cleanup, "xctestrun_template": str(xctestrun),
                      "device_type": "iPhone 17 Pro", "os_version": "27.0", "test_env_inherit": "()"}
            script = root / "runner.sh"
            script.write_text(re.sub(r"%\((\w+)\)s", lambda m: values.get(m[1], ""), runner_template()))
            env = {**os.environ, "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                   "EVENTS": str(events), "READY": str(ready), "TEST_TMPDIR": str(root),
                   "TEST_PREMATURE_EXIT_FILE": str(root / "premature"), "TEST_SRCDIR": str(root),
                   "TEST_UNDECLARED_OUTPUTS_DIR": str(root / "outputs"), "XML_OUTPUT_FILE": str(root / "tests.xml"),
                   "COVERAGE": "0", "ERROR_ON_NO_TESTS_RAN": "0"}
            (root / "outputs").mkdir()
            process = subprocess.Popen(["/bin/bash", str(script)], env=env, cwd=root,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            if cancel:
                deadline = time.monotonic() + 5
                while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue(ready.exists(), "runner never reached its pre-action")
                os.killpg(process.pid, signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 143 if cancel else pre_exit or post_exit or test_exit,
                             (stdout + stderr).decode())
            self.assertEqual(events.read_text().splitlines(), ["create", "cleanup:owned-simulator"])

    def test_pre_action_failure_still_cleans_its_device(self):
        self.run_fixture(pre_exit=7)

    def test_post_action_failure_still_cleans_its_device(self):
        self.run_fixture(post_exit=17)

    def test_test_failure_retains_its_exit_and_cleans_the_device(self):
        self.run_fixture(test_exit=3)

    def test_cancelled_runner_cleans_its_device(self):
        self.run_fixture(cancel=True)


if __name__ == "__main__":
    unittest.main()

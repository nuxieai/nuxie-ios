"""Exercise the pinned Apple simulator creator with concurrent test requests."""
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

base = Path(os.environ["TEST_SRCDIR"])
paths = [root / "apple/testing/default_runner/simulator_creator.py"
         for root in [base, *base.iterdir()]]
paths = [path for path in paths if path.is_file()]
if len(paths) != 1:
    raise RuntimeError("Expected one declared Apple simulator creator")
spec = importlib.util.spec_from_file_location("simulator_creator", paths[0])
creator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(creator)


class SimulatorOwnershipTests(unittest.TestCase):
    def setUp(self):
        self.runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        self.devices = [{"name": "BAZEL_TEST_iPhone 17 Pro_27.0", "udid": "another-suite", "state": "Booted"}]
        self.created = []

    def simctl(self, arguments):
        if arguments == ["list", "devices", "-j"]:
            return json.dumps({"devices": {self.runtime: self.devices}})
        self.assertEqual(arguments[0], "create")
        identity = "owned-" + str(len(self.created))
        self.created.append(identity)
        self.devices.append({"name": arguments[1], "udid": identity, "state": "Booted"})
        return identity

    def run_creator(self, environment, arguments=()):
        with patch.dict(os.environ, {"SIMULATOR_OS_VERSION": "27.0", "SIMULATOR_DEVICE_TYPE": "iPhone 17 Pro", **environment}, clear=True), \
                patch.object(sys, "argv", ["creator", *arguments]), \
                patch.object(creator, "_simctl", side_effect=self.simctl), \
                patch.object(creator, "_boot_simulator"), patch.object(sys, "stdout", new_callable=io.StringIO) as output:
            creator._main()
            return output.getvalue().strip()

    def test_disposable_requests_never_share_an_existing_or_new_device(self):
        first = self.run_creator({"SIMULATOR_REUSE_SIMULATOR": ""})
        second = self.run_creator({"SIMULATOR_REUSE_SIMULATOR": ""})
        self.assertNotEqual(first, "another-suite")
        self.assertNotEqual(first, second)
        self.assertEqual(self.created, [first, second])

    def test_explicit_no_reuse_overrides_a_reuse_environment(self):
        self.assertNotEqual(self.run_creator({"SIMULATOR_REUSE_SIMULATOR": "1"}, ["--no-reuse-simulator"]), "another-suite")

    def test_explicit_reuse_overrides_an_empty_environment(self):
        self.assertEqual(self.run_creator({"SIMULATOR_REUSE_SIMULATOR": ""}, ["--reuse-simulator"]), "another-suite")

    def test_unconfigured_creator_preserves_its_default_reuse_behavior(self):
        self.assertEqual(self.run_creator({}), "another-suite")


if __name__ == "__main__":
    unittest.main()

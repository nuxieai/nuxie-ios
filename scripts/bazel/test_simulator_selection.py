import unittest
from simulator_selection import select_simulator


class SimulatorSelectionTests(unittest.TestCase):
    def inventory(self):
        return {
            "runtimes": [
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "version": "27.0", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "pro"}, {"identifier": "duo"}]},
                {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "version": "27.1", "isAvailable": True, "supportedDeviceTypes": [{"identifier": "pro"}, {"identifier": "duo"}]},
            ],
            "devicetypes": [
                {"identifier": "duo", "name": "iPhone Duo", "productFamily": "iPhone", "minRuntimeVersion": 27 << 16, "maxRuntimeVersion": 0xffffffff},
                {"identifier": "pro", "name": "iPhone 17 Pro", "productFamily": "iPhone", "minRuntimeVersion": 26 << 16, "maxRuntimeVersion": 0xffffffff},
            ],
            "devices": {"iOS-27-1": [{"name": "iPhone Duo"}]},
        }

    def test_existing_duo_does_not_change_the_general_gate_viewport(self):
        self.assertEqual(select_simulator(self.inventory()), ("27.1", "iPhone 17 Pro"))

    def test_unavailable_runtime_is_not_selected(self):
        inventory = self.inventory()
        inventory["runtimes"][1]["isAvailable"] = False
        self.assertEqual(select_simulator(inventory), ("27.0", "iPhone 17 Pro"))

    def test_duo_only_runtime_does_not_admit_an_incompatible_ordinary_phone(self):
        inventory = self.inventory()
        inventory["runtimes"][1]["supportedDeviceTypes"] = [{"identifier": "duo"}]
        self.assertEqual(select_simulator(inventory), ("27.0", "iPhone 17 Pro"))

    def test_device_runtime_bounds_are_respected(self):
        inventory = self.inventory()
        inventory["devicetypes"][1]["maxRuntimeVersion"] = 27 << 16
        self.assertEqual(select_simulator(inventory), ("27.0", "iPhone 17 Pro"))

    def test_missing_ordinary_viewport_fails_explicitly(self):
        inventory = self.inventory()
        inventory["devicetypes"] = inventory["devicetypes"][:1]
        with self.assertRaisesRegex(ValueError, "ordinary iPhone"):
            select_simulator(inventory)

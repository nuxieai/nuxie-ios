"""Choose the ordinary XCTest viewport independently of existing simulators."""
import json
import subprocess


def select_simulator(inventory):
    runtimes = sorted(
        (runtime for runtime in inventory["runtimes"]
         if runtime.get("isAvailable") and ".iOS-" in runtime["identifier"]),
        key=lambda runtime: tuple(int(part) for part in runtime["version"].split(".")),
        reverse=True,
    )
    for runtime in runtimes:
        supported = {device["identifier"] for device in runtime["supportedDeviceTypes"]}
        parts = [int(part) for part in runtime["version"].split(".")]
        parts += [0] * (3 - len(parts))
        version = (parts[0] << 16) | (parts[1] << 8) | parts[2]
        devices = [device for device in inventory["devicetypes"]
                   if device.get("productFamily") == "iPhone"
                   and device["identifier"] in supported
                   and "Duo" not in device["name"]
                   and device["minRuntimeVersion"] <= version <= device["maxRuntimeVersion"]]
        if devices:
            preferred = next((device for device in devices if device["name"] == "iPhone 17 Pro"), None)
            device = preferred or max(devices, key=lambda device: (device["minRuntimeVersion"], device["name"]))
            return runtime["version"], device["name"]
    raise ValueError("No available iOS runtime supports an ordinary iPhone test viewport")


if __name__ == "__main__":
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "--json"], text=True))
    version, name = select_simulator(inventory)
    print(version, name)

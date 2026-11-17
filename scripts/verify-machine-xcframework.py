#!/usr/bin/env python3
"""Check a NuxMachine.xcframework before it is staged.

The Nux machine's library is for tests only: it carries the .nux compiler and
a fixed stand-in world. Its builder writes NuxMachine.metadata.json beside the
bundle; this check requires that file to say so, and the bundle to hold one
static library and the NuxMachineC module for the device and the simulator.
"""

import json
import plistlib
import sys
from pathlib import Path

SLICES = {("ios", ""): "device", ("ios", "simulator"): "simulator"}


def fail(message: str) -> None:
    print(f"NuxMachine.xcframework: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: verify-machine-xcframework.py <NuxMachine.xcframework> <NuxMachine.metadata.json>")
    bundle, metadata_path = Path(sys.argv[1]), Path(sys.argv[2])
    if bundle.name != "NuxMachine.xcframework" or not bundle.is_dir():
        fail(f"{bundle} is not a NuxMachine.xcframework directory")
    if not metadata_path.is_file():
        fail(f"its metadata file is missing: {metadata_path}")
    metadata = json.loads(metadata_path.read_text())
    if metadata.get("purpose") != "tests-only":
        fail(f"its metadata says purpose {metadata.get('purpose')!r}, not 'tests-only'")
    if metadata.get("module") != "NuxMachineC":
        fail(f"its metadata names module {metadata.get('module')!r}, not 'NuxMachineC'")

    libraries = plistlib.loads((bundle / "Info.plist").read_bytes()).get("AvailableLibraries", [])
    found = {}
    for library in libraries:
        key = (library.get("SupportedPlatform"), library.get("SupportedPlatformVariant", ""))
        if key not in SLICES or key in found:
            fail(f"unexpected or repeated slice {library.get('LibraryIdentifier')}")
        if "arm64" not in library.get("SupportedArchitectures", []):
            fail(f"{library.get('LibraryIdentifier')} has no arm64 code")
        root = bundle / library["LibraryIdentifier"]
        if not (root / library["LibraryPath"]).is_file():
            fail(f"{library['LibraryIdentifier']} has no library {library['LibraryPath']}")
        headers = root / library.get("HeadersPath", "")
        if not (headers / "nux_machine.h").is_file():
            fail(f"{library['LibraryIdentifier']} has no nux_machine.h")
        modulemap = headers / "module.modulemap"
        if not modulemap.is_file() or "module NuxMachineC" not in modulemap.read_text():
            fail(f"{library['LibraryIdentifier']} has no module map declaring NuxMachineC")
        found[key] = library["LibraryIdentifier"]
    if set(found) != set(SLICES):
        fail("it needs exactly an iOS device slice and an iOS simulator slice")
    print("NuxMachine.xcframework: tests-only, device and simulator slices, NuxMachineC module")


if __name__ == "__main__":
    main()

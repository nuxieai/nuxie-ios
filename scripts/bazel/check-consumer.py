#!/usr/bin/env python3
"""Prove a prepared SDK's static/framework imports using only its manifest."""

import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def checked(command):
    subprocess.run(command, check=True)


def verify(manifest_path: Path, platform: str, configuration: str, architecture: str, allow_dirty: bool = False) -> None:
    root = manifest_path.parent
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("sourceDirty") and not allow_dirty:
        raise ValueError("Source-addressed SDK consumption requires committed source")
    products = [product for product in manifest["products"]
                if product["platform"] == platform and product["configuration"] == configuration
                and architecture in product["architectures"]]
    if len(products) != 1:
        raise ValueError("Expected one prepared SDK product for the selected platform/configuration/architecture")
    product = products[0]
    native = product["nativeDependencies"][0]
    modules = {item["module"]: root / item["path"] for item in product["swiftModules"]
               if item["architecture"] == architecture}
    if set(modules) != {"Nuxie", "NuxieRuntime"} or not all(path.is_file() for path in modules.values()):
        raise ValueError("The prepared SDK must include its own Swift module and NuxieRuntime")
    headers = [root / item["path"] for item in product["swiftHeaders"]
               if item["module"] == "Nuxie" and item["architecture"] == architecture]
    framework = root / product["framework"]
    framework_header = framework / "Headers/Nuxie.h"
    if len(headers) != 1 or framework_header.read_bytes() != headers[0].read_bytes():
        raise ValueError("The framework must export its owning Swift header")
    for bundle in product["resourceBundles"]:
        resources = root / bundle
        if not all((resources / name).is_file() for name in ("PrivacyInfo.xcprivacy", "timezone-bundle.json", "LICENSE-unicode.txt")):
            raise ValueError("The prepared SDK is missing a required Nuxie_Nuxie.bundle resource")
    sdk = "macosx" if platform == "macos" else "iphonesimulator" if platform == "ios-simulator" else "iphoneos"
    target = architecture + ("-apple-macosx12.0" if platform == "macos" else "-apple-ios15.0")
    if platform == "ios-simulator":
        target += "-simulator"
    sdk_path = subprocess.check_output(["xcrun", "--sdk", sdk, "--show-sdk-path"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="nuxie-sdk-consumer-") as temporary:
        stage = Path(temporary)
        consumer = stage / "Consumer.swift"
        consumer.write_text('import Nuxie\nimport NuxieRuntime\nimport NuxieRuntimeC\n'
                            'func configure() -> NuxieConfiguration { NuxieConfiguration(apiKey: "consumer-api-key") }\n')
        common = ["xcrun", "--sdk", sdk, "swiftc", "-typecheck", "-swift-version", "5", "-target", target,
                  "-sdk", sdk_path, "-I", str(root / native["headers"])]
        # Framework mode intentionally excludes the standalone Nuxie module.
        runtime_modules = stage / "runtime-modules"
        runtime_modules.mkdir()
        (runtime_modules / "NuxieRuntime.swiftmodule").symlink_to(modules["NuxieRuntime"])
        checked(common + ["-F", str(framework.parent), "-I", str(runtime_modules), str(consumer)])
        checked(common + ["-I", str(modules["Nuxie"].parent), str(consumer)])
    print(f"SDK consumer imports passed: {platform}/{configuration}/{architecture}, framework and static modules")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--platform", choices=("ios-device", "ios-simulator", "macos"), required=True)
    parser.add_argument("--configuration", choices=("Debug", "Release"), default="Release")
    parser.add_argument("--architecture", choices=("arm64", "x86_64"), required=True)
    parser.add_argument("--allow-dirty", action="store_true", help="Check explicitly selected development artifacts")
    args = parser.parse_args()
    verify(args.manifest.resolve(), args.platform, args.configuration, args.architecture, args.allow_dirty)

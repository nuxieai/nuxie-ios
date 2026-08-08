#!/usr/bin/env python3

import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse


def fail(message: str) -> None:
    raise SystemExit(f"runtime-package-pin: {message}")


if len(sys.argv) != 2:
    fail("usage: check-runtime-package-pin.py Runtime/artifact.json")

metadata_path = pathlib.Path(sys.argv[1])
try:
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    fail(f"cannot read {metadata_path}: {error}")

if set(metadata) != {"release", "url", "checksum"}:
    fail("artifact metadata must contain exactly release, url, and checksum")
if not all(isinstance(metadata[key], str) for key in metadata):
    fail("artifact metadata values must be strings")
if re.fullmatch(r"[0-9a-f]{64}", metadata["checksum"]) is None:
    fail("checksum is not a lowercase SHA-256")

parsed_url = urllib.parse.urlsplit(metadata["url"])
expected_prefix = f"/nuxieai/nuxie-runtime/releases/download/{metadata['release']}/"
if (
    parsed_url.scheme != "https"
    or parsed_url.netloc != "github.com"
    or not parsed_url.path.startswith(expected_prefix)
    or not parsed_url.path.endswith(".zip")
    or parsed_url.query
    or parsed_url.fragment
):
    fail("URL is not an immutable nuxie-runtime release asset")

def package_environment(local_selection=None):
    environment = dict(os.environ)
    environment.pop("NUXIE_RUNTIME_USE_LOCAL", None)
    if local_selection is not None:
        environment["NUXIE_RUNTIME_USE_LOCAL"] = local_selection
    return environment


def package_command(package_path: pathlib.Path) -> list[str]:
    return ["swift", "package", "dump-package", "--package-path", str(package_path)]


def dump_package(package_path: pathlib.Path, local_selection=None) -> dict:
    try:
        result = subprocess.run(
            package_command(package_path),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=package_environment(local_selection),
        )
        return json.loads(result.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as error:
        fail(f"cannot inspect Package.swift: {error}")


def require_dump_failure(
    package_path: pathlib.Path, local_selection: str, expected: str
) -> None:
    result = subprocess.run(
        package_command(package_path),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=package_environment(local_selection),
    )
    if result.returncode == 0 or expected not in result.stderr:
        fail(
            "Package.swift did not reject "
            f"NUXIE_RUNTIME_USE_LOCAL={local_selection!r}"
        )


def runtime_target(manifest: dict) -> dict:
    targets = [
        target
        for target in manifest.get("targets", [])
        if target.get("name") == "NuxieRuntimeFFI"
    ]
    if len(targets) != 1:
        fail("Package.swift must declare exactly one NuxieRuntimeFFI target")
    return targets[0]


def require_remote_target(manifest: dict) -> None:
    target = runtime_target(manifest)
    if target.get("type") != "binary" or target.get("path") is not None:
        fail("NuxieRuntimeFFI must be a remote binary target by default")
    if (
        target.get("url") != metadata["url"]
        or target.get("checksum") != metadata["checksum"]
    ):
        fail("Package.swift binary target differs from Runtime/artifact.json")


package_root = pathlib.Path(__file__).resolve().parent.parent
require_remote_target(dump_package(package_root))

# A pre-existing ignored cache must not select a local binary implicitly. The
# local path is allowed only when the caller opts in explicitly.
with tempfile.TemporaryDirectory(prefix="nuxie-runtime-package-pin-") as temporary:
    fixture_root = pathlib.Path(temporary)
    shutil.copy2(package_root / "Package.swift", fixture_root / "Package.swift")
    local_runtime = fixture_root / ".artifacts" / "NuxieRuntime.xcframework"
    local_runtime.mkdir(parents=True)

    require_remote_target(dump_package(fixture_root))
    local_target = runtime_target(dump_package(fixture_root, "1"))
    if local_target.get("type") != "binary" or local_target.get("url") is not None:
        fail("explicit local runtime selection must produce a local binary target")
    if pathlib.Path(local_target.get("path", "")).name != "NuxieRuntime.xcframework":
        fail("explicit local runtime selection did not use the staged XCFramework")

    require_dump_failure(
        fixture_root,
        "invalid",
        "NUXIE_RUNTIME_USE_LOCAL must be unset or 1",
    )
    missing_fixture = fixture_root / "missing-local"
    missing_fixture.mkdir()
    shutil.copy2(package_root / "Package.swift", missing_fixture / "Package.swift")
    require_dump_failure(
        missing_fixture,
        "1",
        "NUXIE_RUNTIME_USE_LOCAL=1 requires .artifacts/NuxieRuntime.xcframework",
    )

print(f"Runtime package pin passed: {metadata['release']} URL and checksum are atomic")

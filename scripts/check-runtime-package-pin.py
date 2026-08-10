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

artifact_set_path = metadata_path.with_name("artifact-set.json")
try:
    artifact_set = json.loads(artifact_set_path.read_text(encoding="utf-8"))
except (OSError, UnicodeError, json.JSONDecodeError) as error:
    fail(f"cannot read {artifact_set_path}: {error}")
if artifact_set.get("schemaVersion") != 6:
    fail("artifact-set schemaVersion must be 6")
source_revision = artifact_set.get("buildSourceRevision")
release_revision = artifact_set.get("releaseRevision")
build_inputs_hash = artifact_set.get("buildInputsHash")
runtime_version = artifact_set.get("runtimeVersion")
contract_fingerprint = artifact_set.get("contractFingerprint")
version_match = re.fullmatch(r"([0-9]+)\.([0-9]+)\.([0-9]+)", str(runtime_version))
if version_match is None or tuple(map(int, version_match.groups())) < (0, 5, 0):
    fail("artifact-set must select the slim runtime release (0.5.0 or newer)")
if (
    not isinstance(source_revision, str)
    or re.fullmatch(r"[0-9a-f]{40}", source_revision) is None
):
    fail("artifact-set buildSourceRevision is not an exact git revision")
if release_revision != source_revision:
    fail("artifact-set releaseRevision differs from buildSourceRevision")
if (
    not isinstance(build_inputs_hash, str)
    or re.fullmatch(r"[0-9a-f]{64}", build_inputs_hash) is None
):
    fail("artifact-set buildInputsHash is not a lowercase SHA-256")
if (
    not isinstance(contract_fingerprint, str)
    or re.fullmatch(r"[0-9a-f]{64}", contract_fingerprint) is None
):
    fail("artifact-set contractFingerprint is not a lowercase SHA-256")
if artifact_set.get("runtimeIdentity") != f"{runtime_version}@{source_revision}":
    fail("artifact-set runtime identity is inconsistent")
if metadata["release"] != f"apple-runtime-v{runtime_version}":
    fail("artifact-set runtime version differs from release tag")
artifacts = artifact_set.get("artifacts")
if (
    not isinstance(artifacts, list)
    or not all(isinstance(artifact, dict) for artifact in artifacts)
    or [artifact.get("kind") for artifact in artifacts]
    != [
        "full-apple",
        "ios-only",
    ]
):
    fail("artifact-set must contain ordered full-apple and ios-only artifacts")
full_artifacts = [
    artifact
    for artifact in artifacts
    if artifact.get("kind") == "full-apple"
]
if len(full_artifacts) != 1:
    fail("artifact-set must contain exactly one full-apple artifact")
full_artifact = full_artifacts[0]
if (
    full_artifact.get("archiveName") != pathlib.PurePosixPath(metadata["url"]).name
    or full_artifact.get("bundleName") != "NuxieRuntime.xcframework"
    or full_artifact.get("swiftPackageChecksum") != metadata["checksum"]
):
    fail("artifact-set full-apple artifact differs from the package pin")
if set(full_artifact.get("targets", [])) != {
    "aarch64-apple-darwin",
    "aarch64-apple-ios",
    "aarch64-apple-ios-sim",
    "x86_64-apple-darwin",
    "x86_64-apple-ios",
}:
    fail("artifact-set full-apple target matrix is incomplete")
ios_artifact = artifacts[1]
if (
    ios_artifact.get("archiveName") != "NuxieRuntime-iOS.xcframework.zip"
    or ios_artifact.get("bundleName") != "NuxieRuntime.xcframework"
    or re.fullmatch(r"[0-9a-f]{64}", str(ios_artifact.get("swiftPackageChecksum"))) is None
):
    fail("artifact-set iOS-only artifact is incomplete")
if set(ios_artifact.get("targets", [])) != {
    "aarch64-apple-ios",
    "aarch64-apple-ios-sim",
    "x86_64-apple-ios",
}:
    fail("artifact-set iOS-only target matrix is incomplete")
if ios_artifact.get("swiftPackageChecksum") == metadata["checksum"]:
    fail("full-apple and iOS-only archives must have distinct checksums")

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
        if target.get("name") == "NuxieRuntimeBinary"
    ]
    if len(targets) != 1:
        fail("Package.swift must declare exactly one NuxieRuntimeBinary target")
    return targets[0]


def require_remote_target(manifest: dict) -> None:
    target = runtime_target(manifest)
    if target.get("type") != "binary" or target.get("path") is not None:
        fail("NuxieRuntimeBinary must be a remote binary target by default")
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

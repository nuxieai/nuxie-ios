#!/usr/bin/env python3
"""Build the SDK through native Bazel rules and stage its consumer products."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import shutil
import shlex
import stat
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cache import startup_options
from launcher import executable as installed_bazelisk

ROOT = Path(__file__).resolve().parents[2]
PLATFORMS = {
    "ios-device": {"arm64": "ios_arm64"},
    "ios-simulator": {"arm64": "ios_sim_arm64", "x86_64": "ios_x86_64"},
    "macos": {"arm64": "macos_arm64", "x86_64": "macos_x86_64"},
}
SUITES = {
    "unit": ["//:NuxieSDKUnitTests"],
    "native-runtime": ["//:NuxieSDKUnitTests"],
    "hosted-input": ["//:NuxieExperienceInputTests"],
    "integration": ["//:NuxieSDKIntegrationTests"],
    "macos-unit": ["//:NuxieSDKMacUnitTests"],
    "storekit": ["//:NuxieSDKStoreKitTests"],
    "video": ["//:NuxieVideoDeviceTests"],
    "runtime-ui": ["//:NuxieExperienceRuntimeUITests"],
    "reference-ui": ["//:NuxieExperienceRuntimeReferenceUITests"],
    "e2e": ["//:NuxieE2EAppTests", "//:NuxieE2EAppUITests"],
}
SCHEMES = {
    "NuxieSDKUnitTests": "unit", "NuxieSDKMacUnitTests": "macos-unit",
    "NuxieSDKIntegrationTests": "integration", "NuxieExperienceInputTests": "hosted-input",
    "NuxieVideoDeviceTests": "video", "NuxieSDKStoreKitTests": "storekit",
    "NuxieExperienceRuntimeUITests": "runtime-ui", "NuxieExperienceRuntimeReferenceUITests": "reference-ui",
    "NuxieSDKE2ETests": "e2e",
}


def run(command: list[str], *, capture: bool = False, raw: bool = False) -> str:
    result = subprocess.run(command, cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return (result.stdout if raw else result.stdout.strip()) if capture else ""


def bazel_command() -> list[str]:
    binary = os.environ.get("NUXIE_BAZEL_BIN") or os.environ.get("BAZEL") or shutil.which("bazelisk") or shutil.which("bazel")
    if not binary and (ROOT.parent.parent / "node_modules/.bin/bazelisk").is_file():
        binary = str(ROOT.parent.parent / "node_modules/.bin/bazelisk")
    if not binary:
        binary = installed_bazelisk()
    command = [binary, "--nosystem_rc", "--nohome_rc", *startup_options(ROOT)]
    user_root = os.environ.get("NUXIE_BAZEL_OUTPUT_USER_ROOT")
    if user_root:
        if not Path(user_root).is_absolute() or any(c in user_root for c in "\0\r\n"):
            raise ValueError("NUXIE_BAZEL_OUTPUT_USER_ROOT must be an absolute path on one line")
        command.append("--output_user_root=" + user_root)
    output_base = os.environ.get("NUXIE_IOS_BAZEL_OUTPUT_BASE")
    if output_base:
        command.append("--output_base=" + str(Path(output_base).resolve()))
    if os.environ.get("NUXIE_BAZEL_BATCH") == "1" or os.environ.get("CI") or os.environ.get("BUILDKITE") or os.environ.get("GITHUB_ACTIONS"):
        command.append("--batch")
    return command


def options(configuration: str, sdk_platform: str, architecture: str) -> list[str]:
    cpu = PLATFORMS[sdk_platform][architecture]
    jobs = os.environ.get("NUXIE_BAZEL_JOBS", "2")
    if not jobs.isdecimal() or int(jobs) < 1:
        raise ValueError("NUXIE_BAZEL_JOBS must be a positive integer")
    return ["--compilation_mode=" + ("opt" if configuration == "Release" else "dbg"),
            "--platforms=@apple_support//platforms:" + cpu,
            "--apple_platforms=@apple_support//platforms:" + cpu,
            ("--macos_cpus=" + architecture if sdk_platform == "macos" else "--ios_multi_cpus=" + cpu.removeprefix("ios_")),
            "--jobs=" + jobs,
            "--macos_minimum_os=12.0" if sdk_platform == "macos" else "--ios_minimum_os=15.0"]


def outputs(label: str, flags: list[str]) -> list[Path]:
    result = run(bazel_command() + ["cquery", label, *flags, "--output=files", "--noshow_progress"], capture=True)
    execution_root = Path(run(bazel_command() + ["info", "execution_root", "--noshow_progress"], capture=True))
    if not execution_root.is_absolute():
        raise ValueError("Bazel must report an absolute execution root")
    # cquery paths are relative to Bazel's execution root. In particular,
    # external repository inputs have no corresponding checkout-local path.
    return [execution_root / line for line in result.splitlines() if line.strip()]


def owning_archive(files: list[Path], target: str) -> Path:
    selected = [path for path in files if path.name == target + ".zip"]
    if len(selected) != 1:
        raise ValueError(f"Expected exactly one {target}.zip from its configured target")
    if not selected[0].is_file():
        raise ValueError("The selected framework archive has not been built")
    return selected[0]


def extract_framework(archive: Path, destination: Path, bundle_name: str = "Nuxie.framework") -> Path:
    """Preserve macOS framework symlinks and reject archive path traversal."""
    with zipfile.ZipFile(archive) as bundle:
        for entry in bundle.infolist():
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename:
                raise ValueError("Framework archive contains an unsafe member path")
            output = destination.joinpath(*path.parts)
            if not output.resolve().is_relative_to(destination.resolve()):
                raise ValueError("Framework archive member escapes its staging directory")
            mode = entry.external_attr >> 16
            if entry.is_dir():
                output.mkdir(parents=True, exist_ok=True)
                continue
            output.parent.mkdir(parents=True, exist_ok=True)
            if stat.S_ISLNK(mode):
                link = bundle.read(entry).decode()
                if not (output.parent / link).resolve().is_relative_to(destination.resolve()):
                    raise ValueError("Framework archive contains an unsafe symlink")
                output.symlink_to(link)
            else:
                output.write_bytes(bundle.read(entry))
                if mode & 0o777:
                    output.chmod(mode & 0o777)
    frameworks = [path for path in destination.rglob(bundle_name) if path.is_dir()]
    if len(frameworks) != 1:
        raise ValueError("SDK archive must contain exactly one Nuxie.framework")
    return frameworks[0]


def publish_build(target: str, flags: list[str], sdk_platform: str, configuration: str) -> None:
    names = {
        "sdk": ("NuxieSDK", "Nuxie.framework"), "NuxieSDK": ("NuxieSDK", "Nuxie.framework"),
        "sdk_macos": ("NuxieSDKMac", "Nuxie.framework"), "NuxieSDKMac": ("NuxieSDKMac", "Nuxie.framework"),
        "NuxieExperienceRuntimeReferenceApp": ("NuxieExperienceRuntimeReferenceApp", "NuxieExperienceRuntimeReference.app"),
        "NuxieExperienceRuntimeHostApp": ("NuxieExperienceRuntimeHostApp", "NuxieExperienceRuntimeHost.app"),
        "NuxieE2EApp": ("NuxieE2EApp", "NuxieE2EApp.app"),
    }
    name = target.removeprefix("//:")
    if name not in names:
        return
    owner, bundle_name = names[name]
    archive_names = {owner + ".zip", owner + ".ipa"}
    if bundle_name.endswith(".app"):
        archive_names.add(bundle_name.removesuffix(".app") + ".ipa")
    archives = [path for path in outputs(target, flags) if path.name in archive_names]
    if len(archives) != 1:
        raise ValueError("Expected one built SDK framework/application archive")
    directory = ROOT / ".bazel-artifacts/build" / sdk_platform / configuration
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".bundle-stage-", dir=directory) as temporary:
        stage = Path(temporary)
        bundle = extract_framework(archives[0], stage, bundle_name)
        dependencies = []
        if bundle_name == "Nuxie.framework":
            dependencies = stage_framework_dependencies(owner, flags, sdk_platform, stage)
        if bundle_name == "Nuxie.framework" and sdk_platform != "macos":
            run([str(ROOT / "scripts/verify-customer-framework.sh"), str(bundle)])
        elif bundle_name == "NuxieExperienceRuntimeReference.app":
            run([str(ROOT / "scripts/verify-runtime-reference-app.sh"), str(bundle)])
        destination = directory / bundle_name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.move(bundle, destination)
        for dependency in dependencies:
            destination = directory / dependency.name
            if destination.is_dir():
                shutil.rmtree(destination)
            elif destination.exists():
                destination.unlink()
            shutil.move(dependency, destination)


def runtime_root(flags: list[str]) -> Path:
    roots = set()
    for file in outputs("@nuxie_runtime_release//:xcframework", flags):
        for ancestor in file.parents:
            if ancestor.name == "NuxieRuntime.xcframework":
                roots.add(ancestor)
                break
    if len(roots) != 1:
        raise ValueError("Expected exactly one checksum-pinned runtime XCFramework")
    return roots.pop()


def verify_framework_platform(framework: Path, sdk_platform: str, architecture: str) -> None:
    """Check the built Mach-O, independently of requested Bazel platform labels."""
    expected = {"ios-device": "IOS", "ios-simulator": "IOSSIMULATOR", "macos": "MACOS"}[sdk_platform]
    binary = framework / framework.name.removesuffix(".framework")
    metadata = run(["xcrun", "vtool", "-arch", architecture, "-show-build", str(binary)], capture=True)
    actual = re.findall(r"^\s*platform\s+(\S+)\s*$", metadata, re.MULTILINE)
    if actual != [expected]:
        raise ValueError(f"Prepared {sdk_platform}/{architecture} framework has Mach-O platforms {actual}; expected {expected}")


def runtime_slice(runtime: Path, sdk_platform: str, architectures: list[str]) -> dict:
    available = plistlib.loads((runtime / "Info.plist").read_bytes())["AvailableLibraries"]
    platform_name = "macos" if sdk_platform == "macos" else "ios"
    variant = "simulator" if sdk_platform == "ios-simulator" else ""
    libraries = [library for library in available
                 if library["SupportedPlatform"] == platform_name
                 and library.get("SupportedPlatformVariant", "") == variant
                 and set(architectures).issubset(library["SupportedArchitectures"])]
    if len(libraries) != 1:
        raise ValueError("The pinned runtime must contain exactly one compatible SDK platform slice")
    return libraries[0]


def stage_framework_dependencies(target: str, flags: list[str], sdk_platform: str, stage: Path) -> list[Path]:
    """Retain the exact Swift/C imports needed to load the compiled framework."""
    files = outputs(f'filter("^//:NuxieRuntime$", deps(//:{target}))', flags)
    modules = [source for source in files if source.name == "NuxieRuntime.swiftmodule"]
    if len(modules) != 1 or not modules[0].is_file():
        raise ValueError("The built SDK framework requires its configured NuxieRuntime Swift module")
    dependencies = []
    for source in files:
        if source.suffix in {".swiftmodule", ".swiftdoc", ".swiftsourceinfo", ".swiftinterface"}:
            destination = stage / source.name
            shutil.copy2(source, destination)
            dependencies.append(destination)
    runtime = runtime_root(flags)
    library = runtime_slice(runtime, sdk_platform, [])
    headers = runtime / library["LibraryIdentifier"] / library["HeadersPath"]
    if not (headers / "module.modulemap").is_file():
        raise ValueError("The pinned runtime slice must include its C ABI module map")
    destination = stage / "runtime-headers"
    shutil.copytree(headers, destination)
    dependencies.append(destination)
    return dependencies


def test_options(args, sdk_platform):
    flags = []
    selectors = [args.test_filter] if args.test_filter else []
    for flag in shlex.split(args.xcodebuild_test_flags or ""):
        if flag.startswith("-only-testing:"):
            selectors.append(flag.removeprefix("-only-testing:"))
        elif flag != "-quiet":
            raise ValueError("Unsupported Xcode test flag; use --test-filter for Bazel test selection")
    if args.suite == "native-runtime" and not selectors:
        selectors = ["NuxieSDKUnitTests/" + name for name in (
            "NuxieNativeRuntimeTests", "ExperienceInteractiveScreenTests", "ExperienceRuntimePresentationLoopTests")]
    if selectors:
        # Xcode accepts Target/Class[/method]; xctestrunner passes the filter
        # directly to XCTest, which identifies Swift classes as Module.Class.
        identifiers = []
        modules = {label.removeprefix("//:") for labels in SUITES.values() for label in labels}
        for selector in ",".join(selectors).split(","):
            excluded = selector.startswith("-")
            parts = selector.removeprefix("-").split("/")
            if len(parts) > 1 and parts[0] in modules:
                parts = [parts[0] + "." + parts[1], *parts[2:]]
            identifiers.append(("-" if excluded else "") + "/".join(parts))
        flags.append("--test_filter=" + ",".join(identifiers))
    if sdk_platform != "macos":
        destination = dict(item.split("=", 1) for item in (args.destination or "").split(",") if "=" in item)
        device = args.simulator_device or destination.get("name")
        version = args.simulator_os or destination.get("OS")
        if "id" in destination:
            devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))["devices"]
            matches = [(runtime, device) for runtime, values in devices.items() for device in values if device.get("udid") == destination["id"]]
            if len(matches) != 1:
                raise ValueError("The selected simulator is unavailable")
            runtime, selected = matches[0]
            device = selected["name"]
            version = runtime.split(".iOS-", 1)[1].replace("-", ".")
        if device:
            flags.append("--ios_simulator_device=" + device)
        if version:
            flags.append("--ios_simulator_version=" + version)
    flags += ["--test_env=" + key for key in sorted(os.environ) if key.startswith("NUXIE_E2E_")]
    if "NUXIE_STOREKIT_REQUIRE_AVAILABLE" in os.environ:
        flags.append("--test_env=NUXIE_STOREKIT_REQUIRE_AVAILABLE=" + os.environ["NUXIE_STOREKIT_REQUIRE_AVAILABLE"])
    return flags


def verify_test_results(labels: list[str]) -> None:
    testlogs = Path(run(bazel_command() + ["info", "bazel-testlogs", "--noshow_progress"], capture=True))
    if not testlogs.is_absolute():
        raise ValueError("Bazel must report an absolute test log directory")
    for label in labels:
        package, name = label.removeprefix("//").split(":", 1)
        log = testlogs / package / name / "test.log"
        if not log.is_file():
            raise ValueError(f"The XCTest test log is missing for {label}: {log}")
        counts = [int(count) for count in re.findall(r"Executed (\d+) tests?\b", log.read_text())]
        if not counts or max(counts) == 0:
            raise ValueError(f"{label} executed no XCTest cases; check the test selector in {log}")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def artifact_inventory(directory: Path) -> list[dict]:
    artifacts = []
    for path in sorted(directory.rglob("*")):
        if path.is_symlink() or not path.is_file() or path.name == "sdk-artifacts.json":
            continue
        relative = path.relative_to(directory).as_posix()
        kind = "file"
        if relative.startswith("runtime/"):
            kind = "runtime-file"
        elif relative.startswith("licenses/"):
            kind = "license"
        elif path.suffix in {".swiftmodule", ".swiftinterface", ".swiftdoc", ".swiftsourceinfo"}:
            kind = "swiftmodule"
        elif path.suffix == ".a":
            kind = "static-library"
        elif any(part.endswith(".bundle") for part in path.parts):
            kind = "resource-file"
        elif any(part.endswith(".framework") for part in path.parts):
            kind = "framework-file"
        artifacts.append({"kind": kind, "path": relative, "sha256": sha256(path), "size": path.stat().st_size})
    return artifacts


def manifest(directory: Path, products: list[dict], revision: str, dirty: bool,
             artifact: dict, artifact_set: dict, source_digest: str | None = None) -> dict:
    return {"schemaVersion": 1, "sdk": "ios", "sourceRevision": revision,
            "sourceDirty": dirty, "sourceContentDigest": source_digest, "runtime": {
                "release": artifact["release"], "url": artifact["url"], "checksum": artifact["checksum"],
                "sourceCommit": artifact_set["buildSourceRevision"], "identity": artifact_set["runtimeIdentity"],
                "path": "runtime/NuxieRuntime.xcframework",
            }, "products": products, "artifacts": artifact_inventory(directory),
            "symlinks": [{"path": path.relative_to(directory).as_posix(), "target": os.readlink(path)}
                         for path in sorted(directory.rglob("*")) if path.is_symlink()]}


def merge_framework(source: Path, destination: Path) -> None:
    if not destination.exists():
        shutil.copytree(source, destination, symlinks=True)
        return
    binary = (destination / "Nuxie").resolve()
    run(["xcrun", "lipo", "-create", str(binary), str((source / "Nuxie").resolve()), "-output", str(binary)])
    for modules in source.rglob("*.swiftmodule"):
        if modules.is_dir():
            shutil.copytree(modules, destination / modules.relative_to(source), dirs_exist_ok=True)


def runtime_dependencies(directory: Path, sdk_platform: str, architectures: list[str]) -> dict:
    """Select compile/link inputs from the actual XCFramework slice metadata."""
    runtime = directory / "runtime/NuxieRuntime.xcframework"
    library = runtime_slice(runtime, sdk_platform, architectures)
    slice_path = runtime / library["LibraryIdentifier"]
    native_archive = slice_path / library["LibraryPath"]
    headers = slice_path / library["HeadersPath"]
    modulemap = headers / "module.modulemap"
    if not native_archive.is_file() or not modulemap.is_file():
        raise ValueError("The pinned runtime slice must contain its static archive and C ABI module map")
    return {"module": "NuxieRuntimeC", "library": native_archive.relative_to(directory).as_posix(),
            "headers": headers.relative_to(directory).as_posix(),
            "moduleMap": modulemap.relative_to(directory).as_posix(),
            "sdkFrameworks": ["CoreGraphics", "CoreText", "CoreVideo", "CryptoKit", "Foundation",
                              "ImageIO", "Metal", "QuartzCore", "Security"]}


def check_owned_output(output: Path) -> None:
    if not output.exists() or not any(output.iterdir()):
        return
    manifest_path = output / "sdk-artifacts.json"
    if not manifest_path.is_file():
        raise ValueError("Refusing to replace an output directory without an iOS SDK artifact manifest")
    previous = json.loads(manifest_path.read_text())
    if previous.get("schemaVersion") != 1 or previous.get("sdk") != "ios":
        raise ValueError("Refusing to replace an output directory without an iOS SDK artifact manifest")
    owned = {"sdk-artifacts.json"}
    for artifact in previous.get("artifacts", []) + previous.get("symlinks", []):
        path = PurePosixPath(artifact["path"])
        if path.is_absolute() or ".." in path.parts:
            raise ValueError("The existing SDK artifact manifest contains an unsafe path")
        owned.add(path.as_posix())
        owned.update(parent.as_posix() for parent in path.parents)
    for file in output.rglob("*"):
        if file.relative_to(output).as_posix() not in owned:
            raise ValueError("Refusing to replace SDK output containing files absent from its artifact manifest")


def source_identity(excluded: list[Path]) -> tuple[str, bool, str]:
    pathspecs = ["."] + [":(exclude)" + path.relative_to(ROOT).as_posix()
                         for path in excluded if path.is_relative_to(ROOT)]
    revision = run(["git", "rev-parse", "HEAD"], capture=True)
    dirty = bool(run(["git", "status", "--porcelain", "--untracked-files=all", "--", *pathspecs], capture=True))
    paths = sorted(set(run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z",
                            "--", *pathspecs], capture=True, raw=True).split("\0")) - {""})
    inputs = []
    for relative in paths:
        file = ROOT / relative
        if file.is_symlink():
            inputs.append([relative, "symlink", os.readlink(file)])
        elif file.is_file():
            inputs.append([relative, "file", bool(file.stat().st_mode & 0o111), sha256(file)])
        else:
            inputs.append([relative, "absent"])
    digest = hashlib.sha256(json.dumps(inputs, separators=(",", ":")).encode()).hexdigest()
    return revision, dirty, digest


def prepare(args: argparse.Namespace) -> None:
    if os.environ.get("NUXIE_RUNTIME_USE_LOCAL", ""):
        raise ValueError("Distribution preparation requires the pinned release; use build/test for a local runtime")
    output = Path(args.output).expanduser().resolve()
    if output == ROOT or ROOT.is_relative_to(output):
        raise ValueError("Choose a dedicated artifact output directory")
    check_owned_output(output)
    revision, dirty, source_digest = source_identity([output])
    if dirty and not getattr(args, "allow_dirty", False):
        raise ValueError("SDK distribution preparation requires committed source; --allow-dirty is for development artifacts")
    output.parent.mkdir(parents=True, exist_ok=True)
    products = []
    with tempfile.TemporaryDirectory(prefix="nuxie-sdk-stage-", dir=output.parent) as temporary:
        stage = Path(temporary) / "products"
        stage.mkdir()
        for sdk_platform in args.platform or PLATFORMS:
            architectures = getattr(args, "architecture", None) or list(PLATFORMS[sdk_platform])
            if len(architectures) != len(set(architectures)) or any(architecture not in PLATFORMS[sdk_platform] for architecture in architectures):
                raise ValueError("Select unique architectures supported by each requested SDK platform")
            target = "NuxieSDKMac" if sdk_platform == "macos" else "NuxieSDK"
            product = {"platform": sdk_platform, "configuration": args.configuration,
                       "framework": f"{sdk_platform}/{args.configuration}/Nuxie.framework", "module": "Nuxie",
                       "architectures": architectures, "staticLibraries": [], "swiftModules": [],
                       "swiftHeaders": [], "swiftDependencies": ["NuxieRuntime"], "resourceBundles": []}
            for architecture in architectures:
                flags = options(args.configuration, sdk_platform, architecture)
                run(bazel_command() + ["build", *flags, "//:" + target])
                with tempfile.TemporaryDirectory(prefix="framework-", dir=temporary) as extracted:
                    framework = extract_framework(owning_archive(outputs("//:" + target, flags), target), Path(extracted))
                    verify_framework_platform(framework, sdk_platform, architecture)
                    merge_framework(framework, stage / product["framework"])
                static_directory = stage / sdk_platform / args.configuration / "static" / architecture
                static_directory.mkdir(parents=True)
                for module in ("Nuxie", "NuxieRuntime"):
                    # These are the exact configured modules linked into the
                    # selected framework, including its deployment target.
                    selection = f'filter("^//:{module}$", deps(//:{target}))'
                    for source in outputs(selection, flags):
                        if source.suffix not in {".a", ".swiftmodule", ".swiftinterface", ".swiftdoc", ".swiftsourceinfo", ".h"}:
                            continue
                        destination = static_directory / source.name
                        shutil.copy2(source, destination)
                        reference = {"module": module, "architecture": architecture,
                                     "path": destination.relative_to(stage).as_posix()}
                        if source.suffix == ".a":
                            product["staticLibraries"].append(reference)
                        elif source.suffix == ".swiftmodule":
                            product["swiftModules"].append(reference)
                        elif source.suffix == ".h":
                            product["swiftHeaders"].append(reference)
            resources = [path for path in (stage / product["framework"]).rglob("Nuxie_Nuxie.bundle")
                         if path.is_dir() and not path.is_symlink()]
            if len(resources) != 1:
                raise ValueError("The built SDK framework must carry exactly one Nuxie_Nuxie.bundle")
            resource_path = f"{sdk_platform}/{args.configuration}/Nuxie_Nuxie.bundle"
            shutil.copytree(resources[0], stage / resource_path, symlinks=True)
            product["resourceBundles"] = [resource_path]
            products.append(product)
            if sdk_platform != "macos":
                run([str(ROOT / "scripts/verify-customer-framework.sh"), str(stage / product["framework"])])
        shutil.copytree(runtime_root(flags), stage / "runtime/NuxieRuntime.xcframework", symlinks=True)
        for product in products:
            product["nativeDependencies"] = [runtime_dependencies(stage, product["platform"], product["architectures"])]
        licenses = stage / "licenses"
        licenses.mkdir()
        for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
            shutil.copy2(ROOT / name, licenses / name)
        artifact = json.loads((ROOT / "Runtime/artifact.json").read_text())
        artifact_set = json.loads((ROOT / "Runtime/artifact-set.json").read_text())
        if source_identity([output, Path(temporary)]) != (revision, dirty, source_digest):
            raise ValueError("SDK source changed during preparation; rerun against one source revision")
        result = manifest(stage, products, revision, dirty, artifact, artifact_set, source_digest)
        (stage / "sdk-artifacts.json").write_text(json.dumps(result, indent=2) + "\n")
        backup = Path(temporary) / "previous"
        if output.exists():
            output.rename(backup)
        try:
            stage.rename(output)
        except BaseException:
            if backup.exists():
                backup.rename(output)
            raise
    print(output / "sdk-artifacts.json")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for command in ("build", "test", "prepare", "plan"):
        sub = commands.add_parser(command)
        sub.add_argument("--configuration", choices=("Debug", "Release"), default="Release" if command in ("prepare", "plan") else "Debug")
        sub.add_argument("--platform", choices=PLATFORMS, action="append")
        if command in ("prepare", "plan"):
            sub.add_argument("--output", required=command == "prepare")
            sub.add_argument("--architecture", choices=("arm64", "x86_64"), action="append")
            if command == "prepare":
                sub.add_argument("--allow-dirty", action="store_true", help="Prepare development artifacts with dirty state and source digest")
        elif command == "test":
            sub.add_argument("--suite", choices=[*SUITES, "all"], default="all")
            sub.add_argument("--scheme", choices=SCHEMES)
            sub.add_argument("--test-filter")
            sub.add_argument("--simulator-device")
            sub.add_argument("--simulator-os")
            sub.add_argument("--destination")
            sub.add_argument("--xcodebuild-test-flags")
        else:
            sub.add_argument("targets", nargs="*")
    args = parser.parse_args()
    if args.platform and len(args.platform) != len(set(args.platform)):
        parser.error("Each platform may be requested only once")
    try:
        if args.command == "prepare":
            prepare(args)
        elif args.command == "plan":
            print(json.dumps({"configuration": args.configuration, "platforms": args.platform or list(PLATFORMS),
                              "architectures": {name: args.architecture or list(PLATFORMS[name]) for name in args.platform or PLATFORMS},
                              "runtime": json.loads((ROOT / "Runtime/artifact.json").read_text())}, indent=2))
        else:
            if args.command == "test" and args.scheme:
                args.suite = SCHEMES[args.scheme]
            if args.command == "test" and args.suite == "all":
                if args.platform:
                    parser.error("Use an explicit test suite when selecting one platform")
                for suite in ("unit", "native-runtime", "hosted-input", "integration", "macos-unit"):
                    sdk_platform = "macos" if suite == "macos-unit" else "ios-simulator"
                    architecture = "arm64" if platform.machine() == "arm64" else "x86_64"
                    args.suite = suite
                    flags = options(args.configuration, sdk_platform, architecture) + test_options(args, sdk_platform)
                    run(bazel_command() + ["test", *flags, *SUITES[suite]])
                    verify_test_results(SUITES[suite])
                return
            sdk_platform = (args.platform or ["macos" if args.command == "test" and args.suite == "macos-unit" else "ios-simulator"])[0]
            if args.platform and len(args.platform) != 1:
                parser.error("build/test select one platform; prepare supports multiple platforms")
            architecture = "arm64" if platform.machine() == "arm64" or sdk_platform == "ios-device" else "x86_64"
            flags = options(args.configuration, sdk_platform, architecture)
            if args.command == "build":
                targets = args.targets or ["//:sdk_macos" if sdk_platform == "macos" else "//:sdk"]
            else:
                targets = SUITES[args.suite]
                flags += test_options(args, sdk_platform)
            run(bazel_command() + [args.command, *flags, *targets])
            if args.command == "test":
                verify_test_results(targets)
            if args.command == "build":
                for target in targets:
                    publish_build(target, flags, sdk_platform, args.configuration)
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()

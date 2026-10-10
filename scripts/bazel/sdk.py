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
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cache import startup_options

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


def run(command: list[str], *, capture: bool = False, raw: bool = False) -> str:
    result = subprocess.run(command, cwd=ROOT, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return (result.stdout if raw else result.stdout.strip()) if capture else ""


def bazel_command() -> list[str]:
    binary = os.environ.get("NUXIE_BAZEL_BIN") or os.environ.get("BAZEL") or shutil.which("bazelisk") or shutil.which("bazel")
    if not binary and (ROOT.parent.parent / "node_modules/.bin/bazelisk").is_file():
        binary = str(ROOT.parent.parent / "node_modules/.bin/bazelisk")
    if not binary:
        raise ValueError("Install Bazelisk or set BAZEL to its executable path")
    command = [binary, "--nosystem_rc", "--nohome_rc", *startup_options(ROOT)]
    output_base = os.environ.get("NUXIE_IOS_BAZEL_OUTPUT_BASE")
    if output_base:
        command.append("--output_base=" + str(Path(output_base).resolve()))
    return command


def options(configuration: str, sdk_platform: str, architecture: str) -> list[str]:
    cpu = PLATFORMS[sdk_platform][architecture]
    return ["--compilation_mode=" + ("opt" if configuration == "Release" else "dbg"),
            "--platforms=@apple_support//platforms:" + cpu, "--jobs=2",
            "--macos_minimum_os=12.0" if sdk_platform == "macos" else "--ios_minimum_os=15.0"]


def outputs(label: str, flags: list[str]) -> list[Path]:
    result = run(bazel_command() + ["cquery", label, *flags, "--output=files", "--noshow_progress"], capture=True)
    return [ROOT / line for line in result.splitlines() if line.strip()]


def owning_archive(files: list[Path], target: str) -> Path:
    selected = [path for path in files if path.name == target + ".zip"]
    if len(selected) != 1:
        raise ValueError(f"Expected exactly one {target}.zip from its configured target")
    if not selected[0].is_file():
        raise ValueError("The selected framework archive has not been built")
    return selected[0]


def extract_framework(archive: Path, destination: Path) -> Path:
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
    frameworks = [path for path in destination.rglob("Nuxie.framework") if path.is_dir()]
    if len(frameworks) != 1:
        raise ValueError("SDK archive must contain exactly one Nuxie.framework")
    return frameworks[0]


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
    available = plistlib.loads((runtime / "Info.plist").read_bytes())["AvailableLibraries"]
    platform_name = "macos" if sdk_platform == "macos" else "ios"
    variant = "simulator" if sdk_platform == "ios-simulator" else ""
    libraries = [library for library in available
                 if library["SupportedPlatform"] == platform_name
                 and library.get("SupportedPlatformVariant", "") == variant
                 and set(architectures).issubset(library["SupportedArchitectures"])]
    if len(libraries) != 1:
        raise ValueError("The pinned runtime must contain exactly one compatible SDK platform slice")
    library = libraries[0]
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
            target = "NuxieSDKMac" if sdk_platform == "macos" else "NuxieSDK"
            product = {"platform": sdk_platform, "configuration": args.configuration,
                       "framework": f"{sdk_platform}/{args.configuration}/Nuxie.framework", "module": "Nuxie",
                       "architectures": list(PLATFORMS[sdk_platform]), "staticLibraries": [], "swiftModules": [],
                       "swiftHeaders": [], "swiftDependencies": ["NuxieRuntime"], "resourceBundles": []}
            for architecture in PLATFORMS[sdk_platform]:
                flags = options(args.configuration, sdk_platform, architecture)
                run(bazel_command() + ["build", *flags, "//:" + target])
                with tempfile.TemporaryDirectory(prefix="framework-", dir=temporary) as extracted:
                    framework = extract_framework(owning_archive(outputs("//:" + target, flags), target), Path(extracted))
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
        runtime_files = outputs("@nuxie_runtime_release//:xcframework", flags)
        runtime_roots = set()
        for file in runtime_files:
            for ancestor in file.parents:
                if ancestor.name == "NuxieRuntime.xcframework":
                    runtime_roots.add(ancestor)
                    break
        if len(runtime_roots) != 1:
            raise ValueError("Expected exactly one checksum-pinned runtime XCFramework")
        shutil.copytree(runtime_roots.pop(), stage / "runtime/NuxieRuntime.xcframework", symlinks=True)
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
            if command == "prepare":
                sub.add_argument("--allow-dirty", action="store_true", help="Prepare development artifacts with dirty state and source digest")
        elif command == "test":
            sub.add_argument("--suite", choices=[*SUITES, "all"], default="all")
            sub.add_argument("--test-filter")
            sub.add_argument("--simulator-device")
            sub.add_argument("--simulator-os")
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
                              "runtime": json.loads((ROOT / "Runtime/artifact.json").read_text())}, indent=2))
        else:
            sdk_platform = (args.platform or ["macos" if args.command == "test" and args.suite == "macos-unit" else "ios-simulator"])[0]
            if args.platform and len(args.platform) != 1:
                parser.error("build/test select one platform; prepare supports multiple platforms")
            architecture = "arm64" if platform.machine() == "arm64" or sdk_platform == "ios-device" else "x86_64"
            flags = options(args.configuration, sdk_platform, architecture)
            if args.command == "build":
                targets = args.targets or ["//:sdk_macos" if sdk_platform == "macos" else "//:sdk"]
            else:
                targets = ["//:sdk_tests", "//:NuxieSDKMacUnitTests"] if args.suite == "all" else SUITES[args.suite]
                selected = args.test_filter
                if args.suite == "native-runtime" and not selected:
                    selected = ",".join("NuxieSDKUnitTests/" + name for name in (
                        "NuxieNativeRuntimeTests", "ExperienceInteractiveScreenTests", "ExperienceRuntimePresentationLoopTests"))
                if selected:
                    flags.append("--test_filter=" + selected)
                if args.simulator_device:
                    flags.append("--ios_simulator_device=" + args.simulator_device)
                if args.simulator_os:
                    flags.append("--ios_simulator_version=" + args.simulator_os)
            run(bazel_command() + [args.command, *flags, *targets])
    except (ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error) + "\n")


if __name__ == "__main__":
    main()

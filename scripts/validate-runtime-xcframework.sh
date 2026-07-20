#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/NuxieRuntime.xcframework" >&2
    exit 64
fi

runtime="$1"
device_identifier="ios-arm64"
simulator_identifier="ios-arm64_x86_64-simulator"
device_archive="${runtime}/${device_identifier}/libnux_apple_runtime.a"
simulator_archive="${runtime}/${simulator_identifier}/libnux_apple_runtime.a"

if [[ ! -d "${runtime}" ]]; then
    echo "runtime XCFramework not found: ${runtime}" >&2
    exit 1
fi

required_paths=(
    "Info.plist"
    "LICENSE"
    "THIRD_PARTY_NOTICES.md"
    "${device_identifier}/libnux_apple_runtime.a"
    "${device_identifier}/Headers/nux_runtime.h"
    "${device_identifier}/Headers/nux_runtime.generated.h"
    "${device_identifier}/Headers/module.modulemap"
    "${simulator_identifier}/libnux_apple_runtime.a"
    "${simulator_identifier}/Headers/nux_runtime.h"
    "${simulator_identifier}/Headers/nux_runtime.generated.h"
    "${simulator_identifier}/Headers/module.modulemap"
)

for relative in "${required_paths[@]}"; do
    if [[ ! -s "${runtime}/${relative}" ]]; then
        echo "NuxieRuntime.xcframework is missing or has an empty ${relative}" >&2
        exit 1
    fi
done

plutil -lint "${runtime}/Info.plist" >/dev/null
python3 - "${runtime}/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    manifest = plistlib.load(handle)

libraries = {
    library.get("LibraryIdentifier"): library
    for library in manifest.get("AvailableLibraries", [])
}

expected = {
    "ios-arm64": {
        "architectures": {"arm64"},
        "variant": None,
    },
    "ios-arm64_x86_64-simulator": {
        "architectures": {"arm64", "x86_64"},
        "variant": "simulator",
    },
}

for identifier, contract in expected.items():
    library = libraries.get(identifier)
    if library is None:
        raise SystemExit(f"NuxieRuntime.xcframework Info.plist is missing {identifier}")
    if library.get("SupportedPlatform") != "ios":
        raise SystemExit(f"{identifier} does not declare SupportedPlatform=iOS")
    if library.get("SupportedPlatformVariant") != contract["variant"]:
        raise SystemExit(f"{identifier} has the wrong platform variant")
    architectures = set(library.get("SupportedArchitectures", []))
    if not contract["architectures"].issubset(architectures):
        missing = sorted(contract["architectures"] - architectures)
        raise SystemExit(f"{identifier} is missing architectures: {', '.join(missing)}")
PY

require_architecture() {
    local archive="$1"
    local expected="$2"
    local architectures
    architectures="$(lipo -archs "${archive}")"
    if ! tr ' ' '\n' <<< "${architectures}" | grep -Fxq "${expected}"; then
        echo "${archive} is missing ${expected}; found: ${architectures}" >&2
        exit 1
    fi
}

require_symbol() {
    local archive="$1"
    local expected="$2"
    # Prefer classic nm. The published archive members embed __LLVM bitcode
    # produced by Rust's LLVM (21.x for apple-runtime-v0.1.0); llvm-nm from an
    # older Xcode (e.g. 26.2, Apple LLVM 17) cannot parse that bitcode and
    # silently drops those members' symbols, failing this check even though
    # the Mach-O symtab is intact and linking works. Classic nm reads only
    # the symtab, so it validates identically on every supported Xcode.
    local nm_tool
    if ! nm_tool="$(xcrun --find nm-classic 2>/dev/null)"; then
        nm_tool="nm"
    fi
    local nm_stderr
    nm_stderr="$(mktemp)"
    if ! "${nm_tool}" -gj "${archive}" 2>"${nm_stderr}" \
        | awk -v expected="${expected}" '$0 == expected { found = 1 } END { exit(found ? 0 : 1) }'; then
        echo "${archive} is missing exported symbol ${expected}" >&2
        echo "--- nm diagnostics (${nm_tool}) ---" >&2
        sed 's/^/nm stderr: /' "${nm_stderr}" >&2 || true
        rm -f "${nm_stderr}"
        exit 1
    fi
    rm -f "${nm_stderr}"
}

require_build_contract() {
    local archive="$1"
    local expected_platform="$2"
    local platforms
    local minimum_versions

    platforms="$(otool -l "${archive}" \
        | awk '$1 == "platform" { print $2 }' \
        | sort -u)"
    if [[ "${platforms}" != "${expected_platform}" ]]; then
        echo "${archive} has unexpected Mach-O platforms: ${platforms:-none}" >&2
        exit 1
    fi

    minimum_versions="$(otool -l "${archive}" \
        | awk '$1 == "minos" { print $2 }' \
        | sort -u)"
    if [[ -z "${minimum_versions}" ]]; then
        echo "${archive} does not declare a minimum OS version" >&2
        exit 1
    fi

    while IFS= read -r version; do
        local major=0
        local minor=0
        local patch=0
        IFS=. read -r major minor patch <<< "${version}"
        minor="${minor:-0}"
        patch="${patch:-0}"
        if (( major > 15 || (major == 15 && (minor > 0 || patch > 0)) )); then
            echo "${archive} contains an object requiring iOS ${version}; maximum is 15.0" >&2
            exit 1
        fi
    done <<< "${minimum_versions}"
}

require_architecture "${device_archive}" arm64
require_architecture "${simulator_archive}" arm64
require_architecture "${simulator_archive}" x86_64
require_build_contract "${device_archive}" 2
require_build_contract "${simulator_archive}" 7

for archive in "${device_archive}" "${simulator_archive}"; do
    require_symbol "${archive}" _nux_runtime_abi_major
    require_symbol "${archive}" _nux_flow_runtime_context_create
done

echo "Validated ${runtime}: device/simulator slices, iOS 15 load commands, headers, notices, and ABI symbols"

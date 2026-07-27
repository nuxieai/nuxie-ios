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
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT

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

require_header_contract() {
    local header="$1"
    for expected in \
        "NuxStatus nux_runtime_bind(" \
        "NuxStatus nux_runtime_build_provenance(" \
        "NuxStatus nux_flow_runtime_context_create_bound("; do
        if ! grep -Fq "${expected}" "${header}"; then
            echo "${header} is missing exact-identity declaration ${expected}" >&2
            exit 1
        fi
    done
    for removed in \
        "nux_runtime_abi_major(" \
        "nux_runtime_abi_minor(" \
        "nux_runtime_require_abi(" \
        "required_abi_major" \
        "minimum_abi_minor" \
        "NUX_STATUS_ABI_MISMATCH" \
        "nux_flow_runtime_context_create("; do
        if grep -Fq "${removed}" "${header}"; then
            echo "${header} still declares removed ABI negotiation ${removed}" >&2
            exit 1
        fi
    done
}

require_build_contract_per_architecture() {
    local archive="$1"
    local expected_platform="$2"
    local architecture_list
    local -a architectures
    local index=0

    architecture_list="$(lipo -archs "${archive}")"
    read -r -a architectures <<< "${architecture_list}"
    if [[ "${#architectures[@]}" -eq 0 ]]; then
        echo "${archive} contains no architectures" >&2
        exit 1
    fi

    for architecture in "${architectures[@]}"; do
        index=$((index + 1))
        local slice="${archive}"
        if [[ "${#architectures[@]}" -gt 1 ]]; then
            slice="${temporary}/build-contract-${index}-${architecture}.a"
            if ! lipo \
                "${archive}" \
                -thin "${architecture}" \
                -output "${slice}"; then
                echo "could not extract ${archive} (architecture ${architecture})" >&2
                exit 1
            fi
        fi
        require_build_contract \
            "${slice}" \
            "${expected_platform}" \
            "${archive} (architecture ${architecture})"
    done
}

require_build_contract() {
    local archive="$1"
    local expected_platform="$2"
    local context="${3:-${archive}}"
    local platforms
    local minimum_versions

    platforms="$(otool -l "${archive}" \
        | awk '$1 == "platform" { print $2 }' \
        | sort -u)"
    if [[ "${platforms}" != "${expected_platform}" ]]; then
        echo "${context} has unexpected Mach-O platforms: ${platforms:-none}" >&2
        exit 1
    fi

    minimum_versions="$(otool -l "${archive}" \
        | awk '$1 == "minos" { print $2 }' \
        | sort -u)"
    if [[ -z "${minimum_versions}" ]]; then
        echo "${context} does not declare a minimum OS version" >&2
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
            echo "${context} contains an object requiring iOS ${version}; maximum is 15.0" >&2
            exit 1
        fi
    done <<< "${minimum_versions}"
}

require_architecture "${device_archive}" arm64
require_architecture "${simulator_archive}" arm64
require_architecture "${simulator_archive}" x86_64
require_build_contract_per_architecture "${device_archive}" 2
require_build_contract_per_architecture "${simulator_archive}" 7

for archive in "${device_archive}" "${simulator_archive}"; do
    "${repository_root}/scripts/validate-runtime-archive-identity.sh" \
        "${archive}" \
        >/dev/null
done

for identifier in "${device_identifier}" "${simulator_identifier}"; do
    require_header_contract "${runtime}/${identifier}/Headers/nux_runtime.generated.h"
done

echo "Validated ${runtime}: exact runtime provenance, device/simulator slices, iOS 15 load commands, headers, notices, and identity-binding symbols"

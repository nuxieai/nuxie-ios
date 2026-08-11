#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/NuxieRuntime.xcframework" >&2
    exit 64
fi

runtime="$1"
device_identifier="ios-arm64"
simulator_identifier="ios-arm64_x86_64-simulator"
macos_identifier="macos-arm64_x86_64"
device_library="libnux_apple_product_extension.a"
simulator_library="libnux_apple_product_extension-simulator.a"
macos_library="libnux_apple_product_extension-macos.a"
device_archive="${runtime}/${device_identifier}/${device_library}"
simulator_archive="${runtime}/${simulator_identifier}/${simulator_library}"
macos_archive="${runtime}/${macos_identifier}/${macos_library}"

if [[ ! -d "${runtime}" ]]; then
    echo "runtime XCFramework not found: ${runtime}" >&2
    exit 1
fi

required_paths=(
    "Info.plist"
    "LICENSE"
    "THIRD_PARTY_NOTICES.md"
    "BUILD_INPUTS.json"
    "${device_identifier}/${device_library}"
    "${device_identifier}/Headers/nux_capi_apple.h"
    "${device_identifier}/Headers/nux_capi.generated.h"
    "${device_identifier}/Headers/nux_capi.h"
    "${device_identifier}/Headers/nux_product_extension.h"
    "${device_identifier}/Headers/module.modulemap"
    "${simulator_identifier}/${simulator_library}"
    "${simulator_identifier}/Headers/nux_capi_apple.h"
    "${simulator_identifier}/Headers/nux_capi.generated.h"
    "${simulator_identifier}/Headers/nux_capi.h"
    "${simulator_identifier}/Headers/nux_product_extension.h"
    "${simulator_identifier}/Headers/module.modulemap"
    "${macos_identifier}/${macos_library}"
    "${macos_identifier}/Headers/nux_capi_apple.h"
    "${macos_identifier}/Headers/nux_capi.generated.h"
    "${macos_identifier}/Headers/nux_capi.h"
    "${macos_identifier}/Headers/nux_product_extension.h"
    "${macos_identifier}/Headers/module.modulemap"
)

for relative in "${required_paths[@]}"; do
    if [[ ! -s "${runtime}/${relative}" ]]; then
        echo "NuxieRuntime.xcframework is missing or has an empty ${relative}" >&2
        exit 1
    fi
done

for module_map in \
    "${runtime}/${device_identifier}/Headers/module.modulemap" \
    "${runtime}/${simulator_identifier}/Headers/module.modulemap" \
    "${runtime}/${macos_identifier}/Headers/module.modulemap"; do
    if ! grep -Fxq 'module NuxieRuntimeC {' "${module_map}"; then
        echo "${module_map} does not expose the NuxieRuntimeC module" >&2
        exit 1
    fi
    if [[ "$(grep -Ec '^[[:space:]]*module[[:space:]]+' "${module_map}")" -ne 1 ]]; then
        echo "${module_map} must expose exactly one C module" >&2
        exit 1
    fi
    if grep -Eq '^[[:space:]]*module[[:space:]]+Nuxie(RuntimeFFI|ProductFFI|RuntimeLegacy)[[:space:]]*\{' "${module_map}"; then
        echo "${module_map} exposes a retired product runtime module" >&2
        exit 1
    fi
    if grep -Fxq 'module NuxieRuntime {' "${module_map}"; then
        echo "${module_map} shadows the Swift NuxieRuntime module" >&2
        exit 1
    fi
done

plutil -lint "${runtime}/Info.plist" >/dev/null
python3 - "${runtime}/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    manifest = plistlib.load(handle)

available_libraries = manifest.get("AvailableLibraries", [])
if not isinstance(available_libraries, list) or not all(
    isinstance(library, dict) for library in available_libraries
):
    raise SystemExit("NuxieRuntime.xcframework Info.plist has invalid libraries")

identifiers = [library.get("LibraryIdentifier") for library in available_libraries]
if len(identifiers) != len(set(identifiers)):
    raise SystemExit("NuxieRuntime.xcframework Info.plist has duplicate identifiers")
libraries = dict(zip(identifiers, available_libraries))

expected = {
    "ios-arm64": {
        "platform": "ios",
        "architectures": {"arm64"},
        "variant": None,
        "library": "libnux_apple_product_extension.a",
    },
    "ios-arm64_x86_64-simulator": {
        "platform": "ios",
        "architectures": {"arm64", "x86_64"},
        "variant": "simulator",
        "library": "libnux_apple_product_extension-simulator.a",
    },
    "macos-arm64_x86_64": {
        "platform": "macos",
        "architectures": {"arm64", "x86_64"},
        "variant": None,
        "library": "libnux_apple_product_extension-macos.a",
    },
}

if set(libraries) != set(expected):
    missing = sorted(set(expected) - set(libraries))
    extra = sorted(set(libraries) - set(expected), key=str)
    raise SystemExit(
        "NuxieRuntime.xcframework Info.plist identifiers differ: "
        f"missing={missing}, extra={extra}"
    )

for identifier, contract in expected.items():
    library = libraries.get(identifier)
    if library is None:
        raise SystemExit(f"NuxieRuntime.xcframework Info.plist is missing {identifier}")
    if library.get("SupportedPlatform") != contract["platform"]:
        raise SystemExit(
            f"{identifier} does not declare SupportedPlatform={contract['platform']}"
        )
    if library.get("SupportedPlatformVariant") != contract["variant"]:
        raise SystemExit(f"{identifier} has the wrong platform variant")
    if library.get("LibraryPath") != contract["library"]:
        raise SystemExit(f"{identifier} has the wrong LibraryPath")
    if library.get("BinaryPath") != contract["library"]:
        raise SystemExit(f"{identifier} has the wrong BinaryPath")
    if library.get("HeadersPath") != "Headers":
        raise SystemExit(f"{identifier} has the wrong HeadersPath")
    architectures = set(library.get("SupportedArchitectures", []))
    if architectures != contract["architectures"]:
        raise SystemExit(
            f"{identifier} architectures differ: "
            f"expected={sorted(contract['architectures'])}, "
            f"actual={sorted(architectures)}"
        )
PY

require_architectures() {
    local archive="$1"
    shift
    local expected
    local architectures
    expected="$(printf '%s\n' "$@" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
    architectures="$(lipo -archs "${archive}" | tr ' ' '\n' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
    if [[ "${architectures}" != "${expected}" ]]; then
        echo "${archive} architectures differ; expected: ${expected}; found: ${architectures}" >&2
        exit 1
    fi
}

require_symbol() {
    local archive="$1"
    local expected="$2"
    # Prefer classic nm for stable Mach-O symbol-table inspection across the
    # supported Xcode versions. Verification must not depend on embedded LLVM
    # IR or a particular llvm-nm reader version.
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
    local maximum_version="$3"
    local platform_name="$4"
    local platforms
    local minimum_versions
    local maximum_major=0
    local maximum_minor=0
    local maximum_patch=0

    IFS=. read -r maximum_major maximum_minor maximum_patch <<< "${maximum_version}"
    maximum_minor="${maximum_minor:-0}"
    maximum_patch="${maximum_patch:-0}"

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
        if (( major > maximum_major \
            || (major == maximum_major && minor > maximum_minor) \
            || (major == maximum_major && minor == maximum_minor && patch > maximum_patch) )); then
            echo "${archive} contains an object requiring ${platform_name} ${version}; maximum is ${maximum_version}" >&2
            exit 1
        fi
    done <<< "${minimum_versions}"
}

require_architectures "${device_archive}" arm64
require_architectures "${simulator_archive}" arm64 x86_64
require_architectures "${macos_archive}" arm64 x86_64
require_build_contract "${device_archive}" 2 15.0 iOS
require_build_contract "${simulator_archive}" 7 15.0 iOS
require_build_contract "${macos_archive}" 1 12.0 macOS

for archive in "${device_archive}" "${simulator_archive}" "${macos_archive}"; do
    require_symbol "${archive}" _nux_file_import_with_result
    require_symbol "${archive}" _nux_player_step
    require_symbol "${archive}" _nux_view_model_instance_snapshot
    require_symbol "${archive}" _nux_renderer_new_metal
    require_symbol "${archive}" _nux_product_file_import_configured
done

echo "Validated ${runtime}: iOS 15 and macOS 12 slices, sole C module, authored-data extension, notices, and final ABI symbols"

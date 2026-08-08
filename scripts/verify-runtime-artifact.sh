#!/usr/bin/env bash

set -euo pipefail

metadata=""
archive=""
xcframework=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --metadata) metadata="${2:-}"; shift 2 ;;
        --archive) archive="${2:-}"; shift 2 ;;
        --xcframework) xcframework="${2:-}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 64 ;;
    esac
done

if [[ -z "${xcframework}" ]]; then
    echo "usage: $0 [--metadata artifact.json --archive runtime.zip] --xcframework runtime.xcframework" >&2
    exit 64
fi
if [[ -n "${metadata}" || -n "${archive}" ]]; then
    if [[ -z "${metadata}" || -z "${archive}" ]]; then
        echo "--metadata and --archive must be supplied together" >&2
        exit 64
    fi
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
device="${xcframework}/ios-arm64/libnux_apple_runtime.a"
simulator="${xcframework}/ios-arm64_x86_64-simulator/libnux_apple_runtime.a"
macos="${xcframework}/macos-arm64_x86_64/libnux_apple_runtime.a"
device_headers="${xcframework}/ios-arm64/Headers"
simulator_headers="${xcframework}/ios-arm64_x86_64-simulator/Headers"
macos_headers="${xcframework}/macos-arm64_x86_64/Headers"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-runtime-consumer-verify.XXXXXX")"
trap 'rm -rf "${temporary}"' EXIT

if [[ -n "${metadata}" ]]; then
    expected_checksum="$(python3 "${script_dir}/json-scalar.py" "${metadata}" checksum string)"
    actual_checksum="$(swift package compute-checksum "${archive}")"
    if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
        echo "Runtime archive checksum differs from ${metadata}" >&2
        echo "expected: ${expected_checksum}" >&2
        echo "actual:   ${actual_checksum}" >&2
        exit 1
    fi
    archived="${temporary}/archived"
    mkdir -p "${archived}"
    ditto -x -k "${archive}" "${archived}"
    if ! diff -rq "${archived}/NuxieRuntime.xcframework" "${xcframework}" >/dev/null; then
        echo "Staged XCFramework differs from the checksummed archive" >&2
        exit 1
    fi
fi

"${script_dir}/validate-runtime-xcframework.sh" "${xcframework}"

expected_headers="$(printf '%s\n' module.modulemap nux_runtime.generated.h nux_runtime.h)"
for headers in "${device_headers}" "${simulator_headers}" "${macos_headers}"; do
    actual_headers="$(cd "${headers}" && find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort)"
    if [[ "${actual_headers}" != "${expected_headers}" ]]; then
        echo "Unexpected public headers in ${headers}" >&2
        diff -u <(printf '%s\n' "${expected_headers}") <(printf '%s\n' "${actual_headers}") >&2 || true
        exit 1
    fi
done
for public_header in module.modulemap nux_runtime.generated.h nux_runtime.h; do
    cmp "${device_headers}/${public_header}" "${simulator_headers}/${public_header}"
    cmp "${device_headers}/${public_header}" "${macos_headers}/${public_header}"
done

nm_tool="$(xcrun --find nm-classic 2>/dev/null || command -v nm)"
libraries=("${device}")
for arch in arm64 x86_64; do
    thin="${temporary}/libnux_apple_runtime-simulator-${arch}.a"
    lipo "${simulator}" -thin "${arch}" -output "${thin}"
    libraries+=("${thin}")
done
for arch in arm64 x86_64; do
    thin="${temporary}/libnux_apple_runtime-macos-${arch}.a"
    lipo "${macos}" -thin "${arch}" -output "${thin}"
    libraries+=("${thin}")
done
for library in "${libraries[@]}"; do
    symbols="${temporary}/$(basename "${library}").symbols"
    "${nm_tool}" -gjU "${library}" > "${symbols}"
    python3 "${script_dir}/apple_runtime_contract.py" \
        symbols "${device_headers}/nux_runtime.generated.h" "${symbols}"
done

xcrun --sdk iphoneos clang -std=c11 -Wall -Wextra -Werror \
    -target arm64-apple-ios15.0 \
    -I"${device_headers}" \
    -fsyntax-only "${repo_root}/Tests/RuntimeContract/header_smoke.c"
xcrun --sdk macosx clang -std=c11 -Wall -Wextra -Werror \
    -target arm64-apple-macos12.0 \
    -I"${macos_headers}" \
    -fsyntax-only "${repo_root}/Tests/RuntimeContract/header_smoke.c"

link_swift_smoke() {
    local sdk="$1"
    local target="$2"
    local headers="$3"
    local library="$4"
    local label="$5"
    local minimum_version="$6"
    local output="${temporary}/libNuxieRuntimeSmoke-${label}.dylib"
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
    xcrun --sdk "${sdk}" swiftc \
        -emit-library -parse-as-library \
        -sdk "${sdk_path}" -target "${target}" \
        -I "${headers}" -L "$(dirname "${library}")" -lnux_apple_runtime \
        -framework Foundation -framework QuartzCore -framework Metal \
        -framework CoreGraphics -framework Security \
        "${repo_root}/Tests/RuntimeContract/swift_import_smoke.swift" \
        -o "${output}"
    [[ "$(lipo -archs "${output}")" == "${target%%-*}" ]]
    [[ "$(otool -l "${output}" | awk '$1 == "minos" { print $2 }' | sort -u)" == "${minimum_version}" ]]
}

link_swift_smoke iphoneos arm64-apple-ios15.0 "${device_headers}" "${device}" device-arm64 15.0
link_swift_smoke iphonesimulator arm64-apple-ios15.0-simulator "${simulator_headers}" "${simulator}" simulator-arm64 15.0
link_swift_smoke iphonesimulator x86_64-apple-ios15.0-simulator "${simulator_headers}" "${simulator}" simulator-x86_64 15.0
link_swift_smoke macosx arm64-apple-macosx12.0 "${macos_headers}" "${macos}" macos-arm64 12.0
link_swift_smoke macosx x86_64-apple-macosx12.0 "${macos_headers}" "${macos}" macos-x86_64 12.0

echo "Runtime consumer verification passed: checksum, iOS 15/macOS 12 slices, headers, and complete ABI"

#!/usr/bin/env bash
set -euo pipefail

phase() {
    printf '  -> %s\n' "$1"
}

require_file() {
    local path="$1"
    if [[ ! -f "${path}" ]]; then
        echo "required Apple runtime artifact is missing: ${path}" >&2
        return 1
    fi
}

if [[ $# -ne 3 ]]; then
    echo "usage: verify-apple-xcframework.sh <xcframework> <zip> <artifact-metadata>" >&2
    exit 2
fi

xcframework_path="$1"
archive_path="$2"
metadata_path="$3"
info_plist="${xcframework_path}/Info.plist"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
native_root="${repo_root}/native"
crate_root="${native_root}/nux-apple-runtime"
runtime_source_root="${repo_root}/third_party/nuxie-runtime"

metadata_scalar() {
    python3 "${script_dir}/json-scalar.py" "${metadata_path}" "$1" "$2"
}

phase "validate metadata and archive checksum"
require_file "${info_plist}"
require_file "${archive_path}"
require_file "${metadata_path}"
plutil -lint "${info_plist}"
if ! python3 -m json.tool "${metadata_path}" >/dev/null; then
    echo "artifact metadata is not valid JSON: ${metadata_path}" >&2
    sed -n '1,200p' "${metadata_path}" >&2
    exit 1
fi
python3 "${script_dir}/apple_runtime_contract.py" metadata "${metadata_path}"

rust_toolchain="$(metadata_scalar rustToolchain string)"
rust_compiler="$(rustup which --toolchain "${rust_toolchain}" rustc)"
rust_host="$("${rust_compiler}" -vV | sed -n 's/^host: //p')"
rust_sysroot="$("${rust_compiler}" --print sysroot)"
rust_llvm_nm="${rust_sysroot}/lib/rustlib/${rust_host}/bin/llvm-nm"
rust_llvm_readobj="${rust_sysroot}/lib/rustlib/${rust_host}/bin/llvm-readobj"
for rust_llvm_tool in "${rust_llvm_nm}" "${rust_llvm_readobj}"; do
    if [[ ! -x "${rust_llvm_tool}" ]]; then
        echo "missing $(basename "${rust_llvm_tool}") for Rust toolchain ${rust_toolchain}" >&2
        echo "install it with: rustup component add --toolchain ${rust_toolchain} llvm-tools" >&2
        exit 1
    fi
done

expected_checksum="$(metadata_scalar swiftPackageChecksum string)"
actual_checksum="$(swift package compute-checksum "${archive_path}")"
if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
    echo "archive checksum does not match artifact metadata" >&2
    echo "expected: ${expected_checksum}" >&2
    echo "actual:   ${actual_checksum}" >&2
    exit 1
fi

phase "extract and compare the archive"
verification_temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-runtime-verify.XXXXXX")"
trap 'rm -rf "${verification_temp_dir}"' EXIT
ditto -x -k "${archive_path}" "${verification_temp_dir}"
archived_framework="$(find "${verification_temp_dir}" -maxdepth 1 -name '*.xcframework' -print -quit)"
test -n "${archived_framework}"
diff -rq "${xcframework_path}" "${archived_framework}" >/dev/null

phase "validate packaged license notices"
third_party_notices_path="$(metadata_scalar thirdPartyNoticesPath string)"
test "${third_party_notices_path}" = "NuxieRuntime.xcframework/THIRD_PARTY_NOTICES.md"
require_file "${xcframework_path}/LICENSE"
require_file "${xcframework_path}/THIRD_PARTY_NOTICES.md"
require_file "${verification_temp_dir}/${third_party_notices_path}"
cmp "${repo_root}/LICENSE" "${xcframework_path}/LICENSE"
cmp "${runtime_source_root}/THIRD_PARTY_NOTICES.md" "${xcframework_path}/THIRD_PARTY_NOTICES.md"
cmp "${runtime_source_root}/THIRD_PARTY_NOTICES.md" "${verification_temp_dir}/${third_party_notices_path}"

device_library="$(find "${xcframework_path}" -path '*ios-arm64/libnux_apple_runtime.a' -print -quit)"
simulator_library="$(find "${xcframework_path}" -path '*ios-arm64_x86_64-simulator/libnux_apple_runtime.a' -print -quit)"

phase "validate architectures and exported runtime contract"
if [[ -z "${device_library}" ]]; then
    echo "device Apple runtime library is missing from ${xcframework_path}" >&2
    exit 1
fi
if [[ -z "${simulator_library}" ]]; then
    echo "simulator Apple runtime library is missing from ${xcframework_path}" >&2
    exit 1
fi
device_archs="$(lipo -archs "${device_library}")"
if [[ "${device_archs}" != "arm64" ]]; then
    echo "unexpected device library architectures: ${device_archs}" >&2
    exit 1
fi
simulator_archs="$(lipo -archs "${simulator_library}")"
if [[ "${simulator_archs}" != *arm64* || "${simulator_archs}" != *x86_64* ]]; then
    echo "simulator library is missing a required architecture: ${simulator_archs}" >&2
    exit 1
fi

# Apple deprecated embedded bitcode, and `__LLVM,__bitcode` members produced
# by a newer LLVM break symbol listing on consumers with an older Apple LLVM.
# No archive member may retain a `__LLVM` segment.
assert_no_llvm_segment() {
    local library="$1"
    local label="$2"
    local sections
    if ! sections="$("${rust_llvm_readobj}" --sections "${library}")"; then
        echo "cannot inspect Mach-O sections in ${label}" >&2
        exit 1
    fi
    if grep -q 'Segment: __LLVM' <<< "${sections}"; then
        echo "${label} contains __LLVM segment sections (embedded bitcode)" >&2
        exit 1
    fi
}

phase "validate no embedded LLVM bitcode is shipped"
assert_no_llvm_segment "${device_library}" "device library"
# llvm-readobj walks every member of a thin archive but only one slice of a
# universal file, so split the simulator library per architecture first.
for simulator_arch in arm64 x86_64; do
    thin_simulator_library="${verification_temp_dir}/libnux_apple_runtime-${simulator_arch}.a"
    lipo "${simulator_library}" -thin "${simulator_arch}" -output "${thin_simulator_library}"
    assert_no_llvm_segment "${thin_simulator_library}" "simulator library (${simulator_arch})"
done
headers_dir="$(dirname "${device_library}")/Headers"
simulator_headers_dir="$(dirname "${simulator_library}")/Headers"
require_file "${headers_dir}/nux_runtime.generated.h"

symbol_libraries=("${device_library}")
for simulator_arch in arm64 x86_64; do
    symbol_libraries+=(
        "${verification_temp_dir}/libnux_apple_runtime-${simulator_arch}.a"
    )
done

for library in "${symbol_libraries[@]}"; do
    phase "validate complete public symbol manifest in ${library##*/}"
    if ! symbols="$("${rust_llvm_nm}" -gjU "${library}")"; then
        echo "cannot inspect exported symbols in ${library}" >&2
        exit 1
    fi
    symbols_path="${verification_temp_dir}/${library##*/}.symbols"
    printf '%s\n' "${symbols}" > "${symbols_path}"
    python3 "${script_dir}/apple_runtime_contract.py" \
        symbols \
        "${headers_dir}/nux_runtime.generated.h" \
        "${symbols_path}"
    if ! grep -Fxq "_rust_eh_personality" <<< "${symbols}"; then
        echo "required panic-unwind symbol _rust_eh_personality is missing from ${library}" >&2
        exit 1
    fi
done

phase "validate toolchain and embedded provenance"
source_revision="$(metadata_scalar sourceRevision string)"
build_profile="$(metadata_scalar buildProfile string)"
minimum_ios_version="$(metadata_scalar minimumIOSVersion string)"
runtime_version="$(metadata_scalar runtimeVersion string)"
runtime_identity="$(metadata_scalar runtimeIdentity string)"
contract_fingerprint="$(metadata_scalar contractFingerprint string)"
luaur_version="$(metadata_scalar luaurVersion string)"
xcode_version="$(metadata_scalar xcodeVersion string)"
xcode_build="$(metadata_scalar xcodeBuild string)"
iphoneos_sdk_version="$(metadata_scalar iphoneOSSDKVersion string)"
iphoneos_sdk_build="$(metadata_scalar iphoneOSSDKBuild string)"
iphonesimulator_sdk_version="$(metadata_scalar iphoneSimulatorSDKVersion string)"
iphonesimulator_sdk_build="$(metadata_scalar iphoneSimulatorSDKBuild string)"
test "$(metadata_scalar schemaVersion integer)" = "2"
if [[ ! "${source_revision}" =~ ^[0-9a-f]{40}(-dirty\.[0-9a-f]{64})?$ ]]; then
    echo "artifact source revision is not an exact clean or diagnostic-dirty identity: ${source_revision}" >&2
    exit 1
fi
expected_runtime_version="$(
    sed -n 's/^version = "\([^"]*\)"/\1/p' \
        "${crate_root}/Cargo.toml" |
        head -1
)"
test -n "${expected_runtime_version}"
test "${runtime_version}" = "${expected_runtime_version}"
test "${runtime_identity}" = "${runtime_version}@${source_revision}"
expected_contract_fingerprint="$(
    shasum -a 256 "${headers_dir}/nux_runtime.generated.h" |
        awk '{ print $1 }'
)"
test -n "${expected_contract_fingerprint}"
test "${contract_fingerprint}" = "${expected_contract_fingerprint}"
if grep -Eq '"(abiMajor|abiMinor|runtimeAbiMajor|runtimeAbiMinor|flowSessionAbiMinor)"[[:space:]]*:' "${metadata_path}"; then
    echo "artifact metadata contains a removed client-facing ABI field" >&2
    exit 1
fi
expected_luaur_version="$(
    awk '
        $0 == "name = \"luaur-vm\"" { found = 1; next }
        found && /^version = / {
            value = $0
            sub(/^version = \"/, "", value)
            sub(/\"$/, "", value)
            print value
            exit
        }
        found && /^\[\[package\]\]/ { exit 1 }
    ' "${native_root}/Cargo.lock"
)"
test -n "${expected_luaur_version}"
test "${luaur_version}" = "${expected_luaur_version}"
test "$(xcodebuild -version | sed -n 's/^Xcode //p')" = "${xcode_version}"
test "$(xcodebuild -version | sed -n 's/^Build version //p')" = "${xcode_build}"
test "$(xcrun --sdk iphoneos --show-sdk-version)" = "${iphoneos_sdk_version}"
test "$(xcrun --sdk iphoneos --show-sdk-build-version)" = "${iphoneos_sdk_build}"
test "$(xcrun --sdk iphonesimulator --show-sdk-version)" = "${iphonesimulator_sdk_version}"
test "$(xcrun --sdk iphonesimulator --show-sdk-build-version)" = "${iphonesimulator_sdk_build}"
for target_and_library in \
    "aarch64-apple-ios:${device_library}" \
    "aarch64-apple-ios-sim:${verification_temp_dir}/libnux_apple_runtime-arm64.a" \
    "x86_64-apple-ios:${verification_temp_dir}/libnux_apple_runtime-x86_64.a"; do
    target="${target_and_library%%:*}"
    library="${target_and_library#*:}"
    provenance="$(strings "${library}" | grep -F "\"target\":\"${target}\"" | head -1)"
    test -n "${provenance}"
    grep -Fq "\"sourceRevision\":\"${source_revision}\"" <<< "${provenance}"
    grep -Fq "\"runtimeVersion\":\"${runtime_version}\"" <<< "${provenance}"
    grep -Fq "\"runtimeIdentity\":\"${runtime_identity}\"" <<< "${provenance}"
    grep -Fq "\"contractFingerprint\":\"${contract_fingerprint}\"" <<< "${provenance}"
    grep -Fq '"schemaVersion":2' <<< "${provenance}"
    grep -Fq "\"profile\":\"${build_profile}\"" <<< "${provenance}"
    grep -Fq "\"rustc\":\"rustc ${rust_toolchain}" <<< "${provenance}"
    grep -Fq '"features":"apple-product"' <<< "${provenance}"
    grep -Fq "\"luaurVersion\":\"${luaur_version}\"" <<< "${provenance}"
    if grep -Eq '"(abiMajor|abiMinor|runtimeAbiMajor|runtimeAbiMinor|flowSessionAbiMinor)"[[:space:]]*:' <<< "${provenance}"; then
        echo "embedded provenance contains a removed client-facing ABI field for ${target}" >&2
        exit 1
    fi
done

expected_public_headers="$(printf '%s\n' \
    module.modulemap \
    nux_runtime.generated.h \
    nux_runtime.h)"

verify_public_header_allowlist() {
    local headers="$1"
    local actual_public_headers
    test -d "${headers}"
    actual_public_headers="$(
        cd "${headers}"
        find . -mindepth 1 -print | sed 's#^\./##' | LC_ALL=C sort
    )"
    if [[ "${actual_public_headers}" != "${expected_public_headers}" ]]; then
        echo "unexpected public header contents in ${headers}" >&2
        diff -u \
            <(printf '%s\n' "${expected_public_headers}") \
            <(printf '%s\n' "${actual_public_headers}") >&2 || true
        return 1
    fi
}

phase "validate the public header boundary"
verify_public_header_allowlist "${headers_dir}"
verify_public_header_allowlist "${simulator_headers_dir}"
for public_header in module.modulemap nux_runtime.generated.h nux_runtime.h; do
    cmp "${headers_dir}/${public_header}" "${simulator_headers_dir}/${public_header}"
done

phase "compile the C header smoke test"
clang -std=c11 -Wall -Wextra -Werror \
    -I"${headers_dir}" \
    -fsyntax-only \
    "${crate_root}/smoke/header_smoke.c"

swift_smoke_dir="${verification_temp_dir}/swift-link"
mkdir -p "${swift_smoke_dir}"

link_swift_smoke() {
    local sdk="$1"
    local target="$2"
    local headers="$3"
    local library="$4"
    local label="$5"
    local output="${swift_smoke_dir}/libNuxieRuntimeSmoke-${label}.dylib"
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
    xcrun --sdk "${sdk}" swiftc \
        -emit-library \
        -parse-as-library \
        -sdk "${sdk_path}" \
        -target "${target}" \
        -I "${headers}" \
        -L "$(dirname "${library}")" \
        -lnux_apple_runtime \
        -framework Foundation \
        -framework QuartzCore \
        -framework Metal \
        -framework CoreGraphics \
        -framework Security \
        "${crate_root}/smoke/swift_import_smoke.swift" \
        -o "${output}"

    local expected_arch="${target%%-*}"
    test "$(lipo -archs "${output}")" = "${expected_arch}"
    local linked_symbols
    linked_symbols="$(nm -gjU "${output}")"
    grep -Fxq '_nux_runtime_bind' <<< "${linked_symbols}"
    ! otool -L "${output}" | grep -Eiq 'rive|nuxie_runtime'
    local linked_minos
    linked_minos="$(otool -l "${output}" | awk '$1 == "minos" { print $2 }' | sort -u)"
    test "${linked_minos}" = "${minimum_ios_version}"
}

phase "link the Swift smoke tests"
link_swift_smoke \
    iphoneos "arm64-apple-ios${minimum_ios_version}" \
    "${headers_dir}" "${device_library}" device-arm64
link_swift_smoke \
    iphonesimulator "arm64-apple-ios${minimum_ios_version}-simulator" \
    "${simulator_headers_dir}" "${simulator_library}" simulator-arm64
link_swift_smoke \
    iphonesimulator "x86_64-apple-ios${minimum_ios_version}-simulator" \
    "${simulator_headers_dir}" "${simulator_library}" simulator-x86_64

echo "apple-xcframework verification passed"

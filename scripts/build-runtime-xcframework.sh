#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repo_root="$(cd -P "${script_dir}/.." && pwd -P)"
native_root="${repo_root}/native"
crate_root="${native_root}/nux-apple-runtime"
runtime_source_root="${repo_root}/third_party/nuxie-runtime"
requested_output_root="${1:-${native_root}/target/apple-runtime}"

if [[ -z "${requested_output_root}" ]]; then
    echo "refusing unsafe output path: empty path" >&2
    exit 2
fi
mkdir -p "${requested_output_root}"
output_root="$(cd -P "${requested_output_root}" && pwd -P)"
case "${output_root}" in
    /|"${repo_root}"|"${native_root}"|"")
        echo "refusing unsafe output path: ${output_root}" >&2
        exit 2
        ;;
esac

if [[ ! -f "${runtime_source_root}/Cargo.toml" ]]; then
    echo "pinned runtime engine source is missing; run git submodule update --init" >&2
    exit 3
fi

profile="${NUX_APPLE_PROFILE:-release-apple}"
deployment_target="${NUX_APPLE_DEPLOYMENT_TARGET:-15.0}"
rust_toolchain="${NUX_APPLE_RUST_TOOLCHAIN:-1.94.1}"
rust_cargo="$(rustup which --toolchain "${rust_toolchain}" cargo)"
rust_compiler="$(rustup which --toolchain "${rust_toolchain}" rustc)"
rust_host="$("${rust_compiler}" -vV | sed -n 's/^host: //p')"
rust_sysroot="$("${rust_compiler}" --print sysroot)"
rust_llvm_nm="${rust_sysroot}/lib/rustlib/${rust_host}/bin/llvm-nm"
rust_llvm_objcopy="${rust_sysroot}/lib/rustlib/${rust_host}/bin/llvm-objcopy"
rust_llvm_readobj="${rust_sysroot}/lib/rustlib/${rust_host}/bin/llvm-readobj"
runtime_version="$(
    sed -n 's/^version = "\([^"]*\)"/\1/p' "${crate_root}/Cargo.toml" |
        head -1
)"
xcode_version="$(xcodebuild -version | sed -n 's/^Xcode //p')"
xcode_build="$(xcodebuild -version | sed -n 's/^Build version //p')"
iphoneos_sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
iphoneos_sdk_build="$(xcrun --sdk iphoneos --show-sdk-build-version)"
iphonesimulator_sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
iphonesimulator_sdk_build="$(xcrun --sdk iphonesimulator --show-sdk-build-version)"
luaur_version="$(
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

if [[ -z "${runtime_version}" || -z "${luaur_version}" ]]; then
    echo "cannot determine pinned runtime versions from the native workspace" >&2
    exit 4
fi
if [[ -n "${NUX_APPLE_XCODE_VERSION:-}" && "${xcode_version}" != "${NUX_APPLE_XCODE_VERSION}" ]]; then
    echo "Xcode version ${xcode_version} does not match required ${NUX_APPLE_XCODE_VERSION}" >&2
    exit 4
fi
if [[ -n "${NUX_APPLE_XCODE_BUILD:-}" && "${xcode_build}" != "${NUX_APPLE_XCODE_BUILD}" ]]; then
    echo "Xcode build ${xcode_build} does not match required ${NUX_APPLE_XCODE_BUILD}" >&2
    exit 4
fi

for rust_llvm_tool in "${rust_llvm_nm}" "${rust_llvm_objcopy}" "${rust_llvm_readobj}"; do
    if [[ ! -x "${rust_llvm_tool}" ]]; then
        echo "missing $(basename "${rust_llvm_tool}") for Rust toolchain ${rust_toolchain}" >&2
        echo "install it with: rustup component add --toolchain ${rust_toolchain} llvm-tools" >&2
        exit 4
    fi
done

build_root="${output_root}/build"
cargo_target_dir="${build_root}/cargo"
headers_dir="${build_root}/Headers"
simulator_dir="${build_root}/simulator"
stripped_root="${build_root}/stripped"
verification_root="${build_root}/verification"
xcframework_path="${output_root}/NuxieRuntime.xcframework"
archive_path="${output_root}/NuxieRuntime.xcframework.zip"
metadata_path="${output_root}/artifact.json"

phase() {
    printf '\n==> %s\n' "$1"
}

report_disk() {
    local available_kib
    available_kib="$(df -Pk "${output_root}" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
    printf 'disk: available=%s KiB\n' "${available_kib:-unknown}"
}

# Match the adopted crate's unchanged build.rs identity algorithm. Untracked
# native files are intentionally absent from this diagnostic identity until
# the adoption is committed; clean release tags bind every owned source byte.
git_revision="$(git -C "${repo_root}" rev-parse --verify HEAD)"
runtime_revision="${git_revision}"
if ! git -C "${repo_root}" diff --quiet --no-ext-diff HEAD -- ||
    [[ -n "$(
        git -C "${repo_root}" ls-files \
            --others \
            --exclude-standard \
            -- \
            crates \
            vendor
    )" ]]; then
    dirty_fingerprint="$(
        {
            printf '%s\0' "${git_revision}"
            git -C "${repo_root}" diff --binary --no-ext-diff HEAD --
            git -C "${repo_root}" ls-files \
                --others \
                --exclude-standard \
                -z \
                -- \
                crates \
                vendor |
                while IFS= read -r -d '' untracked_path; do
                    printf '%s\0' "${untracked_path}"
                    cat "${repo_root}/${untracked_path}"
                    printf '\0'
                done
        } | shasum -a 256 | awk '{ print $1 }'
    )"
    runtime_revision="${git_revision}-dirty.${dirty_fingerprint}"
fi
if [[ -n "${NUX_RUNTIME_SOURCE_REVISION:-}" &&
    "${NUX_RUNTIME_SOURCE_REVISION}" != "${runtime_revision}" ]]; then
    echo "requested runtime source revision does not match the SDK worktree" >&2
    echo "requested: ${NUX_RUNTIME_SOURCE_REVISION}" >&2
    echo "worktree:  ${runtime_revision}" >&2
    exit 4
fi
runtime_identity="${runtime_version}@${runtime_revision}"

rm -rf \
    "${headers_dir}" \
    "${simulator_dir}" \
    "${stripped_root}" \
    "${verification_root}" \
    "${xcframework_path}" \
    "${archive_path}" \
    "${metadata_path}"
mkdir -p \
    "${build_root}" \
    "${headers_dir}" \
    "${simulator_dir}" \
    "${stripped_root}" \
    "${verification_root}"

targets=(
    aarch64-apple-ios
    aarch64-apple-ios-sim
    x86_64-apple-ios
)

phase "Build the SDK-owned Apple runtime"
report_disk
for target in "${targets[@]}"; do
    if ! rustup target list --toolchain "${rust_toolchain}" --installed | grep -qx "${target}"; then
        echo "missing Rust target ${target} for toolchain ${rust_toolchain}" >&2
        echo "install it with: rustup target add --toolchain ${rust_toolchain} ${target}" >&2
        exit 5
    fi
    phase "Build ${target}"
    IPHONEOS_DEPLOYMENT_TARGET="${deployment_target}" \
    NUX_RUNTIME_BUILD_PROFILE="${profile}" \
    NUX_RUNTIME_SOURCE_REVISION="${runtime_revision}" \
    CARGO_TARGET_DIR="${cargo_target_dir}" \
    RUSTC="${rust_compiler}" \
        "${rust_cargo}" build \
            --manifest-path "${native_root}/Cargo.toml" \
            --locked \
            --package nux-apple-runtime \
            --no-default-features \
            --features apple-product \
            --profile "${profile}" \
            --target "${target}"
    report_disk
done

phase "Strip embedded LLVM bitcode"
for target in "${targets[@]}"; do
    mkdir -p "${stripped_root}/${target}"
    cp "${cargo_target_dir}/${target}/${profile}/libnux_apple_runtime.a" \
        "${stripped_root}/${target}/libnux_apple_runtime.a"
    "${rust_llvm_objcopy}" \
        --remove-section=__LLVM,__bitcode \
        --remove-section=__LLVM,__cmdline \
        "${stripped_root}/${target}/libnux_apple_runtime.a"
done

device_library="${stripped_root}/aarch64-apple-ios/libnux_apple_runtime.a"
arm_simulator_library="${stripped_root}/aarch64-apple-ios-sim/libnux_apple_runtime.a"
intel_simulator_library="${stripped_root}/x86_64-apple-ios/libnux_apple_runtime.a"
simulator_library="${simulator_dir}/libnux_apple_runtime.a"

phase "Assemble device and universal simulator libraries"
lipo -create \
    "${arm_simulator_library}" \
    "${intel_simulator_library}" \
    -output "${simulator_library}"

cp "${crate_root}/include/nux_runtime.h" "${headers_dir}/"
cp "${crate_root}/include/nux_runtime.generated.h" "${headers_dir}/"
cp "${crate_root}/include/module.modulemap" "${headers_dir}/"

phase "Create NuxieRuntime.xcframework"
xcodebuild -create-xcframework \
    -library "${device_library}" \
    -headers "${headers_dir}" \
    -library "${simulator_library}" \
    -headers "${headers_dir}" \
    -output "${xcframework_path}"
cp "${repo_root}/LICENSE" "${xcframework_path}/LICENSE"
cp "${runtime_source_root}/THIRD_PARTY_NOTICES.md" \
    "${xcframework_path}/THIRD_PARTY_NOTICES.md"

phase "Validate the public C header"
clang -std=c11 -Wall -Wextra -Werror \
    -I"${headers_dir}" \
    -fsyntax-only \
    "${crate_root}/smoke/header_smoke.c"

assert_no_llvm_segment() {
    local library="$1"
    local label="$2"
    local sections
    if ! sections="$("${rust_llvm_readobj}" --sections "${library}")"; then
        echo "cannot inspect Mach-O sections in ${label}" >&2
        exit 1
    fi
    if grep -q 'Segment: __LLVM' <<< "${sections}"; then
        echo "${label} contains embedded LLVM bitcode" >&2
        exit 1
    fi
}

phase "Validate slices, bitcode removal, and the experience/session ABI"
test "$(lipo -archs "${device_library}")" = "arm64"
simulator_archs="$(lipo -archs "${simulator_library}")"
grep -qw arm64 <<< "${simulator_archs}"
grep -qw x86_64 <<< "${simulator_archs}"
assert_no_llvm_segment "${device_library}" "device library"

symbol_libraries=("${device_library}")
for simulator_arch in arm64 x86_64; do
    thin_library="${verification_root}/libnux_apple_runtime-${simulator_arch}.a"
    lipo "${simulator_library}" -thin "${simulator_arch}" -output "${thin_library}"
    assert_no_llvm_segment "${thin_library}" "simulator library (${simulator_arch})"
    symbol_libraries+=("${thin_library}")
done

for library in "${symbol_libraries[@]}"; do
    symbols="$("${rust_llvm_nm}" -gjU "${library}")"
    for expected_symbol in \
        _nux_runtime_bind \
        _nux_experience_context_create \
        _nux_screen_session_create; do
        if ! grep -Fxq "${expected_symbol}" <<< "${symbols}"; then
            echo "${library} is missing ${expected_symbol}" >&2
            exit 1
        fi
    done
    if ! grep -Fxq "_rust_eh_personality" <<< "${symbols}"; then
        echo "${library} is missing the panic-unwind personality" >&2
        exit 1
    fi
done

swift_smoke_root="${verification_root}/swift-link"
mkdir -p "${swift_smoke_root}"
link_swift_smoke() {
    local sdk="$1"
    local target="$2"
    local library="$3"
    local label="$4"
    local output="${swift_smoke_root}/libNuxieRuntimeSmoke-${label}.dylib"
    local sdk_path
    sdk_path="$(xcrun --sdk "${sdk}" --show-sdk-path)"
    xcrun --sdk "${sdk}" swiftc \
        -emit-library \
        -parse-as-library \
        -sdk "${sdk_path}" \
        -target "${target}" \
        -I "${headers_dir}" \
        -L "$(dirname "${library}")" \
        -lnux_apple_runtime \
        -framework Foundation \
        -framework QuartzCore \
        -framework Metal \
        -framework CoreGraphics \
        -framework Security \
        "${crate_root}/smoke/swift_import_smoke.swift" \
        -o "${output}"
    test "$(lipo -archs "${output}")" = "${target%%-*}"
    # Capture before grepping: `nm | grep -q` under pipefail dies with SIGPIPE
    # (exit 141) whenever grep exits at the first match before nm finishes.
    local smoke_symbols
    smoke_symbols="$(nm -gjU "${output}")"
    grep -Fxq _nux_runtime_bind <<< "${smoke_symbols}"
    ! otool -L "${output}" | grep -Eiq 'rive|nuxie_runtime'
    linked_minos="$(otool -l "${output}" | awk '$1 == "minos" { print $2 }' | sort -u)"
    test "${linked_minos}" = "${deployment_target}"
}

phase "Link the Swift import smoke tests"
link_swift_smoke \
    iphoneos "arm64-apple-ios${deployment_target}" \
    "${device_library}" device-arm64
link_swift_smoke \
    iphonesimulator "arm64-apple-ios${deployment_target}-simulator" \
    "${simulator_library}" simulator-arm64
link_swift_smoke \
    iphonesimulator "x86_64-apple-ios${deployment_target}-simulator" \
    "${simulator_library}" simulator-x86_64

phase "Archive and compare the release payload"
ditto -c -k --sequesterRsrc --keepParent "${xcframework_path}" "${archive_path}"
archive_extract_root="${verification_root}/archive"
mkdir -p "${archive_extract_root}"
ditto -x -k "${archive_path}" "${archive_extract_root}"
diff -rq \
    "${xcframework_path}" \
    "${archive_extract_root}/NuxieRuntime.xcframework" >/dev/null
checksum="$(swift package compute-checksum "${archive_path}")"

phase "Write and verify artifact provenance"
contract_fingerprint="$(
    shasum -a 256 "${headers_dir}/nux_runtime.generated.h" |
        awk '{ print $1 }'
)"
printf '{\n  "schemaVersion": 2,\n  "runtimeVersion": "%s",\n  "sourceRevision": "%s",\n  "runtimeIdentity": "%s",\n  "contractFingerprint": "%s",\n  "luaurVersion": "%s",\n  "buildProfile": "%s",\n  "rustToolchain": "%s",\n  "xcodeVersion": "%s",\n  "xcodeBuild": "%s",\n  "iphoneOSSDKVersion": "%s",\n  "iphoneOSSDKBuild": "%s",\n  "iphoneSimulatorSDKVersion": "%s",\n  "iphoneSimulatorSDKBuild": "%s",\n  "minimumIOSVersion": "%s",\n  "thirdPartyNoticesPath": "NuxieRuntime.xcframework/THIRD_PARTY_NOTICES.md",\n  "swiftPackageChecksum": "%s"\n}\n' \
    "${runtime_version}" \
    "${runtime_revision}" \
    "${runtime_identity}" \
    "${contract_fingerprint}" \
    "${luaur_version}" \
    "${profile}" \
    "${rust_toolchain}" \
    "${xcode_version}" \
    "${xcode_build}" \
    "${iphoneos_sdk_version}" \
    "${iphoneos_sdk_build}" \
    "${iphonesimulator_sdk_version}" \
    "${iphonesimulator_sdk_build}" \
    "${deployment_target}" \
    "${checksum}" > "${metadata_path}"
"${script_dir}/verify-built-runtime-xcframework.sh" \
    "${xcframework_path}" \
    "${archive_path}" \
    "${metadata_path}"

phase "Stage the XCFramework for local SDK builds"
make -C "${repo_root}" --no-print-directory stage-runtime-xcframework \
    NUXIE_RUNTIME_XCFRAMEWORK="${xcframework_path}"
make -C "${repo_root}" --no-print-directory check-staged-runtime-xcframework

echo "XCFramework: ${xcframework_path}"
echo "Staged: ${repo_root}/.artifacts/NuxieRuntime.xcframework"
echo "Archive: ${archive_path}"
echo "Checksum: ${checksum}"

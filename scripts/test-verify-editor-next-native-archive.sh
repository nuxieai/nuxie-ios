#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 /path/to/Nuxie.framework /path/to/NuxieRuntime.xcframework" >&2
    exit 64
fi

framework_path="$1"
runtime_template_path="$2"
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT

runtime_path="${temporary}/NuxieRuntime.xcframework"
device_identifier="ios-arm64"
simulator_identifier="ios-arm64_x86_64-simulator"
mkdir -p \
    "${runtime_path}/${device_identifier}/Headers" \
    "${runtime_path}/${simulator_identifier}/Headers"

for relative in Info.plist LICENSE THIRD_PARTY_NOTICES.md; do
    cp "${runtime_template_path}/${relative}" "${runtime_path}/${relative}"
done
for identifier in "${device_identifier}" "${simulator_identifier}"; do
    for relative in \
        nux_runtime.h \
        nux_runtime.generated.h \
        module.modulemap; do
        cp \
            "${runtime_template_path}/${identifier}/Headers/${relative}" \
            "${runtime_path}/${identifier}/Headers/${relative}"
    done
done

compile_runtime_object() {
    local sdk="$1"
    local target="$2"
    local output="$3"
    printf '%s\n' \
        'static const char runtime_version[] = "0.2.0";' \
        'static const char source_revision[] = "b1f58004332a73564ffdd9f8585838209604c4d1";' \
        'static const char build_provenance[] = "{\"schemaVersion\":2,\"runtimeVersion\":\"0.2.0\",\"sourceRevision\":\"b1f58004332a73564ffdd9f8585838209604c4d1\",\"runtimeIdentity\":\"0.2.0@b1f58004332a73564ffdd9f8585838209604c4d1\"}";' \
        'void *nux_runtime_bind(void) { return (void *)runtime_version; }' \
        'void *nux_runtime_build_provenance(void) { return (void *)build_provenance; }' \
        'void *nux_flow_runtime_context_create_bound(void) { return (void *)0; }' \
        | xcrun --sdk "${sdk}" clang \
            -target "${target}" \
            -x c \
            -c - \
            -o "${output}"
}

compile_stale_runtime_object() {
    local sdk="$1"
    local target="$2"
    local output="$3"
    printf '%s\n' \
        'static const char runtime_version[] = "9.9.9";' \
        'static const char source_revision[] = "0000000000000000000000000000000000000000";' \
        'static const char build_provenance[] = "{\"schemaVersion\":2,\"runtimeVersion\":\"9.9.9\",\"sourceRevision\":\"0000000000000000000000000000000000000000\",\"runtimeIdentity\":\"9.9.9@0000000000000000000000000000000000000000\"}";' \
        'void *nux_runtime_bind(void) { return (void *)runtime_version; }' \
        'void *nux_runtime_build_provenance(void) { return (void *)build_provenance; }' \
        'void *nux_flow_runtime_context_create_bound(void) { return (void *)0; }' \
        | xcrun --sdk "${sdk}" clang \
            -target "${target}" \
            -x c \
            -c - \
            -o "${output}"
}

compile_identity_decoy_object() {
    local sdk="$1"
    local target="$2"
    local output="$3"
    printf '%s\n' \
        'static const char build_provenance[] = "{\"schemaVersion\":2,\"runtimeVersion\":\"0.2.0\",\"sourceRevision\":\"b1f58004332a73564ffdd9f8585838209604c4d1\",\"runtimeIdentity\":\"0.2.0@b1f58004332a73564ffdd9f8585838209604c4d1\"}";' \
        'const void *runtime_identity_decoy(unsigned index) {' \
        '    return index == 0 ? (const void *)build_provenance : (const void *)0;' \
        '}' \
        | xcrun --sdk "${sdk}" clang \
            -target "${target}" \
            -x c \
            -c - \
            -o "${output}"
}

compile_prefixed_provenance_object() {
    local sdk="$1"
    local target="$2"
    local output="$3"
    printf '%s\n' \
        'static const char build_provenance[] = "{\"schemaVersion\":2,\"runtimeVersion\":\"0.2.0-rc.1\",\"sourceRevision\":\"b1f58004332a73564ffdd9f8585838209604c4d1\",\"runtimeIdentity\":\"0.2.0-rc.1@b1f58004332a73564ffdd9f8585838209604c4d1\"}";' \
        'const void *prefixed_runtime_provenance(void) { return (const void *)build_provenance; }' \
        | xcrun --sdk "${sdk}" clang \
            -target "${target}" \
            -x c \
            -c - \
            -o "${output}"
}

compile_undefined_runtime_decoy_object() {
    local sdk="$1"
    local target="$2"
    local output="$3"
    printf '%s\n' \
        'static const char build_provenance[] = "{\"schemaVersion\":2,\"runtimeVersion\":\"0.2.0\",\"sourceRevision\":\"b1f58004332a73564ffdd9f8585838209604c4d1\",\"runtimeIdentity\":\"0.2.0@b1f58004332a73564ffdd9f8585838209604c4d1\"}";' \
        'extern void nux_runtime_bind(void);' \
        'extern void nux_runtime_build_provenance(void);' \
        'extern void nux_flow_runtime_context_create_bound(void);' \
        'const void *undefined_runtime_decoy(unsigned index) {' \
        '    const void *symbols[] = {' \
        '        (const void *)&nux_runtime_bind,' \
        '        (const void *)&nux_runtime_build_provenance,' \
        '        (const void *)&nux_flow_runtime_context_create_bound,' \
        '    };' \
        '    return index < 3 ? symbols[index] : (const void *)build_provenance;' \
        '}' \
        | xcrun --sdk "${sdk}" clang \
            -target "${target}" \
            -x c \
            -c - \
            -o "${output}"
}

compile_allowed_unwind_object() {
    local sdk="$1"
    local target="$2"
    local output="$3"
    printf '%s\n' \
        'extern void _Unwind_Backtrace(void);' \
        'void rust_std_unwind_probe(void) { _Unwind_Backtrace(); }' \
        | xcrun --sdk "${sdk}" clang \
            -target "${target}" \
            -x c \
            -c - \
            -o "${output}"
}

device_object="${temporary}/runtime-device.o"
simulator_arm64_object="${temporary}/runtime-simulator-arm64.o"
simulator_x86_64_object="${temporary}/runtime-simulator-x86_64.o"
stale_simulator_arm64_object="${temporary}/stale-runtime-simulator-arm64.o"
stale_simulator_x86_64_object="${temporary}/stale-runtime-simulator-x86_64.o"
identity_decoy_x86_64_object="${temporary}/runtime-identity-decoy-x86_64.o"
prefixed_provenance_object="${temporary}/prefixed-runtime-provenance-arm64.o"
undefined_runtime_decoy_object="${temporary}/undefined-runtime-decoy-arm64.o"
allowed_unwind_object="${temporary}/std-test.std.test-cgu.0.rcgu.o"
compile_runtime_object iphoneos arm64-apple-ios15.0 "${device_object}"
compile_runtime_object \
    iphonesimulator \
    arm64-apple-ios15.0-simulator \
    "${simulator_arm64_object}"
compile_runtime_object \
    iphonesimulator \
    x86_64-apple-ios15.0-simulator \
    "${simulator_x86_64_object}"
compile_stale_runtime_object \
    iphonesimulator \
    arm64-apple-ios15.0-simulator \
    "${stale_simulator_arm64_object}"
compile_stale_runtime_object \
    iphonesimulator \
    x86_64-apple-ios15.0-simulator \
    "${stale_simulator_x86_64_object}"
compile_identity_decoy_object \
    iphonesimulator \
    x86_64-apple-ios15.0-simulator \
    "${identity_decoy_x86_64_object}"
compile_prefixed_provenance_object \
    iphonesimulator \
    arm64-apple-ios15.0-simulator \
    "${prefixed_provenance_object}"
compile_undefined_runtime_decoy_object \
    iphonesimulator \
    arm64-apple-ios15.0-simulator \
    "${undefined_runtime_decoy_object}"
compile_allowed_unwind_object \
    iphonesimulator \
    x86_64-apple-ios15.0-simulator \
    "${allowed_unwind_object}"

failure_log="${temporary}/prefixed-runtime-provenance.log"
if "${repository_root}/scripts/validate-runtime-provenance-record.py" \
    "${prefixed_provenance_object}" \
    >"${failure_log}" 2>&1; then
    echo "runtime provenance validator accepted a suffixed runtime version" >&2
    exit 1
fi
if ! grep -Fq \
    "runtimeVersion='0.2.0-rc.1' (expected '0.2.0')" \
    "${failure_log}"; then
    echo "runtime provenance suffix failure omitted the exact mismatch" >&2
    sed 's/^/  /' "${failure_log}" >&2
    exit 1
fi

undefined_runtime_decoy_archive="${temporary}/undefined-runtime-decoy-arm64.a"
xcrun ar rcs \
    "${undefined_runtime_decoy_archive}" \
    "${undefined_runtime_decoy_object}"
failure_log="${temporary}/undefined-runtime-symbols.log"
if "${repository_root}/scripts/validate-runtime-archive-identity.sh" \
    "${undefined_runtime_decoy_archive}" \
    >"${failure_log}" 2>&1; then
    echo "runtime archive validator accepted undefined identity symbols" >&2
    exit 1
fi
if ! grep -Fq \
    "is missing exported symbol _nux_runtime_bind" \
    "${failure_log}"; then
    echo "runtime archive undefined-symbol failure omitted the first missing definition" >&2
    sed 's/^/  /' "${failure_log}" >&2
    exit 1
fi

device_archive="${runtime_path}/${device_identifier}/libnux_apple_runtime.a"
simulator_arm64_archive="${temporary}/runtime-simulator-arm64.a"
simulator_x86_64_archive="${temporary}/runtime-simulator-x86_64.a"
simulator_archive="${runtime_path}/${simulator_identifier}/libnux_apple_runtime.a"
xcrun ar rcs "${device_archive}" "${device_object}"
xcrun ar rcs "${simulator_arm64_archive}" "${simulator_arm64_object}"
xcrun ar rcs \
    "${simulator_x86_64_archive}" \
    "${simulator_x86_64_object}" \
    "${allowed_unwind_object}"
xcrun lipo \
    -create \
    "${simulator_x86_64_archive}" \
    "${simulator_arm64_archive}" \
    -output "${simulator_archive}"

"${repository_root}/scripts/verify-editor-next-native-archive.sh" \
    "${framework_path}" \
    "${runtime_path}" \
    >/dev/null

device_header="${runtime_path}/${device_identifier}/Headers/nux_runtime.generated.h"
for removed in \
    "required_abi_major" \
    "minimum_abi_minor" \
    "NUX_STATUS_ABI_MISMATCH"; do
    cp \
        "${runtime_template_path}/${device_identifier}/Headers/nux_runtime.generated.h" \
        "${device_header}"
    printf '\n/* stale compatibility token: %s */\n' "${removed}" \
        >>"${device_header}"
    failure_log="${temporary}/stale-header-${removed}.log"
    if "${repository_root}/scripts/validate-runtime-xcframework.sh" \
        "${runtime_path}" \
        >"${failure_log}" 2>&1; then
        echo "runtime validator accepted removed header token ${removed}" >&2
        exit 1
    fi
    if ! grep -Fq "${removed}" "${failure_log}"; then
        echo "runtime validator failure omitted removed token ${removed}" >&2
        sed 's/^/  /' "${failure_log}" >&2
        exit 1
    fi
done
cp \
    "${runtime_template_path}/${device_identifier}/Headers/nux_runtime.generated.h" \
    "${device_header}"

stale_simulator_x86_64_archive="${temporary}/stale-runtime-simulator-x86_64.a"
xcrun ar rcs \
    "${stale_simulator_x86_64_archive}" \
    "${stale_simulator_x86_64_object}" \
    "${identity_decoy_x86_64_object}"
stale_slice_metadata="$(xcrun strings "${stale_simulator_x86_64_archive}")"
for expected in \
    '"runtimeVersion":"0.2.0"' \
    '"sourceRevision":"b1f58004332a73564ffdd9f8585838209604c4d1"'; do
    if ! grep -Fq "${expected}" <<< "${stale_slice_metadata}"; then
        echo "stale-slice fixture is missing decoy identity metadata ${expected}" >&2
        exit 1
    fi
done
xcrun lipo \
    -create \
    "${stale_simulator_x86_64_archive}" \
    "${simulator_arm64_archive}" \
    -output "${temporary}/stale-simulator.a"
mv "${temporary}/stale-simulator.a" "${simulator_archive}"

failure_log="${temporary}/stale-simulator-identity.log"
if "${repository_root}/scripts/validate-runtime-xcframework.sh" \
    "${runtime_path}" \
    >"${failure_log}" 2>&1; then
    echo "runtime validator accepted stale identity in the x86_64 simulator slice" >&2
    exit 1
fi
for expected in \
    "architecture x86_64" \
    "identity member" \
    "invalid runtime provenance"; do
    if ! grep -Fq "${expected}" "${failure_log}"; then
        echo "runtime validator stale-slice failure omitted: ${expected}" >&2
        sed 's/^/  /' "${failure_log}" >&2
        exit 1
    fi
done

xcrun lipo \
    -create \
    "${simulator_x86_64_archive}" \
    "${simulator_arm64_archive}" \
    -output "${temporary}/restored-simulator.a"
mv "${temporary}/restored-simulator.a" "${simulator_archive}"

spoof_products="${temporary}/spoof-products"
mkdir -p "${spoof_products}"
ditto "${framework_path}" "${spoof_products}/Nuxie.framework"

spoof_info="${spoof_products}/Nuxie.framework/Info.plist"
spoof_executable="$(
    plutil -extract CFBundleExecutable raw "${spoof_info}"
)"
printf '%s\n' \
    'static const char runtime_version[] = "0.2.0";' \
    'static const char source_revision[] = "b1f58004332a73564ffdd9f8585838209604c4d1";' \
    'void *nux_runtime_bind(void) { return (void *)runtime_version; }' \
    'void *nux_runtime_build_provenance(void) { return (void *)source_revision; }' \
    'void *nux_flow_runtime_context_create_bound(void) { return (void *)0; }' \
    | xcrun --sdk iphonesimulator clang \
        -target arm64-apple-ios15.0-simulator \
        -x c \
        -dynamiclib \
        - \
        -o "${spoof_products}/Nuxie.framework/${spoof_executable}"
spoof_metadata="$(
    xcrun strings "${spoof_products}/Nuxie.framework/${spoof_executable}"
)"
for expected in \
    "0.2.0" \
    "b1f58004332a73564ffdd9f8585838209604c4d1"; do
    if ! grep -Fq "${expected}" <<< "${spoof_metadata}"; then
        echo "customer-framework spoof fixture is missing payload string ${expected}" >&2
        exit 1
    fi
done

failure_log="${temporary}/stale-customer-runtime.log"
if "${repository_root}/scripts/verify-customer-framework.sh" \
    "${spoof_products}/Nuxie.framework" \
    >"${failure_log}" 2>&1; then
    echo "customer verifier accepted Swift strings in place of native runtime identity" >&2
    exit 1
fi
if ! grep -Fq \
    "has 0 runtime provenance records; expected exactly one" \
    "${failure_log}"; then
    echo "customer verifier stale-runtime failure omitted native identity" >&2
    sed 's/^/  /' "${failure_log}" >&2
    exit 1
fi

rive_object="${temporary}/rive-leak.cpp.o"
printf '%s\n' \
    'namespace rive { int leaked() { return 1; } }' \
    'int *allocate() { return new int(1); }' \
    'void thrower() { throw 7; }' \
    | xcrun --sdk iphonesimulator clang++ \
        -target x86_64-apple-ios15.0-simulator \
        -x c++ \
        -c - \
        -o "${rive_object}"

unexpected_unwind_object="${temporary}/runtime-unwind.o"
printf '%s\n' \
    'extern void _Unwind_Resume(void *);' \
    'void runtime_unwind_probe(void) { _Unwind_Resume((void *)0); }' \
    | xcrun --sdk iphonesimulator clang \
        -target x86_64-apple-ios15.0-simulator \
        -x c \
        -c - \
        -o "${unexpected_unwind_object}"

xcrun ar r \
    "${simulator_x86_64_archive}" \
    "${rive_object}" \
    "${unexpected_unwind_object}"
xcrun ranlib "${simulator_x86_64_archive}"
xcrun lipo \
    -create \
    "${simulator_x86_64_archive}" \
    "${simulator_arm64_archive}" \
    -output "${simulator_archive}"

failure_log="${temporary}/failure.log"
if "${repository_root}/scripts/verify-editor-next-native-archive.sh" \
    "${framework_path}" \
    "${runtime_path}" \
    >"${failure_log}" 2>&1; then
    echo "archive verifier missed forbidden symbols in the x86_64 simulator slice" >&2
    exit 1
fi

for expected in \
    'architecture x86_64' \
    'rive-leak.cpp.o' \
    'contains Rive C++ symbols' \
    'contains C++ ABI symbols' \
    'contains unwind imports outside Rust std/panic_unwind' \
    'contains C++ object members'; do
    if ! grep -Fq "${expected}" "${failure_log}"; then
        echo "archive verifier failure omitted: ${expected}" >&2
        sed 's/^/  /' "${failure_log}" >&2
        exit 1
    fi
done

echo "Editor Next archive verifier audits every architecture and fails closed"

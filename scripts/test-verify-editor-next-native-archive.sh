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
        'unsigned nux_runtime_abi_major(void) { return 1; }' \
        'void *nux_flow_runtime_context_create(void) { return (void *)0; }' \
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
compile_allowed_unwind_object \
    iphonesimulator \
    x86_64-apple-ios15.0-simulator \
    "${allowed_unwind_object}"

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

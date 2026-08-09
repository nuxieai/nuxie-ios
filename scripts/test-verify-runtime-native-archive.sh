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
macos_identifier="macos-arm64_x86_64"
mkdir -p \
    "${runtime_path}/${device_identifier}/Headers" \
    "${runtime_path}/${simulator_identifier}/Headers" \
    "${runtime_path}/${macos_identifier}/Headers"

for relative in Info.plist LICENSE THIRD_PARTY_NOTICES.md BUILD_INPUTS.json; do
    cp "${runtime_template_path}/${relative}" "${runtime_path}/${relative}"
done
for identifier in \
    "${device_identifier}" \
    "${simulator_identifier}" \
    "${macos_identifier}"; do
    for relative in \
        nux_capi_apple.h \
        nux_capi.h \
        nux_capi.generated.h \
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
        'void *nux_file_import_with_result(void) { return (void *)0; }' \
        'void *nux_player_step(void) { return (void *)0; }' \
        'void *nux_view_model_instance_snapshot(void) { return (void *)0; }' \
        'void *nux_renderer_new_metal(void) { return (void *)0; }' \
        | xcrun --sdk "${sdk}" clang \
            -target "${target}" \
            -x c \
            -c - \
            -o "${output}"
}

compile_runtime_unwind_object() {
    local sdk="$1"
    local target="$2"
    local output="$3"
    printf '%s\n' \
        'extern void _Unwind_Backtrace(void);' \
        'void rust_runtime_unwind_probe(void) { _Unwind_Backtrace(); }' \
        | xcrun --sdk "${sdk}" clang \
            -target "${target}" \
            -x c \
            -c - \
            -o "${output}"
}

device_object="${temporary}/runtime-device.o"
simulator_arm64_object="${temporary}/runtime-simulator-arm64.o"
simulator_x86_64_object="${temporary}/runtime-simulator-x86_64.o"
macos_arm64_object="${temporary}/runtime-macos-arm64.o"
macos_x86_64_object="${temporary}/runtime-macos-x86_64.o"
runtime_unwind_object="${temporary}/nuxie_runtime-test.nuxie_runtime.test-cgu.0.rcgu.o"
compile_runtime_object iphoneos arm64-apple-ios15.0 "${device_object}"
compile_runtime_object \
    iphonesimulator \
    arm64-apple-ios15.0-simulator \
    "${simulator_arm64_object}"
compile_runtime_object \
    iphonesimulator \
    x86_64-apple-ios15.0-simulator \
    "${simulator_x86_64_object}"
compile_runtime_object macosx arm64-apple-macos12.0 "${macos_arm64_object}"
compile_runtime_object macosx x86_64-apple-macos12.0 "${macos_x86_64_object}"
compile_runtime_unwind_object \
    iphonesimulator \
    x86_64-apple-ios15.0-simulator \
    "${runtime_unwind_object}"

device_archive="${runtime_path}/${device_identifier}/libnux_capi.a"
simulator_arm64_archive="${temporary}/runtime-simulator-arm64.a"
simulator_x86_64_archive="${temporary}/runtime-simulator-x86_64.a"
simulator_archive="${runtime_path}/${simulator_identifier}/libnux_capi-simulator.a"
macos_arm64_archive="${temporary}/runtime-macos-arm64.a"
macos_x86_64_archive="${temporary}/runtime-macos-x86_64.a"
macos_archive="${runtime_path}/${macos_identifier}/libnux_capi-macos.a"
xcrun ar rcs "${device_archive}" "${device_object}"
xcrun ar rcs "${simulator_arm64_archive}" "${simulator_arm64_object}"
xcrun ar rcs \
    "${simulator_x86_64_archive}" \
    "${simulator_x86_64_object}" \
    "${runtime_unwind_object}"
xcrun lipo \
    -create \
    "${simulator_x86_64_archive}" \
    "${simulator_arm64_archive}" \
    -output "${simulator_archive}"
xcrun ar rcs "${macos_arm64_archive}" "${macos_arm64_object}"
xcrun ar rcs "${macos_x86_64_archive}" "${macos_x86_64_object}"
xcrun lipo \
    -create \
    "${macos_arm64_archive}" \
    "${macos_x86_64_archive}" \
    -output "${macos_archive}"

"${repository_root}/scripts/verify-runtime-native-archive.sh" \
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

xcrun ar r \
    "${simulator_x86_64_archive}" \
    "${rive_object}"
xcrun ranlib "${simulator_x86_64_archive}"
xcrun lipo \
    -create \
    "${simulator_x86_64_archive}" \
    "${simulator_arm64_archive}" \
    -output "${simulator_archive}"

failure_log="${temporary}/failure.log"
if "${repository_root}/scripts/verify-runtime-native-archive.sh" \
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
    'contains C++ object members'; do
    if ! grep -Fq "${expected}" "${failure_log}"; then
        echo "archive verifier failure omitted: ${expected}" >&2
        sed 's/^/  /' "${failure_log}" >&2
        exit 1
    fi
done

echo "Runtime archive verifier audits every architecture and fails closed"

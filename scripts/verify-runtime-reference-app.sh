#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/NuxieFlowRuntimeReference.app" >&2
    exit 64
fi

app_path="$1"
info_plist="${app_path}/Info.plist"

if [[ ! -d "${app_path}" || ! -f "${info_plist}" ]]; then
    echo "runtime reference app was not found at ${app_path}" >&2
    exit 1
fi

bundle_executable="$(plutil -extract CFBundleExecutable raw "${info_plist}")"
main_executable="${app_path}/${bundle_executable}"
payload_executable="${main_executable}"
debug_payload="${app_path}/${bundle_executable}.debug.dylib"

if [[ ! -f "${main_executable}" ]]; then
    echo "runtime reference executable is missing: ${main_executable}" >&2
    exit 1
fi

if [[ -f "${debug_payload}" ]]; then
    payload_executable="${debug_payload}"
fi

if find "${app_path}" \
    \( -iname 'RiveRuntime.framework' -o -iname '*rive-ios*' -o -iname 'librive*' \) \
    -print -quit | grep -q .; then
    echo "runtime reference app contains a Rive artifact" >&2
    exit 1
fi

linked_dependencies="$({ otool -L "${main_executable}"; otool -L "${payload_executable}"; })"
if grep -Eiq 'RiveRuntime|rive-ios|/librive' <<< "${linked_dependencies}"; then
    echo "runtime reference app still links a Rive dependency" >&2
    exit 1
fi

exported_symbols="$(nm -gj "${payload_executable}")"
for expected_symbol in \
    _nux_runtime_abi_major \
    _nux_flow_runtime_context_create; do
    if ! grep -Fxq "${expected_symbol}" <<< "${exported_symbols}"; then
        echo "runtime reference app is missing ${expected_symbol}" >&2
        exit 1
    fi
done

echo "runtime reference app audit passed: Rust runtime linked, Rive absent"

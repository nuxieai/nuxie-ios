#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
    echo "usage: $0 /path/to/Nuxie.framework [/path/to/PrivacyInfo.xcprivacy]" >&2
    exit 64
fi

framework_path="$1"
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
expected_privacy="${2:-${repository_root}/Sources/Nuxie/PrivacyInfo.xcprivacy}"
info_plist="${framework_path}/Info.plist"

if [[ ! -d "${framework_path}" || ! -f "${info_plist}" ]]; then
    echo "customer framework was not found at ${framework_path}" >&2
    exit 1
fi

bundle_executable="$(plutil -extract CFBundleExecutable raw "${info_plist}")"
main_executable="${framework_path}/${bundle_executable}"
payload_executable="${main_executable}"
debug_payload="${framework_path}/${bundle_executable}.debug.dylib"

if [[ ! -f "${main_executable}" ]]; then
    echo "customer framework executable is missing: ${main_executable}" >&2
    exit 1
fi

if [[ -f "${debug_payload}" ]]; then
    payload_executable="${debug_payload}"
fi

if find "${framework_path}" \
    \( -iname 'RiveRuntime.framework' -o -iname '*rive-ios*' -o -iname 'librive*' \) \
    -print -quit | grep -q .; then
    echo "customer framework contains a Rive artifact" >&2
    exit 1
fi

linked_dependencies="$({ otool -L "${main_executable}"; otool -L "${payload_executable}"; })"
if grep -Eiq 'RiveRuntime|rive-ios|/librive' <<< "${linked_dependencies}"; then
    echo "customer framework still links a Rive dependency" >&2
    exit 1
fi

if nm -j "${payload_executable}" 2>/dev/null \
    | awk '$0 ~ /(^|_)_?ZN4rive/ { found = 1 } END { exit(found ? 0 : 1) }'; then
    echo "customer framework contains a Rive C++ namespace symbol" >&2
    exit 1
fi

for expected_symbol in \
    _nux_runtime_abi_major \
    _nux_flow_runtime_context_create; do
    if ! nm -gj "${payload_executable}" 2>/dev/null \
        | awk -v expected="${expected_symbol}" '$0 == expected { found = 1 } END { exit(found ? 0 : 1) }'; then
        echo "customer framework is missing ${expected_symbol}" >&2
        exit 1
    fi
done

privacy_manifest="${framework_path}/PrivacyInfo.xcprivacy"
if [[ ! -f "${expected_privacy}" ]]; then
    echo "expected privacy manifest is missing: ${expected_privacy}" >&2
    exit 1
fi
if [[ ! -f "${privacy_manifest}" ]]; then
    echo "customer framework is missing PrivacyInfo.xcprivacy" >&2
    exit 1
fi
if ! cmp -s "${expected_privacy}" "${privacy_manifest}"; then
    echo "customer framework privacy manifest differs from ${expected_privacy}" >&2
    exit 1
fi

python3 "${repository_root}/scripts/validate-privacy-manifest.py" "${privacy_manifest}"

echo "customer framework audit passed: Rust runtime and exact privacy manifest present, Rive absent"

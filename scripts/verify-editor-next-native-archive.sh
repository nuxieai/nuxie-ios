#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/Nuxie.framework" >&2
    exit 64
fi

framework_path="$1"
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
"${repository_root}/scripts/verify-customer-framework.sh" "${framework_path}"

info_plist="${framework_path}/Info.plist"
bundle_executable="$(plutil -extract CFBundleExecutable raw "${info_plist}")"
main_executable="${framework_path}/${bundle_executable}"
payload_executable="${main_executable}"
debug_payload="${framework_path}/${bundle_executable}.debug.dylib"
if [[ -f "${debug_payload}" ]]; then
    payload_executable="${debug_payload}"
fi

linked_dependencies="$({
    otool -L "${main_executable}"
    otool -L "${payload_executable}"
})"
if grep -Eiq '(^|/)(libc\+\+|libc\+\+abi)(\.|/)' <<< "${linked_dependencies}"; then
    echo "Editor Next customer framework still links the C++ runtime" >&2
    exit 1
fi

symbols="$(nm -u "${payload_executable}" 2>/dev/null || true)"
if grep -Eq '(^|[[:space:]])(___cxa_|___gxx_personality|__Unwind_)' <<< "${symbols}"; then
    echo "Editor Next customer framework still imports exception ABI symbols" >&2
    exit 1
fi
if grep -Eq '(^|[[:space:]])__Z(nw|na|dl|da)' <<< "${symbols}"; then
    echo "Editor Next customer framework still imports C++ allocation symbols" >&2
    exit 1
fi

echo "Editor Next archive audit passed: Rust runtime present; Rive, C++, and exception ABI absent"

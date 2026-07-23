#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 /path/to/Nuxie.framework /path/to/NuxieRuntime.xcframework" >&2
    exit 64
fi

framework_path="$1"
runtime_xcframework_path="$2"
repository_root="$(cd "$(dirname "$0")/.." && pwd)"
"${repository_root}/scripts/verify-customer-framework.sh" "${framework_path}"
"${repository_root}/scripts/validate-runtime-xcframework.sh" "${runtime_xcframework_path}"

temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT

nm_tool="$(xcrun --find nm)"
ar_tool="$(xcrun --find ar)"
lipo_tool="$(xcrun --find lipo)"

audit_failed=0
archive_count=0
architecture_count=0
member_count=0
archive_list="${temporary}/archives"
find "${runtime_xcframework_path}" \
    -type f \
    -name 'libnux_apple_runtime.a' \
    -print \
    | sort >"${archive_list}"

while IFS= read -r archive_path; do
    [[ -n "${archive_path}" ]] || continue
    archive_count=$((archive_count + 1))

    lipo_stderr="${temporary}/lipo-${archive_count}.stderr"
    if ! architecture_list="$("${lipo_tool}" -archs "${archive_path}" 2>"${lipo_stderr}")"; then
        echo "Could not enumerate runtime archive architectures: ${archive_path}" >&2
        sed 's/^/  /' "${lipo_stderr}" >&2
        audit_failed=1
        continue
    fi
    read -r -a architectures <<< "${architecture_list}"
    if [[ "${#architectures[@]}" -eq 0 ]]; then
        echo "Runtime archive contains no architectures: ${archive_path}" >&2
        audit_failed=1
        continue
    fi

    for architecture in "${architectures[@]}"; do
        architecture_count=$((architecture_count + 1))
        context="${archive_path} (architecture ${architecture})"
        thin_archive="${archive_path}"
        if [[ "${#architectures[@]}" -gt 1 ]]; then
            thin_archive="${temporary}/archive-${archive_count}-${architecture}.a"
            thin_stderr="${temporary}/thin-${archive_count}-${architecture}.stderr"
            if ! "${lipo_tool}" \
                "${archive_path}" \
                -thin "${architecture}" \
                -output "${thin_archive}" \
                2>"${thin_stderr}"; then
                echo "Could not extract runtime archive ${context}" >&2
                sed 's/^/  /' "${thin_stderr}" >&2
                audit_failed=1
                continue
            fi
        fi

        ar_stderr="${temporary}/ar-${archive_count}-${architecture}.stderr"
        if ! members="$("${ar_tool}" -t "${thin_archive}" 2>"${ar_stderr}")"; then
            echo "Could not enumerate runtime archive members: ${context}" >&2
            sed 's/^/  /' "${ar_stderr}" >&2
            audit_failed=1
            continue
        fi
        object_members="$(
            grep -Ev '^__.SYMDEF( SORTED)?$' <<< "${members}" \
                | sed '/^$/d' \
                || true
        )"
        if [[ -z "${object_members}" ]]; then
            echo "Runtime archive contains no object members: ${context}" >&2
            audit_failed=1
            continue
        fi
        duplicate_members="$(
            sort <<< "${object_members}" \
                | uniq -d \
                || true
        )"
        if [[ -n "${duplicate_members}" ]]; then
            echo "Runtime archive contains duplicate member names that cannot be attributed: ${context}" >&2
            sed 's/^/  /' <<< "${duplicate_members}" >&2
            audit_failed=1
            continue
        fi
        current_member_count="$(awk 'NF { count += 1 } END { print count + 0 }' <<< "${object_members}")"
        member_count=$((member_count + current_member_count))

        nm_stderr="${temporary}/nm-${archive_count}-${architecture}.stderr"
        if ! symbols="$("${nm_tool}" -A "${thin_archive}" 2>"${nm_stderr}")"; then
            echo "Could not inspect runtime archive member symbols: ${context}" >&2
            sed 's/^/  /' "${nm_stderr}" >&2
            audit_failed=1
            continue
        fi
        unexpected_nm_diagnostics="$(
            grep -Ev ': no symbols$' "${nm_stderr}" \
                || true
        )"
        if [[ -n "${unexpected_nm_diagnostics}" ]]; then
            echo "Runtime archive member inspection emitted unexpected diagnostics: ${context}" >&2
            sed 's/^/  /' <<< "${unexpected_nm_diagnostics}" >&2
            audit_failed=1
            continue
        fi
        inspected_members="$(
            {
                awk -F: 'NF >= 3 { print $(NF - 1) }' <<< "${symbols}"
                awk -F: '/: no symbols$/ { print $(NF - 1) }' "${nm_stderr}"
            } \
                | sort -u
        )"
        uninspected_members="$(
            comm -23 \
                <(sort -u <<< "${object_members}") \
                <(sort -u <<< "${inspected_members}") \
                || true
        )"
        if [[ -n "${uninspected_members}" ]]; then
            echo "Could not attribute symbols for every runtime archive member: ${context}" >&2
            sed 's/^/  /' <<< "${uninspected_members}" >&2
            if [[ -s "${nm_stderr}" ]]; then
                sed 's/^/  nm: /' "${nm_stderr}" >&2
            fi
            audit_failed=1
            continue
        fi

        attributed_symbols="$(sed -E 's/^[^:]+://' <<< "${symbols}")"
        rive_symbols="$(
            grep -E '(_+Z[^[:space:]]*4rive|rive::|RiveRuntime)' \
                <<< "${attributed_symbols}" \
                | sort -u \
                || true
        )"
        cpp_abi_symbols="$(
            grep -E '(_+cxa_|_+gxx_personality|_+Z(nw|na|dl|da)|_+Z(St|NK?St|TV|TI|TS|Th|Tc))' \
                <<< "${attributed_symbols}" \
                | sort -u \
                || true
        )"
        unexpected_unwind_symbols="$(
            grep -E '__Unwind_' <<< "${attributed_symbols}" \
                | grep -Ev '^(std|panic_unwind)-[^:]+\.rcgu\.o:' \
                | sort -u \
                || true
        )"
        cpp_members="$(
            grep -E '\.(cc|cpp|cxx|c\+\+|C|CC|CPP|CXX|mm|MM)\.o$' <<< "${object_members}" \
                | sort -u \
                || true
        )"

        if [[ -n "${rive_symbols}" ]]; then
            echo "NuxieRuntime archive contains Rive C++ symbols: ${context}" >&2
            sed 's/^/  /' <<< "${rive_symbols}" >&2
            audit_failed=1
        fi
        if [[ -n "${cpp_abi_symbols}" ]]; then
            echo "NuxieRuntime archive contains C++ ABI symbols: ${context}" >&2
            sed 's/^/  /' <<< "${cpp_abi_symbols}" >&2
            audit_failed=1
        fi
        if [[ -n "${unexpected_unwind_symbols}" ]]; then
            echo "NuxieRuntime archive contains unwind imports outside Rust std/panic_unwind: ${context}" >&2
            sed 's/^/  /' <<< "${unexpected_unwind_symbols}" >&2
            audit_failed=1
        fi
        if [[ -n "${cpp_members}" ]]; then
            echo "NuxieRuntime archive contains C++ object members: ${context}" >&2
            sed 's/^/  /' <<< "${cpp_members}" >&2
            audit_failed=1
        fi
    done
done <"${archive_list}"

if [[ "${archive_count}" -eq 0 ]]; then
    echo "NuxieRuntime.xcframework contains no libnux_apple_runtime.a slices" >&2
    audit_failed=1
fi
if [[ "${audit_failed}" -ne 0 ]]; then
    exit 1
fi

echo "Editor Next archive audit passed: customer framework contains Rust and no Rive; audited ${archive_count} runtime archives, ${architecture_count} architectures, and ${member_count} attributed members with no C++ provenance"

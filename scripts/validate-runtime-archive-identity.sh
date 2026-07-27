#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/libnux_apple_runtime.a" >&2
    exit 64
fi

archive="$1"
repository_root="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -s "${archive}" ]]; then
    echo "runtime archive was not found or is empty: ${archive}" >&2
    exit 1
fi

if ! nm_tool="$(xcrun --find nm-classic 2>/dev/null)"; then
    nm_tool="nm"
fi
lipo_tool="$(xcrun --find lipo)"
temporary="$(mktemp -d)"
trap 'rm -rf "${temporary}"' EXIT

if ! architecture_list="$("${lipo_tool}" -archs "${archive}")"; then
    echo "could not enumerate runtime archive architectures: ${archive}" >&2
    exit 1
fi
read -r -a architectures <<< "${architecture_list}"
if [[ "${#architectures[@]}" -eq 0 ]]; then
    echo "runtime archive contains no architectures: ${archive}" >&2
    exit 1
fi

slice_index=0
for architecture in "${architectures[@]}"; do
    slice_index=$((slice_index + 1))
    context="${archive} (architecture ${architecture})"
    slice="${archive}"
    if [[ "${#architectures[@]}" -gt 1 ]]; then
        slice="${temporary}/runtime-${architecture}.a"
        if ! "${lipo_tool}" \
            "${archive}" \
            -thin "${architecture}" \
            -output "${slice}"; then
            echo "could not extract runtime archive ${context}" >&2
            exit 1
        fi
    fi

    identity_member=""
    for expected_symbol in \
        _nux_runtime_bind \
        _nux_runtime_build_provenance \
        _nux_flow_runtime_context_create_bound; do
        definitions="$(
            "${nm_tool}" -A -U -gj "${slice}" 2>/dev/null \
                | awk -v expected="${expected_symbol}" \
                    '$NF == expected {
                        sub(": " expected "$", "")
                        print
                    }'
        )"
        definition_count="$(
            awk 'NF { count += 1 } END { print count + 0 }' \
                <<< "${definitions}"
        )"
        if [[ "${definition_count}" -eq 0 ]]; then
            echo "${context} is missing exported symbol ${expected_symbol}" >&2
            exit 1
        fi
        if [[ "${definition_count}" -ne 1 ]]; then
            echo "${context} has ${definition_count} definitions of ${expected_symbol}; expected exactly one" >&2
            exit 1
        fi
        definition="${definitions}"
        member="${definition#"${slice}:"}"
        if [[ "${member}" == "${definition}" ]]; then
            echo "${context} could not attribute ${expected_symbol} to an archive member" >&2
            exit 1
        fi
        if [[ -z "${identity_member}" ]]; then
            identity_member="${member}"
        elif [[ "${identity_member}" != "${member}" ]]; then
            echo "${context} splits runtime identity exports across archive members" >&2
            exit 1
        fi
    done

    member_count="$(
        xcrun ar -t "${slice}" \
            | awk -v expected="${identity_member}" \
                '$0 == expected { count += 1 } END { print count + 0 }'
    )"
    if [[ "${member_count}" -ne 1 ]]; then
        echo "${context} has ${member_count} members named ${identity_member}; expected exactly one" >&2
        exit 1
    fi

    member_directory="${temporary}/identity-${slice_index}-${architecture}"
    mkdir -p "${member_directory}"
    slice_directory="$(cd "$(dirname "${slice}")" && pwd)"
    slice_path="${slice_directory}/$(basename "${slice}")"
    if ! (
        cd "${member_directory}"
        xcrun ar -x "${slice_path}" "${identity_member}"
    ); then
        echo "${context} could not extract identity member ${identity_member}" >&2
        exit 1
    fi
    member_path="${member_directory}/${identity_member}"
    if [[ ! -s "${member_path}" ]]; then
        echo "${context} extracted an empty identity member ${identity_member}" >&2
        exit 1
    fi

    if ! "${repository_root}/scripts/validate-runtime-provenance-record.py" \
        "${member_path}" \
        >/dev/null; then
        echo "${context} identity member ${identity_member} has invalid runtime provenance" >&2
        exit 1
    fi
done

echo "Validated ${archive}: every architecture has exact runtime provenance and binding symbols"

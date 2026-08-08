#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <artifact-metadata> <archive-destination> <xcframework-destination>" >&2
    exit 64
fi

metadata="$1"
archive_destination="$2"
xcframework_destination="$3"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
expected_artifacts_dir="${repo_root}/.artifacts"
mkdir -p "${expected_artifacts_dir}"
if [[ -L "${expected_artifacts_dir}" ]]; then
    echo "Refusing to stage through a symlinked .artifacts directory" >&2
    exit 1
fi
resolved_archive_destination="$(
    cd "$(dirname "${archive_destination}")"
    printf '%s/%s\n' "$(pwd -P)" "$(basename "${archive_destination}")"
)"
resolved_xcframework_destination="$(
    cd "$(dirname "${xcframework_destination}")"
    printf '%s/%s\n' "$(pwd -P)" "$(basename "${xcframework_destination}")"
)"
if [[ "${resolved_archive_destination}" != "${expected_artifacts_dir}/NuxieRuntime.xcframework.zip" ]] \
    || [[ "${resolved_xcframework_destination}" != "${expected_artifacts_dir}/NuxieRuntime.xcframework" ]]; then
    echo "Runtime fetch destinations must be the repository .artifacts paths" >&2
    exit 1
fi
archive_destination="${resolved_archive_destination}"
xcframework_destination="${resolved_xcframework_destination}"
url="$(python3 "${script_dir}/json-scalar.py" "${metadata}" url string)"
expected_checksum="$(python3 "${script_dir}/json-scalar.py" "${metadata}" checksum string)"
release="$(python3 "${script_dir}/json-scalar.py" "${metadata}" release string)"

if [[ ! "${url}" =~ ^https://github\.com/nuxieai/nuxie-runtime/releases/download/${release}/[^/]+\.zip$ ]]; then
    echo "Runtime URL is not an immutable ${release} release asset: ${url}" >&2
    exit 1
fi
if [[ ! "${expected_checksum}" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Runtime checksum is not a lowercase SHA-256 in ${metadata}" >&2
    exit 1
fi

artifacts_dir="${expected_artifacts_dir}"
temporary="$(mktemp -d "${artifacts_dir}/.runtime-fetch.XXXXXX")"
trap 'rm -rf "${temporary}"' EXIT
candidate_archive="${temporary}/NuxieRuntime.xcframework.zip"

if [[ -f "${archive_destination}" ]] \
    && [[ "$(swift package compute-checksum "${archive_destination}")" == "${expected_checksum}" ]]; then
    cp "${archive_destination}" "${candidate_archive}"
else
    curl --fail --location --retry 3 --retry-all-errors \
        --output "${candidate_archive}" "${url}"
fi

actual_checksum="$(swift package compute-checksum "${candidate_archive}")"
if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
    echo "Runtime checksum mismatch" >&2
    echo "expected: ${expected_checksum}" >&2
    echo "actual:   ${actual_checksum}" >&2
    exit 1
fi

unpacked="${temporary}/unpacked"
mkdir -p "${unpacked}"
ditto -x -k "${candidate_archive}" "${unpacked}"
candidate_xcframework="${unpacked}/NuxieRuntime.xcframework"
if [[ ! -d "${candidate_xcframework}" ]]; then
    echo "Runtime archive does not contain top-level NuxieRuntime.xcframework" >&2
    exit 1
fi

"${script_dir}/verify-runtime-artifact.sh" \
    --metadata "${metadata}" \
    --archive "${candidate_archive}" \
    --xcframework "${candidate_xcframework}"

rm -f "${archive_destination}"
rm -rf "${xcframework_destination}"
mv "${candidate_archive}" "${archive_destination}"
mv "${candidate_xcframework}" "${xcframework_destination}"
echo "Staged ${release} at ${xcframework_destination}"

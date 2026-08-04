#!/usr/bin/env bash
# Assemble the committed runtime archive from a staged, validated XCFramework.
#
# This lives in its own script rather than inline in the Makefile so that the
# packaging recipe itself is a hashed provenance input. If the archive assembly
# changes - ditto flags, layout, anything affecting the produced bytes - the
# provenance guard must notice that the committed archive was produced by
# obsolete logic. A Makefile recipe could not serve that purpose: the Makefile
# changes constantly for unrelated reasons, so hashing it would fail the guard
# on edits that cannot affect the archive.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <staged-xcframework> <output-archive>" >&2
    exit 2
fi

staged="$1"
output="$2"

if [[ ! -d "${staged}" ]]; then
    echo "Staged XCFramework not found: ${staged}" >&2
    exit 1
fi

output_directory="$(dirname "${output}")"
mkdir -p "${output_directory}"

temporary="$(mktemp -d "${output_directory}/.runtime-package.XXXXXX")"
trap 'rm -rf "${temporary}"' EXIT

candidate="${temporary}/$(basename "${output}")"
ditto -c -k --sequesterRsrc --keepParent "${staged}" "${candidate}"
mv "${candidate}" "${output}"

echo "Packaged ${output}"

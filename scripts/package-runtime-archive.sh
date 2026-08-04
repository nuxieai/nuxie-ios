#!/usr/bin/env bash
# Publish the build script's own archive as the committed runtime archive.
#
# The committed bytes are produced entirely by scripts/build-runtime-xcframework.sh,
# which is a hashed provenance input. This script only copies that output into
# place; it deliberately does no assembly of its own.
#
# That boundary matters. Earlier revisions re-zipped from the staged
# .artifacts/ copy, which made the committed bytes depend on the Makefile's
# stage-runtime-xcframework recipe as well as on this script's ditto flags -
# neither of which is hashed, and neither of which can be hashed without
# hashing the whole Makefile, which changes constantly for unrelated reasons.
# Copying the build output instead means exactly one hashed script determines
# the committed bytes, so no Makefile recipe can leave the guard green while
# the archive goes stale.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <built-archive> <output-archive>" >&2
    exit 2
fi

built="$1"
output="$2"

if [[ ! -f "${built}" ]]; then
    echo "Built runtime archive not found: ${built}" >&2
    echo "Run 'make build-runtime-xcframework' first." >&2
    exit 1
fi

mkdir -p "$(dirname "${output}")"
cp "${built}" "${output}"

echo "Packaged ${output} from ${built}"

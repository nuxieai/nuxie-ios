#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-runtime-boundary-test.XXXXXX")"
trap 'rm -rf "${temporary}"' EXIT

fixture="${temporary}/repository"
mkdir -p "${fixture}/scripts"
cp "${repository_root}/Package.swift" "${fixture}/Package.swift"
cp -R "${repository_root}/Sources" "${fixture}/Sources"
cp \
    "${repository_root}/scripts/check-runtime-module-boundary.sh" \
    "${fixture}/scripts/check-runtime-module-boundary.sh"

run_boundary() {
    (cd "${fixture}" && bash scripts/check-runtime-module-boundary.sh)
}

run_boundary >/dev/null

forbidden="${fixture}/Sources/NuxieRuntime/ForbiddenRuntimeImport.swift"
printf '%s\n' 'import NuxieRuntimeC' >"${forbidden}"
if run_boundary >"${temporary}/portable.log" 2>&1; then
    echo "runtime boundary accepted a second portable C importer" >&2
    exit 1
fi
grep -Fq 'Only NuxieNativeRuntime.swift may import the portable C module.' \
    "${temporary}/portable.log"

: >"${forbidden}"
printf '%s\n' 'import NuxieRuntimeFFI' >"${forbidden}"
if run_boundary >"${temporary}/legacy.log" 2>&1; then
    echo "runtime boundary accepted legacy FFI outside the compatibility target" >&2
    exit 1
fi
grep -Fq 'Legacy FFI imports must remain inside the temporary compatibility target.' \
    "${temporary}/legacy.log"

: >"${forbidden}"
product_forbidden="${fixture}/Sources/Nuxie/ForbiddenLegacyImport.swift"
printf '%s\n' 'import NuxieRuntimeLegacy' >"${product_forbidden}"
if run_boundary >"${temporary}/product.log" 2>&1; then
    echo "runtime boundary accepted a second product legacy importer" >&2
    exit 1
fi
grep -Fq 'Only the existing package-authentication cutover point may import NuxieRuntimeLegacy.' \
    "${temporary}/product.log"

echo "Runtime module boundary fails closed for portable, legacy, and product imports"

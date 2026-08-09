#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-runtime-boundary-test.XXXXXX")"
trap 'rm -rf "${temporary}"' EXIT

fixture="${temporary}/repository"
mkdir -p "${fixture}/scripts"
package_dump="${temporary}/package.json"
swift_wrapper_directory="${temporary}/bin"
mkdir -p "${swift_wrapper_directory}"
(cd "${repository_root}" && swift package dump-package >"${package_dump}")
printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' '[[ "$*" == "package dump-package" ]]' 'exec /bin/cat "${NUXIE_BOUNDARY_PACKAGE_DUMP}"' \
    >"${swift_wrapper_directory}/swift"
chmod +x "${swift_wrapper_directory}/swift"
cp "${repository_root}/Package.swift" "${fixture}/Package.swift"
cp "${repository_root}/project.yml" "${fixture}/project.yml"
cp -R "${repository_root}/Sources" "${fixture}/Sources"
cp \
    "${repository_root}/scripts/check-runtime-module-boundary.sh" \
    "${fixture}/scripts/check-runtime-module-boundary.sh"

run_boundary() {
    (
        cd "${fixture}"
        NUXIE_BOUNDARY_PACKAGE_DUMP="${package_dump}" \
            PATH="${swift_wrapper_directory}:${PATH}" \
            bash scripts/check-runtime-module-boundary.sh
    )
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
printf '%s\n' '@_implementationOnly import NuxieRuntimeC' >"${forbidden}"
if run_boundary >"${temporary}/portable-modifier.log" 2>&1; then
    echo "runtime boundary accepted a modified second portable C importer" >&2
    exit 1
fi
grep -Fq 'Only NuxieNativeRuntime.swift may import the portable C module.' \
    "${temporary}/portable-modifier.log"

: >"${forbidden}"
printf '%s\n' '@_implementationOnly' 'import NuxieRuntimeC' >"${forbidden}"
if run_boundary >"${temporary}/portable-split-modifier.log" 2>&1; then
    echo "runtime boundary accepted a split attributed second portable C importer" >&2
    exit 1
fi
grep -Fq 'Only NuxieNativeRuntime.swift may import the portable C module.' \
    "${temporary}/portable-split-modifier.log"

: >"${forbidden}"
printf '%s\n' 'import NuxieRuntimeFFI' >"${forbidden}"
if run_boundary >"${temporary}/legacy.log" 2>&1; then
    echo "runtime boundary accepted a legacy FFI import" >&2
    exit 1
fi
grep -Fq 'The legacy runtime FFI is forbidden from Swift source.' \
    "${temporary}/legacy.log"

: >"${forbidden}"
printf '%s\n' '@_implementationOnly import NuxieRuntimeFFI' >"${forbidden}"
if run_boundary >"${temporary}/legacy-modifier.log" 2>&1; then
    echo "runtime boundary accepted a modified legacy FFI importer" >&2
    exit 1
fi
grep -Fq 'The legacy runtime FFI is forbidden from Swift source.' \
    "${temporary}/legacy-modifier.log"

: >"${forbidden}"
printf '%s\n' '@_implementationOnly' '@preconcurrency' 'import NuxieRuntimeFFI' >"${forbidden}"
if run_boundary >"${temporary}/legacy-split-modifier.log" 2>&1; then
    echo "runtime boundary accepted a split attributed legacy FFI importer" >&2
    exit 1
fi
grep -Fq 'The legacy runtime FFI is forbidden from Swift source.' \
    "${temporary}/legacy-split-modifier.log"

: >"${forbidden}"
printf '%s\n' '@_implementationOnly' '' '// legal trivia between the attribute and declaration' 'import NuxieRuntimeFFI' >"${forbidden}"
if run_boundary >"${temporary}/legacy-split-trivia.log" 2>&1; then
    echo "runtime boundary accepted a split attributed legacy FFI importer with trivia" >&2
    exit 1
fi
grep -Fq 'The legacy runtime FFI is forbidden from Swift source.' \
    "${temporary}/legacy-split-trivia.log"

: >"${forbidden}"
printf '%s\n' 'import' 'NuxieRuntimeFFI' >"${forbidden}"
if run_boundary >"${temporary}/legacy-import-newline.log" 2>&1; then
    echo "runtime boundary accepted a newline inside a legacy FFI import" >&2
    exit 1
fi
grep -Fq 'The legacy runtime FFI is forbidden from Swift source.' \
    "${temporary}/legacy-import-newline.log"

: >"${forbidden}"
printf '%s\n' 'import/* legal Swift trivia */NuxieRuntimeFFI' >"${forbidden}"
if run_boundary >"${temporary}/legacy-import-comment.log" 2>&1; then
    echo "runtime boundary accepted a comment inside a legacy FFI import" >&2
    exit 1
fi
grep -Fq 'The legacy runtime FFI is forbidden from Swift source.' \
    "${temporary}/legacy-import-comment.log"

: >"${forbidden}"
printf '%s\n' '/* legal Swift trivia */import NuxieRuntimeFFI' >"${forbidden}"
if run_boundary >"${temporary}/legacy-leading-comment.log" 2>&1; then
    echo "runtime boundary accepted a comment before a legacy FFI import" >&2
    exit 1
fi
grep -Fq 'The legacy runtime FFI is forbidden from Swift source.' \
    "${temporary}/legacy-leading-comment.log"

: >"${forbidden}"
printf '%s\n' '@_implementationOnly/* legal Swift trivia */import NuxieRuntimeFFI' >"${forbidden}"
if run_boundary >"${temporary}/legacy-attribute-comment.log" 2>&1; then
    echo "runtime boundary accepted a comment between an attribute and legacy FFI import" >&2
    exit 1
fi
grep -Fq 'The legacy runtime FFI is forbidden from Swift source.' \
    "${temporary}/legacy-attribute-comment.log"

: >"${forbidden}"
printf '%s\n' 'import struct NuxieRuntimeFFI.NuxByteView' >"${forbidden}"
if run_boundary >"${temporary}/legacy-declaration.log" 2>&1; then
    echo "runtime boundary accepted a declaration-scoped legacy FFI importer" >&2
    exit 1
fi
grep -Fq 'The legacy runtime FFI is forbidden from Swift source.' \
    "${temporary}/legacy-declaration.log"

: >"${forbidden}"
printf '%s\n' 'import Foundation; import NuxieRuntimeFFI' >"${forbidden}"
if run_boundary >"${temporary}/legacy-semicolon.log" 2>&1; then
    echo "runtime boundary accepted a non-first legacy FFI importer" >&2
    exit 1
fi
grep -Fq 'The legacy runtime FFI is forbidden from Swift source.' \
    "${temporary}/legacy-semicolon.log"

: >"${forbidden}"
printf '%s\n' 'import Foundation; @_exported import NuxieProductFFI' >"${forbidden}"
if run_boundary >"${temporary}/reexport-semicolon.log" 2>&1; then
    echo "runtime boundary accepted a non-first FFI re-export" >&2
    exit 1
fi
grep -Fq 'The runtime FFI must not be re-exported through a Swift module.' \
    "${temporary}/reexport-semicolon.log"

: >"${forbidden}"
printf '%s\n' '@_exported @preconcurrency import NuxieProductFFI' >"${forbidden}"
if run_boundary >"${temporary}/reexport-modifier.log" 2>&1; then
    echo "runtime boundary accepted an attributed FFI re-export" >&2
    exit 1
fi
grep -Fq 'The runtime FFI must not be re-exported through a Swift module.' \
    "${temporary}/reexport-modifier.log"

: >"${forbidden}"
printf '%s\n' '@preconcurrency @_exported import NuxieProductFFI' >"${forbidden}"
if run_boundary >"${temporary}/reexport-reversed-modifier.log" 2>&1; then
    echo "runtime boundary accepted an FFI re-export after another attribute" >&2
    exit 1
fi
grep -Fq 'The runtime FFI must not be re-exported through a Swift module.' \
    "${temporary}/reexport-reversed-modifier.log"

: >"${forbidden}"
product_forbidden="${fixture}/Sources/Nuxie/ForbiddenLegacyImport.swift"
printf '%s\n' 'import NuxieRuntimeLegacy' >"${product_forbidden}"
if run_boundary >"${temporary}/product.log" 2>&1; then
    echo "runtime boundary accepted a legacy Swift-module import" >&2
    exit 1
fi
grep -Fq 'The legacy Swift runtime module is forbidden from product source.' \
    "${temporary}/product.log"

: >"${product_forbidden}"
printf '%s\n' 'let leaked = NativeExperiencePackageAuthenticator()' >"${product_forbidden}"
if run_boundary >"${temporary}/native-auth.log" 2>&1; then
    echo "runtime boundary accepted a legacy native package-authentication caller" >&2
    exit 1
fi
grep -Fq 'Legacy native package authentication is forbidden from product source.' \
    "${temporary}/native-auth.log"

: >"${product_forbidden}"
printf '%s\n' 'let leaked = LegacyOnlyNuxPackageAuthenticatedHydrator.self' >"${product_forbidden}"
if run_boundary >"${temporary}/legacy-hydrator.log" 2>&1; then
    echo "runtime boundary accepted a legacy authenticated hydrator caller" >&2
    exit 1
fi
grep -Fq 'The legacy authenticated hydrator is forbidden from product source.' \
    "${temporary}/legacy-hydrator.log"

: >"${product_forbidden}"
: >"${forbidden}"
printf '%s\n' 'let status = nux_screen_session_result_status(result)' >"${forbidden}"
if run_boundary >"${temporary}/legacy-symbol.log" 2>&1; then
    echo "runtime boundary accepted a legacy product-result accessor" >&2
    exit 1
fi
grep -Fq 'Legacy product-shaped runtime ABI symbols are forbidden from Swift source.' \
    "${temporary}/legacy-symbol.log"

: >"${forbidden}"
printf '%s\n' 'let leaked: ScreenSession? = nil' >"${forbidden}"
if run_boundary >"${temporary}/legacy-vocabulary.log" 2>&1; then
    echo "runtime boundary accepted legacy product/session vocabulary" >&2
    exit 1
fi
grep -Fq 'Legacy product/session runtime vocabulary is forbidden from Swift source.' \
    "${temporary}/legacy-vocabulary.log"

: >"${forbidden}"
cp "${repository_root}/project.yml" "${fixture}/project.yml"
python3 - "${fixture}/project.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace("  NuxieRuntime:\n", "  NuxieRuntimeLegacyTests:\n", 1))
PY
if run_boundary >"${temporary}/xcodegen-legacy-target.log" 2>&1; then
    echo "runtime boundary accepted a legacy XcodeGen target" >&2
    exit 1
fi
grep -Fq 'The forbidden XcodeGen target NuxieRuntimeLegacyTests must not exist.' \
    "${temporary}/xcodegen-legacy-target.log"

cp "${repository_root}/project.yml" "${fixture}/project.yml"
python3 - "${fixture}/project.yml" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
path.write_text(text.replace("      - target: NuxieRuntime\n", "      - target: NuxieRuntimeSupportMac\n", 1))
PY
if run_boundary >"${temporary}/xcodegen-stale-edge.log" 2>&1; then
    echo "runtime boundary accepted a stale XcodeGen dependency" >&2
    exit 1
fi
grep -Fq 'NuxieSDK retains a stale XcodeGen dependency on NuxieRuntimeSupportMac.' \
    "${temporary}/xcodegen-stale-edge.log"

echo "Runtime module boundary fails closed for portable, legacy, and product imports"

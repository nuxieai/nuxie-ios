#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

status=0
owned_files="$(git ls-files --cached --others --exclude-standard)"
if grep -Eq '(^|/)(Cargo\.toml|Cargo\.lock|rust-toolchain|rust-toolchain\.toml)$|\.rs$' <<< "${owned_files}"; then
    echo "nuxie-ios must not own Cargo manifests, Rust source, or a Rust toolchain" >&2
    status=1
fi
if [[ -e .gitmodules ]] || git ls-files --stage | awk '$1 == "160000" { found = 1 } END { exit(found ? 0 : 1) }'; then
    echo "nuxie-ios must not own runtime source through a git submodule" >&2
    status=1
fi
if git ls-files | grep -Eq '^Runtime/.*\.(zip|xcframework)(/|$)'; then
    echo "nuxie-ios must not commit a runtime binary; consume the versioned release" >&2
    status=1
fi
ownership_pattern='cargo (build|test)|rustup|build-runtime-xcframework|'
ownership_pattern+='package-runtime-xcframework|native/Cargo|third_party/nuxie-runtime'
if rg -n --glob '!scripts/check-runtime-consumer-boundary.sh' \
    "${ownership_pattern}" \
    Makefile Package.swift .buildkite .github scripts README.md CONTRIBUTING.md CLAUDE.md 2>/dev/null; then
    echo "nuxie-ios still contains active Rust build or source-ownership instructions" >&2
    status=1
fi

if [[ "${status}" -eq 0 ]]; then
    echo "Runtime consumer boundary passed: Swift-only SDK owns no native runtime build"
fi
exit "${status}"

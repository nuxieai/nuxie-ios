#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

if rg -n '^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+NuxieRuntimeFFI$' Sources/Nuxie; then
    echo "The Nuxie SDK imports the runtime FFI directly; import the Swift NuxieRuntime module instead." >&2
    exit 1
fi

if ! rg -q '^@_exported import NuxieRuntimeFFI$' Sources/NuxieRuntime/NuxieRuntime.swift; then
    echo "The legacy Swift FFI export changed; finish moving all raw C use behind NuxieRuntime before removing it." >&2
    exit 1
fi

if ! rg -Uq 'name: "NuxieRuntime",\n[[:space:]]+dependencies: \[\n[[:space:]]+\.target\(\n[[:space:]]+name: "NuxieRuntimeFFI",\n[[:space:]]+condition: \.when\(platforms: \[\.iOS\]\)' Package.swift; then
    echo "NuxieRuntimeFFI must remain an iOS-only dependency of the Swift NuxieRuntime target." >&2
    exit 1
fi

if ! rg -Uq 'name: "Nuxie",\n[[:space:]]+dependencies: \[\n[[:space:]]+\.target\(\n[[:space:]]+name: "NuxieRuntime",\n[[:space:]]+condition: \.when\(platforms: \[\.iOS\]\)' Package.swift; then
    echo "Rendered NuxieRuntime support must remain iOS-only in the Nuxie product." >&2
    exit 1
fi

if ! rg -q '^module NuxieRuntimeFFI \{' native/nux-apple-runtime/include/module.modulemap; then
    echo "The runtime XCFramework module map must expose only NuxieRuntimeFFI." >&2
    exit 1
fi

if rg -q '^module NuxieRuntime \{' native/nux-apple-runtime/include/module.modulemap; then
    echo "The binary module is shadowing the Swift NuxieRuntime module." >&2
    exit 1
fi

echo "Runtime module boundary passed: Nuxie -> Swift NuxieRuntime -> NuxieRuntimeFFI"

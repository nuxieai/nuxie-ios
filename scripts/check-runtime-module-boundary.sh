#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

if rg -n '^[[:space:]]*(@_exported[[:space:]]+)?import[[:space:]]+NuxieRuntimeFFI$' Sources/Nuxie; then
    echo "The Nuxie SDK imports the runtime FFI directly; import the Swift NuxieRuntime module instead." >&2
    exit 1
fi

if ! rg -q '^@_exported import NuxieRuntimeFFI$' Sources/NuxieRuntime/NuxieRuntime.swift; then
    echo "The temporary Swift runtime compatibility export changed; finish migrating legacy bridge files before removing it." >&2
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

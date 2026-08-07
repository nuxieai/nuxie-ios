#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

if rg -n '^[[:space:]]*(?:(?:(?:private|fileprivate|internal|package|public)|@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)[[:space:]]+)*import[[:space:]]+(?:(?:typealias|struct|class|enum|protocol|let|var|func|operator|precedencegroup)[[:space:]]+)?(?:NuxieRuntimeFFI|NuxieProductFFI)(?:\.|[[:space:];]|$)' Sources/Nuxie; then
    echo "The Nuxie SDK imports the runtime FFI directly; import the Swift NuxieRuntime module instead." >&2
    exit 1
fi

if ! rg -q '^@_exported import NuxieRuntimeFFI$' Sources/NuxieRuntime/NuxieRuntime.swift; then
    echo "The legacy Swift FFI export changed; finish moving all raw C use behind NuxieRuntime before removing it." >&2
    exit 1
fi

python3 - <<'PY'
import json
import subprocess
import sys

manifest = json.loads(
    subprocess.run(
        ["swift", "package", "dump-package"],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    ).stdout
)
targets = {target["name"]: target for target in manifest["targets"]}


def has_exact_ios_dependency(owner, dependency):
    matching_edges = []
    for item in targets.get(owner, {}).get("dependencies", []):
        edge = item.get("target")
        if isinstance(edge, list) and edge and edge[0] == dependency:
            matching_edges.append(edge)
    return matching_edges == [[dependency, {"platformNames": ["ios"]}]]


required_edges = (
    ("NuxieRuntime", "NuxieRuntimeFFI"),
    ("Nuxie", "NuxieRuntime"),
)
for owner_name, dependency_name in required_edges:
    if not has_exact_ios_dependency(owner_name, dependency_name):
        print(
            f"{dependency_name} must remain an iOS-only dependency of "
            f"the {owner_name} target.",
            file=sys.stderr,
        )
        raise SystemExit(1)
PY

if ! rg -q '^module NuxieRuntimeFFI \{' native/nux-apple-runtime/include/module.modulemap; then
    echo "The runtime XCFramework module map must expose only NuxieRuntimeFFI." >&2
    exit 1
fi

if rg -q '^module NuxieRuntime \{' native/nux-apple-runtime/include/module.modulemap; then
    echo "The binary module is shadowing the Swift NuxieRuntime module." >&2
    exit 1
fi

if ! rg -q '^members = \["nux-apple-runtime", "nuxie-apple-adapter"\]$' native/Cargo.toml; then
    echo "The native workspace must build the SDK-owned Apple adapter." >&2
    exit 1
fi

if ! rg -q '^nuxie-apple-adapter = \{ path = "\.\./nuxie-apple-adapter", optional = true \}$' native/nux-apple-runtime/Cargo.toml; then
    echo "nux-apple-runtime must consume the SDK-owned Apple adapter." >&2
    exit 1
fi

if rg -q 'third_party/nuxie-runtime/crates/nuxie-apple-adapter' native; then
    echo "The SDK must not import Apple product policy from nuxie-runtime." >&2
    exit 1
fi

if rg -q 'wgpu|wgpu_hal|wgpu-core|wgpu_hal|as_hal|raw_device|raw_queue' \
    native/nuxie-apple-adapter/Cargo.toml \
    native/nuxie-apple-adapter/src; then
    echo "The Apple adapter must stay behind the renderer's opaque presenter seam." >&2
    exit 1
fi

echo "Runtime module boundary passed: Nuxie -> Swift NuxieRuntime -> NuxieRuntimeFFI"

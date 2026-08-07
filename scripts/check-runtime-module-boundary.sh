#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

if rg -n '^[[:space:]]*(?:(?:(?:private|fileprivate|internal|package|public)|@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)[[:space:]]+)*import[[:space:]]+(?:(?:typealias|struct|class|enum|protocol|let|var|func|operator|precedencegroup)[[:space:]]+)?(?:NuxieRuntimeFFI|NuxieProductFFI)(?:\.|[[:space:];]|$)' Sources/Nuxie; then
    echo "The Nuxie SDK imports the runtime FFI directly; import the Swift NuxieRuntime module instead." >&2
    exit 1
fi

if rg -n '^[[:space:]]*@_exported[[:space:]]+import[[:space:]]+(NuxieRuntimeFFI|NuxieProductFFI)(?:[[:space:];]|$)' Sources; then
    echo "The runtime FFI must not be re-exported through a Swift module." >&2
    exit 1
fi

if rg -n '\bnux_[a-z0-9_]+\b|\bNux(ByteView|Experience|Screen|Apple|Operation|Flow)[A-Za-z0-9_]*\b' Sources/Nuxie; then
    echo "The Nuxie SDK names raw runtime ABI symbols; move that use behind Sources/NuxieRuntime." >&2
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
)
for owner_name, dependency_name in required_edges:
    if not has_exact_ios_dependency(owner_name, dependency_name):
        print(
            f"{dependency_name} must remain an iOS-only dependency of "
            f"the {owner_name} target.",
            file=sys.stderr,
        )
        raise SystemExit(1)

nuxie_runtime_edges = []
for item in targets.get("Nuxie", {}).get("dependencies", []):
    edge = item.get("byName")
    if isinstance(edge, list) and edge and edge[0] == "NuxieRuntime":
        nuxie_runtime_edges.append(edge)
if nuxie_runtime_edges != [["NuxieRuntime", None]]:
    print(
        "Nuxie must depend unconditionally on the Swift NuxieRuntime value module; "
        "only its FFI edge is iOS-only.",
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

echo "Runtime module boundary passed: product Swift contains no raw runtime ABI use"

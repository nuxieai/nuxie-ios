#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

swift_import_head='(?:^|;)[[:space:]]*(?:(?:(?:private|fileprivate|internal|package|public)|@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)[[:space:]]+)*import[[:space:]]+(?:(?:typealias|struct|class|enum|protocol|let|var|func|operator|precedencegroup)[[:space:]]+)?'

if rg -n "${swift_import_head}(?:NuxieRuntimeC|NuxieRuntimeFFI|NuxieProductFFI)(?:\\.|[[:space:];]|$)" Sources/Nuxie; then
    echo "The Nuxie SDK imports the runtime FFI directly; import the Swift NuxieRuntime module instead." >&2
    exit 1
fi

if rg -n '(?:^|;)[[:space:]]*(?:(?:(?:private|fileprivate|internal|package|public)|@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)[[:space:]]+)*@_exported[[:space:]]+(?:(?:(?:private|fileprivate|internal|package|public)|@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)[[:space:]]+)*import[[:space:]]+(?:NuxieRuntimeC|NuxieRuntimeFFI|NuxieProductFFI)(?:\.|[[:space:];]|$)' Sources; then
    echo "The runtime FFI must not be re-exported through a Swift module." >&2
    exit 1
fi

if rg -l "${swift_import_head}(?:NuxieRuntimeC|NuxieRuntimeFFI)(?:\\.|[[:space:];]|$)" Sources \
    | grep -Ev '^Sources/NuxieRuntime/'; then
    echo "Only Sources/NuxieRuntime may import the low-level runtime module." >&2
    exit 1
fi

capi_imports="$(rg -l "${swift_import_head}NuxieRuntimeC(?:\\.|[[:space:];]|$)" Sources || true)"
if [[ "${capi_imports}" != "Sources/NuxieRuntime/NuxieNativeRuntime.swift" ]]; then
    echo "Only NuxieNativeRuntime.swift may import the portable C module." >&2
    printf '%s\n' "${capi_imports}" >&2
    exit 1
fi

legacy_ffi_imports="$(rg -l "${swift_import_head}NuxieRuntimeFFI(?:\\.|[[:space:];]|$)" Sources | LC_ALL=C sort || true)"
expected_legacy_ffi_imports="$(printf '%s\n' \
    Sources/NuxieRuntime/NuxieRuntimeAdapter.swift \
    Sources/NuxieRuntime/NuxieRuntimeImportRequest.swift \
    Sources/NuxieRuntime/NuxieRuntimeResultDecoder.swift \
    Sources/NuxieRuntime/NuxieRuntimeStatus.swift \
    | LC_ALL=C sort)"
if [[ "${legacy_ffi_imports}" != "${expected_legacy_ffi_imports}" ]]; then
    echo "Legacy FFI imports must remain inside the temporary compatibility target." >&2
    diff -u <(printf '%s\n' "${expected_legacy_ffi_imports}") \
        <(printf '%s\n' "${legacy_ffi_imports}") >&2 || true
    exit 1
fi

legacy_product_imports="$(rg -l "${swift_import_head}NuxieRuntimeLegacy(?:\\.|[[:space:];]|$)" Sources/Nuxie || true)"
if [[ "${legacy_product_imports}" != "Sources/Nuxie/Experiences/ExperiencePackageAuthenticator+Legacy.swift" ]]; then
    echo "Only the explicit legacy presentation cutover file may import NuxieRuntimeLegacy." >&2
    printf '%s\n' "${legacy_product_imports}" >&2
    exit 1
fi

legacy_auth_users="$(rg -l '\bNativeExperiencePackageAuthenticator\b|\bauthenticateRetainingContext\b' Sources/Nuxie | LC_ALL=C sort || true)"
expected_legacy_auth_users="$(printf '%s\n' \
    Sources/Nuxie/Experiences/ExperiencePackageAuthenticator+Legacy.swift \
    Sources/Nuxie/Experiences/ExperienceRuntimeFixtureHost.swift \
    Sources/Nuxie/Experiences/ExperienceViewController.swift \
    | LC_ALL=C sort)"
if [[ "${legacy_auth_users}" != "${expected_legacy_auth_users}" ]]; then
    echo "Legacy native package authentication may remain only at the explicit presentation cutover points." >&2
    diff -u <(printf '%s\n' "${expected_legacy_auth_users}") \
        <(printf '%s\n' "${legacy_auth_users}") >&2 || true
    exit 1
fi

legacy_hydrator_users="$(rg -l '\bLegacyOnlyNuxPackageAuthenticatedHydrator\b' Sources/Nuxie | LC_ALL=C sort || true)"
expected_legacy_hydrator_users="$(printf '%s\n' \
    Sources/Nuxie/Experiences/ExperiencePackageAuthenticator+Legacy.swift \
    Sources/Nuxie/Experiences/NuxPackage.swift \
    | LC_ALL=C sort)"
if [[ "${legacy_hydrator_users}" != "${expected_legacy_hydrator_users}" ]]; then
    echo "Unauthenticated package hydration may remain only behind the explicit legacy authentication boundary." >&2
    diff -u <(printf '%s\n' "${expected_legacy_hydrator_users}") \
        <(printf '%s\n' "${legacy_hydrator_users}") >&2 || true
    exit 1
fi

if rg -n '\bnux_[a-z0-9_]+\b|\bNux(ByteView|Experience|Screen|Apple|Operation|Flow|File|Artboard|Player|ViewModel|Renderer|Metal|Capi)[A-Za-z0-9_]*\b' Sources/Nuxie; then
    echo "The Nuxie SDK names raw runtime ABI symbols; move that use behind Sources/NuxieRuntime." >&2
    exit 1
fi

if rg -n '\bnux_(experience_context|screen_session|flow_session)_[a-z0-9_]+\b|\bNux(ExperienceContext|ScreenSession|FlowSession)\b' \
    Sources/NuxieRuntime/NuxieNativeRuntime.swift; then
    echo "The Swift-native runtime tracer must not call the legacy context/session bootstrap ABI." >&2
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


def has_exact_apple_dependency(owner, dependency):
    matching_edges = []
    for item in targets.get(owner, {}).get("dependencies", []):
        edge = item.get("target")
        if isinstance(edge, list) and edge and edge[0] == dependency:
            matching_edges.append(edge)
    return matching_edges == [[dependency, {"platformNames": ["ios", "macos"]}]]


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
    if not has_exact_apple_dependency(owner_name, dependency_name):
        print(
            f"{dependency_name} must remain an iOS-and-macOS dependency of "
            f"the {owner_name} target.",
            file=sys.stderr,
        )
        raise SystemExit(1)

if not has_exact_ios_dependency("NuxieRuntimeLegacy", "NuxieRuntimeFFI"):
    print("NuxieRuntimeLegacy must be the sole iOS-only legacy FFI target.", file=sys.stderr)
    raise SystemExit(1)
if not has_exact_ios_dependency("Nuxie", "NuxieRuntimeLegacy"):
    print("Nuxie may retain the legacy compatibility target only on iOS.", file=sys.stderr)
    raise SystemExit(1)
legacy_support_edges = [
    item.get("byName")
    for item in targets.get("NuxieRuntimeLegacy", {}).get("dependencies", [])
    if isinstance(item.get("byName"), list) and item["byName"][0] == "NuxieRuntimeSupport"
]
if legacy_support_edges != [["NuxieRuntimeSupport", None]]:
    print(
        "The legacy compatibility target must reuse only C-independent runtime support; "
        "depending on NuxieRuntime would reintroduce the v0.4.0 header collision.",
        file=sys.stderr,
    )
    raise SystemExit(1)

native_support_edges = [
    item.get("byName")
    for item in targets.get("NuxieRuntime", {}).get("dependencies", [])
    if isinstance(item.get("byName"), list) and item["byName"][0] == "NuxieRuntimeSupport"
]
if native_support_edges != [["NuxieRuntimeSupport", None]]:
    print("NuxieRuntime must reuse the C-independent runtime support target.", file=sys.stderr)
    raise SystemExit(1)

nuxie_runtime_edges = []
for item in targets.get("Nuxie", {}).get("dependencies", []):
    edge = item.get("byName")
    if isinstance(edge, list) and edge and edge[0] == "NuxieRuntime":
        nuxie_runtime_edges.append(edge)
if nuxie_runtime_edges != [["NuxieRuntime", None]]:
    print(
        "Nuxie must depend unconditionally on the Swift NuxieRuntime value module; "
        "only its temporary legacy compatibility edge is iOS-only.",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY

echo "Runtime module boundary passed: product Swift contains no raw runtime ABI use"

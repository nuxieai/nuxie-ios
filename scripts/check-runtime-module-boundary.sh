#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "${repo_root}"

swift_import_head='(?:^|;)[[:space:]]*(?:(?:(?:private|fileprivate|internal|package|public)|@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)[[:space:]]+)*import[[:space:]]+(?:(?:typealias|struct|class|enum|protocol|let|var|func|operator|precedencegroup)[[:space:]]+)?'
swift_import_inline_trivia='(?:(?:[\t ]++)|(?:/\*(?s:.*?)\*/))*'
swift_import_prefix="(?m)(?:^|;)${swift_import_inline_trivia}(?:(?:(?:private|fileprivate|internal|package|public)|@[A-Za-z_][A-Za-z0-9_]*(?:\\([^\\r\\n]*\\))?)${swift_import_inline_trivia})*import"
swift_import_trivia='(?:(?:[[:space:]]++)|(?:/\*(?s:.*?)\*/)|(?://[^\r\n]*(?:\r?\n|$)))+'
swift_import_declaration_kind='(?:typealias|struct|class|enum|protocol|let|var|func|operator|precedencegroup)'

find_swift_importers() {
    local module_pattern="$1"
    shift
    {
        rg -l "${swift_import_head}(?:${module_pattern})(?:\\.|[[:space:];]|$)" "$@" || true
        rg -l -P -U "${swift_import_prefix}${swift_import_trivia}(?:${swift_import_declaration_kind}${swift_import_trivia})?(?:${module_pattern})(?:\\.|[[:space:];]|$)" "$@" || true
    } | LC_ALL=C sort -u
}

sdk_ffi_imports="$(find_swift_importers 'NuxieRuntimeC|NuxieRuntimeFFI|NuxieProductFFI' Sources/Nuxie)"
if [[ -n "${sdk_ffi_imports}" ]]; then
    echo "The Nuxie SDK imports the runtime FFI directly; import the Swift NuxieRuntime module instead." >&2
    printf '%s\n' "${sdk_ffi_imports}" >&2
    exit 1
fi

if rg -n '(?:^|;)[[:space:]]*(?:(?:(?:private|fileprivate|internal|package|public)|@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)[[:space:]]+)*@_exported[[:space:]]+(?:(?:(?:private|fileprivate|internal|package|public)|@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?)[[:space:]]+)*import[[:space:]]+(?:NuxieRuntimeC|NuxieRuntimeFFI|NuxieProductFFI)(?:\.|[[:space:];]|$)' Sources; then
    echo "The runtime FFI must not be re-exported through a Swift module." >&2
    exit 1
fi

product_ffi_imports="$(find_swift_importers 'NuxieProductFFI' Sources)"
if [[ -n "${product_ffi_imports}" ]]; then
    echo "The runtime FFI must not be re-exported through a Swift module." >&2
    printf '%s\n' "${product_ffi_imports}" >&2
    exit 1
fi

if find_swift_importers 'NuxieRuntimeC|NuxieRuntimeFFI' Sources \
    | grep -Ev '^Sources/NuxieRuntime/'; then
    echo "Only Sources/NuxieRuntime may import the low-level runtime module." >&2
    exit 1
fi

capi_imports="$(find_swift_importers 'NuxieRuntimeC' Sources)"
if [[ "${capi_imports}" != "Sources/NuxieRuntime/NuxieNativeRuntime.swift" ]]; then
    echo "Only NuxieNativeRuntime.swift may import the portable C module." >&2
    printf '%s\n' "${capi_imports}" >&2
    exit 1
fi

legacy_ffi_imports="$(find_swift_importers 'NuxieRuntimeFFI' Sources)"
if [[ -n "${legacy_ffi_imports}" ]]; then
    echo "The legacy runtime FFI is forbidden from Swift source." >&2
    printf '%s\n' "${legacy_ffi_imports}" >&2
    exit 1
fi

legacy_product_imports="$(find_swift_importers 'NuxieRuntimeLegacy[A-Za-z0-9_]*' Sources/Nuxie)"
if [[ -n "${legacy_product_imports}" ]]; then
    echo "The legacy Swift runtime module is forbidden from product source." >&2
    printf '%s\n' "${legacy_product_imports}" >&2
    exit 1
fi

legacy_auth_users="$(rg -l '\bNativeExperiencePackageAuthenticator\b|\bauthenticateRetainingContext\b' Sources/Nuxie | LC_ALL=C sort || true)"
if [[ -n "${legacy_auth_users}" ]]; then
    echo "Legacy native package authentication is forbidden from product source." >&2
    printf '%s\n' "${legacy_auth_users}" >&2
    exit 1
fi

legacy_hydrator_users="$(rg -l '\bLegacyOnlyNuxPackageAuthenticatedHydrator\b' Sources/Nuxie | LC_ALL=C sort || true)"
if [[ -n "${legacy_hydrator_users}" ]]; then
    echo "The legacy authenticated hydrator is forbidden from product source." >&2
    printf '%s\n' "${legacy_hydrator_users}" >&2
    exit 1
fi

if rg -n '/experiences/.*/versions|\bexperienceVersion\(experienceId:|\bapiKeyInQuery\b' Sources/Nuxie; then
    echo "The legacy exact-version package wire endpoint is forbidden from product source." >&2
    exit 1
fi

if rg -n '\bnux_[a-z0-9_]+\b|\bNux(ByteView|Experience|Screen|Apple|Operation|Flow|File|Artboard|Player|ViewModel|Renderer|Metal|Capi)[A-Za-z0-9_]*\b' Sources/Nuxie; then
    echo "The Nuxie SDK names raw runtime ABI symbols; move that use behind Sources/NuxieRuntime." >&2
    exit 1
fi

if rg -n '\bnux_(experience_context|screen_session|flow_session)_[a-z0-9_]+\b|\bNux(ExperienceContext|ScreenSession|FlowSession)\b' \
    Sources/NuxieRuntime/NuxieNativeRuntime.swift; then
    echo "The Swift-native runtime wrapper must not call the retired product bootstrap ABI." >&2
    exit 1
fi

if rg -n '\bnux_(experience_context|screen_session|flow_session|operation_result|apple_surface)_[a-z0-9_]+\b|\bNux(Experience|Screen|Flow|AppleSurface)[A-Za-z0-9_]*\b' \
    Sources --glob '*.swift'; then
    echo "Legacy product-shaped runtime ABI symbols are forbidden from Swift source." >&2
    exit 1
fi

if rg -n '\b(ScreenSession|ExperienceRuntimeContext|ExperienceRuntimeHost|NuxieRuntimeAdapter|NativeExperiencePackageAuthenticator|LegacyOnlyNuxPackageAuthenticatedHydrator)\b' \
    Sources --glob '*.swift'; then
    echo "Legacy product/session runtime vocabulary is forbidden from Swift source." >&2
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
    ("NuxieRuntime", "NuxieRuntimeBinary"),
)
for owner_name, dependency_name in required_edges:
    if not has_exact_apple_dependency(owner_name, dependency_name):
        print(
            f"{dependency_name} must remain an iOS-and-macOS dependency of "
            f"the {owner_name} target.",
            file=sys.stderr,
        )
        raise SystemExit(1)

for target_name in targets:
    if target_name.startswith(("NuxieRuntimeLegacy", "NuxieRuntimeSupport")):
        print(f"The retired Swift runtime target {target_name} must not exist.", file=sys.stderr)
        raise SystemExit(1)
    if target_name.startswith("NuxieRuntimeFFI"):
        print("The compatibility-named runtime binary target must not exist.", file=sys.stderr)
        raise SystemExit(1)

for item in targets.get("Nuxie", {}).get("dependencies", []):
    edge = item.get("target") or item.get("byName")
    if isinstance(edge, list) and edge and edge[0].startswith("NuxieRuntimeLegacy"):
        print("Nuxie must not depend on a legacy Swift runtime target.", file=sys.stderr)
        raise SystemExit(1)

for owner, target in targets.items():
    for item in target.get("dependencies", []):
        edge = item.get("target") or item.get("byName")
        if isinstance(edge, list) and edge and edge[0].startswith(("NuxieRuntimeLegacy", "NuxieRuntimeSupport")):
            print(f"{owner} retains a stale runtime-support dependency.", file=sys.stderr)
            raise SystemExit(1)

nuxie_runtime_edges = []
for item in targets.get("Nuxie", {}).get("dependencies", []):
    edge = item.get("byName")
    if isinstance(edge, list) and edge and edge[0] == "NuxieRuntime":
        nuxie_runtime_edges.append(edge)
if nuxie_runtime_edges != [["NuxieRuntime", None]]:
    print(
        "Nuxie must depend unconditionally on the sole Swift NuxieRuntime module.",
        file=sys.stderr,
    )
    raise SystemExit(1)
PY

python3 - <<'PY'
from pathlib import Path
import sys

lines = Path("project.yml").read_text().splitlines()
targets = {}
in_targets = False
current_target = None
in_dependencies = False

for line in lines:
    if line == "targets:":
        in_targets = True
        continue
    if in_targets and line and not line.startswith(" "):
        break
    if not in_targets:
        continue
    if line.startswith("  ") and not line.startswith("    ") and line.endswith(":"):
        current_target = line.strip()[:-1]
        targets[current_target] = []
        in_dependencies = False
        continue
    if current_target is None:
        continue
    if line == "    dependencies:":
        in_dependencies = True
        continue
    if line.startswith("    ") and not line.startswith("      "):
        in_dependencies = False
    if in_dependencies and line.startswith("      - "):
        key, separator, value = line[8:].partition(":")
        if separator:
            targets[current_target].append((key.strip(), value.strip()))

for target_name in targets:
    if target_name.startswith(("NuxieRuntimeLegacy", "NuxieRuntimeSupport", "NuxieRuntimeFFI")):
        print(f"The forbidden XcodeGen target {target_name} must not exist.", file=sys.stderr)
        raise SystemExit(1)

for owner, dependencies in targets.items():
    for kind, dependency in dependencies:
        if kind == "target" and dependency.startswith(("NuxieRuntimeLegacy", "NuxieRuntimeSupport")):
            print(f"{owner} retains a stale XcodeGen dependency on {dependency}.", file=sys.stderr)
            raise SystemExit(1)

required_target_edges = {
    "NuxieSDK": "NuxieRuntime",
    "NuxieSDKMac": "NuxieRuntimeMac",
}
for owner, dependency in required_target_edges.items():
    matches = [value for kind, value in targets.get(owner, []) if kind == "target" and value == dependency]
    if matches != [dependency]:
        print(f"{owner} must depend exactly once on {dependency} in project.yml.", file=sys.stderr)
        raise SystemExit(1)

artifact = ".artifacts/NuxieRuntime.xcframework"
for owner in ("NuxieRuntime", "NuxieRuntimeMac", "NuxieSDK", "NuxieSDKMac"):
    matches = [value for kind, value in targets.get(owner, []) if kind == "framework" and value == artifact]
    if matches != [artifact]:
        print(f"{owner} must link the released runtime artifact exactly once in project.yml.", file=sys.stderr)
        raise SystemExit(1)
PY

echo "Runtime module boundary passed: product Swift contains no raw runtime ABI use"

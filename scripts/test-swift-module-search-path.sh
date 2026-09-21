#!/usr/bin/env bash
set -euo pipefail

scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$scripts_dir/swift-module-search-path.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-module-path.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/spm/Modules/Nuxie.swiftmodule" "$scratch/xcode/Nuxie.swiftmodule"
[[ "$(swift_module_search_path "$scratch/spm" Nuxie)" == "$scratch/spm/Modules" ]]
[[ "$(swift_module_search_path "$scratch/xcode" Nuxie)" == "$scratch/xcode" ]]

# Ignore an unrelated module directory, but fail rather than guess when absent.
mkdir -p "$scratch/xcode/Modules/Other.swiftmodule" "$scratch/missing"
[[ "$(swift_module_search_path "$scratch/xcode" Nuxie)" == "$scratch/xcode" ]]
if swift_module_search_path "$scratch/missing" Nuxie >"$scratch/out" 2>"$scratch/err"; then
  echo "Missing module unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -s "$scratch/out" && -s "$scratch/err" ]]
echo "Swift module search paths pass for SPM, Xcode, and missing modules"

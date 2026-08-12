#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-public-api.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

cd "$repo_root"
architecture="$(uname -m)"

extract_platform() {
  local name="$1"
  local sdk_name="$2"
  local target="$3"
  local actual="$scratch/public-api-$name.txt"
  local digest="$scratch/Nuxie-$name.json"
  local sdk_path
  local bin_path

  sdk_path="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
  swift build --target Nuxie --triple "$target" --sdk "$sdk_path" >/dev/null
  bin_path="$(swift build --show-bin-path --triple "$target" --sdk "$sdk_path")"
  xcrun swift-api-digester \
    -dump-sdk \
    -module Nuxie \
    -I "$bin_path/Modules" \
    -target "$target" \
    -sdk "$sdk_path" \
    -o "$digest" \
    -swift-only \
    -avoid-location \
    -avoid-tool-args \
    -abort-on-module-fail
  python3 scripts/extract-public-api.py "$digest" > "$actual"
}

extract_platform macos macosx "$architecture-apple-macosx12.0"
extract_platform ios iphoneos "arm64-apple-ios15.0"

if [[ "${1:-}" == "--update" ]]; then
  cp "$scratch/public-api-macos.txt" "$repo_root/api/public-api.txt"
  cp "$scratch/public-api-ios.txt" "$repo_root/api/public-api-ios.txt"
  echo "Updated macOS and iOS public API baselines"
  exit 0
fi

status=0
diff -u "$repo_root/api/public-api.txt" "$scratch/public-api-macos.txt" || status=1
diff -u "$repo_root/api/public-api-ios.txt" "$scratch/public-api-ios.txt" || status=1

if [[ "$status" -ne 0 ]]; then
  echo >&2
  echo "Public API changed. Keep implementation details internal, or review the" >&2
  echo "intentional API change and run: scripts/check-public-api.sh --update" >&2
  exit "$status"
fi

echo "macOS and iOS public APIs match their baselines"

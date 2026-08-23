#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-public-api.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

cd "$repo_root"
architecture="$(uname -m)"
mode="${1:-}"

if [[ "$mode" != "--update" ]]; then
  python3 scripts/check-public-api-spi-leaks.py \
    api/public-api.txt api/spi-api.txt
  python3 scripts/check-public-api-spi-leaks.py \
    api/public-api-ios.txt api/spi-api-ios.txt
fi

extract_platform() {
  local name="$1"
  local sdk_name="$2"
  local target="$3"
  local actual="$scratch/public-api-$name.txt"
  local spi_actual="$scratch/spi-api-$name.txt"
  local digest="$scratch/Nuxie-$name.json"
  local customer_digest="$scratch/Nuxie-$name-customer.json"
  local compatibility="$scratch/compatibility-$name.txt"
  local baseline_digest="$scratch/Nuxie-$name-baseline.json"
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
  python3 scripts/extract-public-api.py \
    "$digest" \
    --spi-output "$spi_actual" \
    --customer-digest-output "$customer_digest" \
    > "$actual"
  python3 scripts/check-public-api-spi-leaks.py "$actual" "$spi_actual"

  if [[ "$mode" != "--update" ]]; then
    gzip -cd "$repo_root/api/public-api-$name.json.gz" > "$baseline_digest"
    xcrun swift-api-digester \
      -diagnose-sdk \
      -baseline-path "$baseline_digest" \
      -module Nuxie \
      -I "$bin_path/Modules" \
      -target "$target" \
      -sdk "$sdk_path" \
      -swift-only \
      -o "$compatibility"
  fi
}

extract_platform macos macosx "$architecture-apple-macosx12.0"
extract_platform ios iphoneos "arm64-apple-ios15.0"

if [[ "$mode" == "--update" ]]; then
  cp "$scratch/public-api-macos.txt" "$repo_root/api/public-api.txt"
  cp "$scratch/public-api-ios.txt" "$repo_root/api/public-api-ios.txt"
  cp "$scratch/spi-api-macos.txt" "$repo_root/api/spi-api.txt"
  cp "$scratch/spi-api-ios.txt" "$repo_root/api/spi-api-ios.txt"
  gzip -cn "$scratch/Nuxie-macos-customer.json" \
    > "$repo_root/api/public-api-macos.json.gz"
  gzip -cn "$scratch/Nuxie-ios-customer.json" \
    > "$repo_root/api/public-api-ios.json.gz"
  python3 scripts/check-public-api-spi-leaks.py \
    "$repo_root/api/public-api.txt" "$repo_root/api/spi-api.txt"
  python3 scripts/check-public-api-spi-leaks.py \
    "$repo_root/api/public-api-ios.txt" "$repo_root/api/spi-api-ios.txt"
  echo "Updated macOS and iOS customer and SPI API baselines"
  exit 0
fi

status=0
diff -u "$repo_root/api/public-api.txt" "$scratch/public-api-macos.txt" || status=1
diff -u "$repo_root/api/public-api-ios.txt" "$scratch/public-api-ios.txt" || status=1
diff -u "$repo_root/api/spi-api.txt" "$scratch/spi-api-macos.txt" || status=1
diff -u "$repo_root/api/spi-api-ios.txt" "$scratch/spi-api-ios.txt" || status=1

for platform in macos ios; do
  # The native digester preserves compatibility details omitted by the
  # declaration inventory, including conformances and default arguments.
  # Its empty report contains only section headings and whitespace.
  if grep -Ev '^[[:space:]]*$|^[[:space:]]*/\*.*\*/[[:space:]]*$' \
      "$scratch/compatibility-$platform.txt" | grep -q .; then
    cat "$scratch/compatibility-$platform.txt" >&2
    status=1
  fi
done

if [[ "$status" -ne 0 ]]; then
  echo >&2
  echo "Customer or SPI API changed, or customer API is source-incompatible." >&2
  echo "Keep implementation" >&2
  echo "details internal, or review the" >&2
  echo "intentional API change and run: scripts/check-public-api.sh --update" >&2
  exit "$status"
fi

echo "macOS and iOS customer and SPI APIs match their baselines"

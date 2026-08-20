#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-provider-adapters.XXXXXX")"
cp "$repo_root/Package.resolved" "$fixture_root/Package.resolved"
run_with_runtime_selection() {
  if [[ -e "$repo_root/.artifacts/NuxieRuntime.xcframework" ]]; then
    NUXIE_RUNTIME_USE_LOCAL=1 "$@"
  else
    env -u NUXIE_RUNTIME_USE_LOCAL "$@"
  fi
}
cleanup() {
  cp "$fixture_root/Package.resolved" "$repo_root/Package.resolved"
  rm -rf "$fixture_root"
}
trap cleanup EXIT

mkdir -p "$fixture_root/Positive/Sources"
cp "$repo_root/Examples/Adapters/NuxieRevenueCatPurchaseDelegate.swift" \
  "$fixture_root/Positive/Sources/"
cp "$repo_root/Examples/Adapters/NuxieSuperwallPurchaseDelegate.swift" \
  "$fixture_root/Positive/Sources/"

copy_documented_provider_snippet() {
  local environment_name="$1"
  local destination_name="$2"
  local source_path="${!environment_name:-}"
  if [[ -z "$source_path" ]]; then
    return
  fi
  if [[ ! -f "$source_path" ]]; then
    echo "$environment_name does not name a readable Swift source: $source_path" >&2
    exit 1
  fi
  cp "$source_path" "$fixture_root/Positive/Sources/$destination_name"
}

copy_documented_provider_snippet \
  NUXIE_REVENUECAT_DOC_SNIPPET \
  DocumentedRevenueCatConfiguration.swift
copy_documented_provider_snippet \
  NUXIE_SUPERWALL_DOC_SNIPPET \
  DocumentedSuperwallConfiguration.swift

cat > "$fixture_root/Positive/Sources/Smoke.swift" <<'EOF'
import Nuxie

public func maintainedProviderDelegates() -> [any NuxiePurchaseDelegate] {
    [NuxieRevenueCatPurchaseDelegate(), NuxieSuperwallPurchaseDelegate()]
}
EOF

cat > "$fixture_root/Positive/project.yml" <<EOF
name: ProviderAdapterBoundary
options:
  deploymentTarget:
    iOS: "15.0"
packages:
  Nuxie:
    path: $repo_root
  RevenueCat:
    url: https://github.com/RevenueCat/purchases-ios.git
    from: 5.83.2
  Superwall:
    url: https://github.com/superwall/Superwall-iOS.git
    from: 4.16.3
targets:
  ProviderAdapterBoundary:
    type: framework
    platform: iOS
    sources:
      - Sources
    dependencies:
      - package: Nuxie
        product: Nuxie
      - package: RevenueCat
        product: RevenueCat
      - package: Superwall
        product: SuperwallKit
    settings:
      CODE_SIGNING_ALLOWED: NO
      GENERATE_INFOPLIST_FILE: YES
      SWIFT_VERSION: 5.9
EOF

(
  cd "$fixture_root/Positive"
  run_with_runtime_selection xcodegen generate >/dev/null
  run_with_runtime_selection xcodebuild build -quiet \
    -project ProviderAdapterBoundary.xcodeproj \
    -scheme ProviderAdapterBoundary \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$fixture_root/PositiveDerivedData" \
    CODE_SIGNING_ALLOWED=NO
)

echo "provider adapter boundary passed: maintained source adapters build without core provider dependencies"

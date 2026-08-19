#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/nuxie-provider-adapters.XXXXXX")"
cp "$repo_root/Package.resolved" "$fixture_root/Package.resolved"
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
  NUXIE_RUNTIME_USE_LOCAL=1 xcodegen generate >/dev/null
  NUXIE_RUNTIME_USE_LOCAL=1 xcodebuild build -quiet \
    -project ProviderAdapterBoundary.xcodeproj \
    -scheme ProviderAdapterBoundary \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$fixture_root/PositiveDerivedData" \
    CODE_SIGNING_ALLOWED=NO
)

echo "provider adapter boundary passed: maintained source adapters build without core provider dependencies"

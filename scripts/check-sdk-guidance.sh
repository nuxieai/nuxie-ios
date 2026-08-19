#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "SDK guidance check failed: $1" >&2
  exit 1
}

grep -Fq 'public func reset(keepAnonymousId: Bool = false)' Sources/Nuxie/NuxieSDK.swift \
  || fail 'NuxieSDK.reset default changed'
grep -Fq 'keepAnonymousId = false by default' README.md \
  || fail 'README reset default is stale'
grep -Fq 'NuxieSDK.shared.getCurrentSessionId()' README.md \
  || fail 'README is missing the public session accessor'

for removed_api in startNewSession endSession resetSession 'setSessionId('; do
  if grep -Fq "$removed_api" README.md; then
    fail "README mentions removed manual-session API: $removed_api"
  fi
done

for removed_config in enableFileLogging propertiesSanitizer do-not-track do‑not‑track FactoryKit \
  Container.shared '@Injected(' DI/NuxieContainer.swift; do
  if grep -Fq "$removed_config" README.md CLAUDE.md; then
    fail "top-level guidance mentions removed configuration/infrastructure: $removed_config"
  fi
done

grep -Fq 'test             - Run the full unit + native-runtime + integration + macOS gate' Makefile \
  || fail 'Make help does not describe the full test gate'

revenuecat_adapter='Examples/Adapters/NuxieRevenueCatPurchaseDelegate.swift'
grep -Fq 'init()' "$revenuecat_adapter" \
  || fail 'RevenueCat adapter is missing its shared-instance public initializer'
grep -Fq 'init(purchases: PurchasesType)' "$revenuecat_adapter" \
  || fail 'RevenueCat adapter is missing internal test injection'
if grep -Fq 'public init(purchases:' "$revenuecat_adapter"; then
  fail 'RevenueCat adapter exposes forgeable provider injection publicly'
fi
for provider_adapter in Examples/Adapters/NuxieRevenueCatPurchaseDelegate.swift \
  Examples/Adapters/NuxieSuperwallPurchaseDelegate.swift; do
  if grep -Eq 'purchasedWithStoreKitEvidence|transaction\.finish' "$provider_adapter"; then
    fail "provider adapter takes transaction sync/finish ownership: $provider_adapter"
  fi
done
if grep -R -Fq 'shouldObservePurchases = true' \
  Examples/SwiftUI-Superwall Examples/UIKit-Superwall; then
  fail 'Superwall examples disable its transaction finisher'
fi

echo 'SDK guidance matches the current public surface.'

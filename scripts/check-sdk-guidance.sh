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

for removed_purchase_api in \
  StoreKitPurchaseEvidence \
  providerPurchased \
  purchasedWithStoreKitEvidence \
  providerRestored \
  storeKitRestored \
  'purchaseOutcome('; do
  if grep -R -Fq "$removed_purchase_api" Sources Examples README.md; then
    fail "maintained source or guidance mentions removed purchase API: $removed_purchase_api"
  fi
done
for removed_delegate_signature in 'func purchase(_ product' 'func restore()'; do
  if grep -R -Fq "$removed_delegate_signature" \
    Sources/Nuxie/StoreKit/NuxiePurchaseDelegate.swift Examples README.md; then
    fail "maintained delegate guidance mentions removed signature: $removed_delegate_signature"
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
  if grep -Eq 'transaction\.finish' "$provider_adapter"; then
    fail "provider adapter takes transaction sync/finish ownership: $provider_adapter"
  fi
done

for provider_example in \
  Examples/SwiftUI-RevenueCat/Sources/App/MoodLogApp.swift \
  Examples/UIKit-RevenueCat/Sources/App/AppDelegate.swift \
  Examples/SwiftUI-Superwall/Sources/App/MoodLogApp.swift \
  Examples/UIKit-Superwall/Sources/App/AppDelegate.swift; do
  grep -Fq 'purchaseHandlingMode = .observer' "$provider_example" \
    || fail "provider example does not assign StoreKit finishing ownership: $provider_example"
  grep -Fq 'purchaseDelegate = Nuxie' "$provider_example" \
    || fail "provider example does not configure the maintained delegate: $provider_example"
done

for completion_contract in \
  'one checkout-scoped completion' \
  'callback and StoreKit observer' \
  'idempotent by StoreKit transaction ID'; do
  grep -Fq "$completion_contract" README.md \
    || fail "README is missing durable completion guidance: $completion_contract"
done
if grep -R -Fq 'shouldObservePurchases = true' \
  Examples/SwiftUI-Superwall Examples/UIKit-Superwall; then
  fail 'Superwall examples disable its transaction finisher'
fi

echo 'SDK guidance matches the current public surface.'

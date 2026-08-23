<p align="center">
  <a href="https://nuxie.ai" target="_blank" rel="noopener">
    <img alt="Nuxie" src="https://nuxie.ai/favicon-192.png" width="64" height="64" />
  </a>
</p>

<div align="center">
  <strong>Nuxie Apple SDK</strong>
  <br />
  Bring targeted in‑app flows, paywalls, and analytics to your iOS or macOS app.
  <br /><br />
  <a href="https://nuxie.ai" target="_blank" rel="noopener">Website</a>
</div>

---

## What is Nuxie?

Nuxie is a platform for running targeted in‑app experiences such as paywalls, upgrade prompts, surveys, and more — without shipping new app releases. This SDK connects your iOS or macOS app to Nuxie so you can track events, identify users, and automatically present experiences configured in the Nuxie dashboard. An experience holds the screens (Rive-rendered by the Nuxie Rust runtime) and the journey that drives them; journeys execute client-side from cached config.

Learn more at https://nuxie.ai

## Features

- Event tracking: send custom events with properties and user traits.
- User identity: anonymous IDs, `identify`, and event linking on login.
- Experiences: server‑driven journeys + screens that present in‑app UI, executed client‑side from cached config.
- Session tracking: automatic idle/lifetime rotation with a read-only current-session accessor.
- Purchases: delegate‑based StoreKit integration for buy/restore.
- Automatic lifecycle events: $app_installed, $app_updated, $app_opened, $app_backgrounded (can be disabled).
- Privacy & controls: sensitive-value log redaction and a `beforeSend` transform/drop hook.
- Offline-first, precisely: committed events are normally persisted locally before observers run and re-sent after relaunch (deduplicated server-side); a history-write failure advances the durable completeness fence so local evaluation fails closed instead of silently reasoning across a gap. Journey enrollment and gate decisions evaluate from cached config, so network failure degrades freshness, never function.
- Resilient Experiences: authenticated profile snapshots remain offline-usable for 24 hours, verified release objects use a bounded 256 MiB disk LRU, speculative preparation respects Low Data Mode and app lifecycle, and StoreKit failures block only product-bound selected screens.

### Local event-history contract

The on-device event log is a retained window, not a complete lifetime record.
Delivered events are bounded by count and age, so unbounded journey conditions
that need an exact count, first/last occurrence, aggregate, or sequence fail
closed when evaluated from device history. Negating such a condition does not
turn an unknown answer into a match. A condition with an authored lower bound
(`since`, `within`, or an active-period window) is deterministic only when its
whole window is inside the durable, monotonic horizon reported by local
storage. Retention advances that horizon atomically with deletion; history-write
gaps, corrupt property payloads, query truncation, and storage failure are
unknown and fail closed.
See [Event-history semantics](docs/event-history-semantics.md) for the precise
contract and current v1 schema guidance.

## Requirements

- iOS 15+
- macOS 12+ for non-rendering SDK behavior
- Swift 5.9+ (Xcode 15+)

Rendered product experiences are intentionally iOS-only. The pure-Swift
`NuxieRuntime` ownership facade and its portable C dependency also compile as
part of the macOS SDK graph, but macOS applications expose only events,
identity, configuration, networking, and other non-rendering SDK surfaces. A
rendered macOS experience host requires separate design and qualification.

On iOS, the SDK talks to the Nuxie runtime through the pure-Swift
`NuxieRuntime` module. Its native ownership file is the sole importer of the
low-level `NuxieRuntimeC` module supplied by a versioned XCFramework release from
[`nuxie-runtime`](https://github.com/nuxieai/nuxie-runtime). Application and
SDK contributors do not build Rust from this repository.

## Installation (Swift Package Manager)

Add the package to your app:

1) Xcode → File → Add Package Dependencies…
- Package URL: `https://github.com/nuxieai/nuxie-ios`
- Dependency Rule: a branch or commit SHA
- Add the `Nuxie` product to your app target

The SDK pins an immutable runtime release URL and checksum. Selecting an SDK
branch or commit therefore also selects one qualified runtime artifact.

This private-beta SDK uses one hard-cut Experience contract. Apps adopting a
new SDK commit must republish their Experiences so they contain authenticated
routes, named screen actions, and response sessions in the current canonical
shape. Unsupported descriptors and actions fail closed; the SDK does not keep
compatibility aliases or fallback decoders for superseded authored behavior.

Or via `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/nuxieai/nuxie-ios", branch: "main")
]
```

## Quick Start

Initialize early (e.g., in your app entry point) with your API key from the Nuxie dashboard.

SwiftUI App:

```swift
import SwiftUI
import Nuxie

@main
struct MyApp: App {
  init() {
    var config = NuxieConfiguration(apiKey: "NX_…")
    config.environment = .production // .staging, .development, or .custom
    config.logLevel = .info
    // Optional: configure purchases
    // config.purchaseDelegate = MyPurchaseDelegate()

    do { try NuxieSDK.shared.setup(with: config) }
    catch { print("Nuxie setup failed: \(error)") }
  }

  var body: some Scene { WindowGroup { ContentView() } }
}
```

UIKit (AppDelegate):

```swift
import UIKit
import Nuxie

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
    let config = NuxieConfiguration(apiKey: "NX_…")
    config.environment = .production
    config.logLevel = .warning

    do { try NuxieSDK.shared.setup(with: config) }
    catch { print("Nuxie setup failed: \(error)") }
    return true
  }
}
```

Identify a user (login):

```swift
NuxieSDK.shared.identify(
  "user_123",
  userProperties: ["plan": "free"],
  userPropertiesSetOnce: ["signup_at": Date()]
)
```

Trigger events (optionally observe decisions/entitlements):

```swift
NuxieSDK.shared.trigger(
  "premium_feature_tapped",
  properties: ["feature": "pro_filters"]
)

Task {
  NuxieSDK.shared.trigger(
    "premium_feature_tapped",
    properties: ["feature": "pro_filters"]
  ) { update in
    switch update {
    case .entitlement(.allowed):
      print("Unlocked")
    case .decision(.noMatch):
      break
    case .error(let error):
      print("Trigger failed: \(error.message)")
    default:
      break
    }
  }
}
```

Logout / clear identity:

```swift
NuxieSDK.shared.reset() // keepAnonymousId = false by default
```

## API Overview

- `NuxieSDK.shared.setup(with:)`: initialize the SDK (call once).
- `NuxieSDK.shared.identify(_:userProperties:userPropertiesSetOnce:)`: identify a user and set traits.
- `NuxieSDK.shared.trigger(_:properties:userProperties:userPropertiesSetOnce:)`: trigger events (analytics-only).
- `NuxieSDK.shared.trigger(_:properties:userProperties:userPropertiesSetOnce:handler:)`: trigger events with decisions/entitlements.
- `NuxieSDK.shared.reset(keepAnonymousId:)`: clear identity (e.g., logout).
- `NuxieSDK.shared.version`: current SDK version string.
- `NuxieSDK.shared.getDistinctId()`: current distinct ID (identified or anonymous).
- `NuxieSDK.shared.getCurrentSessionId()`: read the current automatically managed session ID.
- `NuxieSDK.shared.shutdown()`: tear down services (usually not needed).

### Experiences

- The experience engine owns presentation. Trigger matching and journey execution
  decide when an experience is shown; applications do not construct or present
  experience view controllers directly.
- `await NuxieSDK.shared.dismiss()`: dismisses the presented experience. It is a
  no-op when none is presented, waits for that experience's in-flight purchase or
  restore without interrupting StoreKit, and abandons its in-progress server-effect
  wait before dismissing. The journey exits as dismissed, and a pending
  `triggerAndWait` resolves as a completed journey with that exit reason.
- On macOS, `target: "in_app"` link actions open in the default browser (no in-app Safari view).

## Configuration Highlights

Create with `NuxieConfiguration(apiKey:)` and optionally set:

- `environment`: `.production` (default), `.staging`, `.development`, `.custom` (+ `apiEndpoint`).
- `testStoreEnabled`: the isolated, local-only commerce sheet (development +
  `pk_test_` key only).
- Logging: `logLevel`, `enableConsoleLogging`, `redactSensitiveData`. Interpolated
  identifiers, payloads, paths, and error details are replaced with
  process-stable HMAC-SHA-256 summaries by default. Set
  `redactSensitiveData = false` only for an explicitly consented diagnostic
  session because raw values may enter logs.
- Batching: `eventBatchSize`, `flushAt`, `flushInterval`, `maxQueueSize`,
  `retryCount`, and `retryDelay`. Setup requires batch, threshold, and queue
  counts within `1...Int32.max`; rejects a flush threshold above queue capacity;
  non-finite intervals; negative retry values; and timer/backoff combinations
  that cannot be scheduled safely.
- Hooks: `beforeSend` to transform or drop events.
- Experience releases use the authenticated delivery origins supplied by the
  profile; applications cannot override signed object locations.
- Purchases: `purchaseDelegate` to handle StoreKit buy/restore in your app.
- Lifecycle events: `trackApplicationLifecycleEvents` (default `true`).

Minimal example:

```swift
var config = NuxieConfiguration(apiKey: "NX_…")
config.environment = .staging
config.beforeSend = { event in
  // Example: drop noisy dev events
  event.name.hasPrefix("dev_") ? nil : event
}
```

### Nuxie Test Store (development only)

Use the Test Store when qualifying a signed Experience, paywall copy, purchase
outcomes, restore branches, and local Feature Access without configuring App
Store products or charging an account:

```swift
let config = NuxieConfiguration(apiKey: "pk_test_demo")
config.environment = .development
config.testStoreEnabled = true
try NuxieSDK.shared.setup(with: config)
```

The sheet is deliberately branded `Nuxie Test Store` and says that it creates
no StoreKit transaction. It offers explicit Purchased, Pending, Cancelled, and
Failed outcomes, plus Restored, No Purchases, and Failed restore outcomes. A
successful test purchase applies the signed Product-to-Feature mapping only to
the in-memory local Feature Access view and emits the normal Experience/Journey
purchase events with `test_store: true`; it does not call StoreKit, a purchase
delegate, the transaction listener, or a production purchase endpoint.

This is different from an Xcode StoreKit Configuration file (which exercises
real StoreKit APIs with local products) and from Apple Sandbox (which exercises
Apple's commerce and receipt lifecycle). Test Store is for Nuxie Experience
qualification; use StoreKit Configuration or Sandbox before shipping native
commerce behavior.

SDK contributors can run the checked-in real StoreKitTest qualification suite
with `make test-storekit`; see [Native StoreKit qualification](docs/storekit-test-qualification.md).

### Purchases (optional)

StoreKit checkout works without configuration. Provide a purchase delegate only when
RevenueCat, Superwall, or your own billing stack should launch checkout:

```swift
import StoreKit

enum MyPurchaseError: Error {
  case productUnavailable
  case unknown
}

final class MyPurchaseDelegate: NuxiePurchaseDelegate {
  func purchase(product: StoreProduct) async -> PurchaseResult {
    // product.productId: Nuxie Product identity
    // product.placementId: the exact Experience Placement
    // product.storeProductId: App Store identifier
    // product.productType: consumable, non-consumable, or subscription type
    // product.rawProduct: the retained StoreKit.Product
    // product.storeKitPurchaseOptions: the exact StoreKit checkout options
    // product.introductoryOfferEligibilityJWS: fresh checkout-scoped JWS
    //
    // Custom StoreKit delegates use the retained product and exact options.
    guard let rawProduct = product.rawProduct else {
      return .failed(MyPurchaseError.productUnavailable)
    }
    do {
      switch try await rawProduct.purchase(
        options: product.storeKitPurchaseOptions
      ) {
      case .success(let verification):
        switch verification {
        case .verified:
          return .purchased
        case .unverified(_, let error): return .failed(error)
        }
      case .userCancelled: return .cancelled
      case .pending: return .pending
      @unknown default: return .failed(MyPurchaseError.unknown)
      }
    } catch {
      return .failed(error)
    }
  }

  func restorePurchases() async -> RestoreResult {
    do {
      try await AppStore.sync()
      for await result in Transaction.currentEntitlements {
        guard case .verified(let transaction) = result,
              transaction.revocationDate == nil,
              !transaction.isUpgraded else { continue }
        return .restored
      }
      return .noPurchases
    } catch {
      return .failed(error)
    }
  }
}
```

The delegate reports only `.purchased`, `.pending`, `.cancelled`, or `.failed`
and `.restored`, `.noPurchases`, or `.failed`. It never transports receipts,
transaction identifiers, or finish closures. Before a signed Connector cutover,
Nuxie's StoreKit listener may separately record and sync a verified native update;
`.observer` suppresses only Nuxie's finish call. Signed provider authority then
suppresses Nuxie's native receipt path, and the Connector synchronizes durable
state. Set
`purchaseHandlingMode = .observer` whenever the app or another SDK owns
StoreKit finishing; configuring a delegate does not silently change that
explicit choice.

Native checkout records the authenticated release, Experience, Placement,
Product, customer, and StoreKit account token before Apple opens checkout. The
transaction listener uses that protected record to recover a completed purchase
after process death without attributing it to whichever customer happens to be
active on relaunch. A separate protected account-token mapping retains only the
customer owner needed to attribute later renewals; it does not retain the
one-shot Experience or Placement context. An interrupted checkout may be
retried after its 15-minute recovery window, while an explicit Ask-to-Buy/SCA
pending result remains recoverable for 30 days. Purchase recovery, account
ownership, receipt evidence, and immediate local access are stored in separate
app, SDK-environment, and Test Store/App Store namespaces. Receipt/JWS retry
evidence is removed after backend acceptance and expires after 90 days; the
smaller StoreKit-reconciled local-access ledger does not retain receipt bytes.
For an outcome-only custom delegate without signed Connector authority, Nuxie
starts a 30-second exact-checkout window before invoking the delegate and
re-bounds it for 30 seconds after a successful callback. A crash while the
callback is suspended therefore cannot retain context for the ordinary pending
TTL. After the bound, the one-shot Experience/Placement context is retired; a
later verified update carrying Nuxie's deterministic account token still syncs
and finishes, but cannot resurrect stale Journey context or local grants.
Before delegate invocation, Nuxie also persists one checkout-scoped completion
ID. The callback and StoreKit observer both attempt to claim that same ID. The
winner durably captures Journey and analytics completion; the loser observes
that it is already complete and does nothing. The 30-second window helps
correlate a StoreKit update to the checkout, but this shared claim prevents
duplicates. Receipt synchronization and finishing remain separately
idempotent by StoreKit transaction ID. Capture or storage failure leaves recovery
retryable without turning a successful charge into a failed purchase result.

Fresh-device current-entitlement recovery uses authenticated Products from the
active release profile as receipt authority. A Product with signed Connector
Feature Access remains provider-owned even when local checkout history is
empty; an unsigned Product remains native StoreKit-owned. Conflicting active
Products for the same App Store identifier fail closed until release authority
converges, so Nuxie does not guess, sync, or finish the receipt.

### Atomic purchase-backed Feature use

`useFeatureAndWait` automatically uses one matching pending App Store receipt
when the signed Product mapping grants the requested Feature. The backend
accepts the receipt and records the requested usage as one atomic command, so a
new credit-wallet Product can fund its first transitive metered use without a
separate synchronization call. The returned `FeatureUsageResult.success`
describes that command; `authoritativeAccess` describes whether another use is
allowed afterward. Consuming the final credit therefore returns success with a
zero balance and `allowed == false`.

The receipt, purchasing identity, and stable `$purchase_synced` event remain
durable until that event has been captured. Transport, denial, or local capture
failure retains the bounded receipt evidence for an idempotent retry. The SDK
does not fall back to an ordinary usage request after attempting the atomic
command, and ambiguous receipts or unrelated Product mappings fail closed.

### Connected provider Feature Access

RevenueCat, Superwall, and custom billing delegates own checkout, their provider
reporting, transaction finishing, and durable subscription state. Importing a
provider entitlement into the Nuxie dashboard is initially evidence only. An
app builder must review the provider-to-Product mapping and explicitly enable
Nuxie Feature Access before the published Product contains a local access
mapping.

#### Before Connector cutover

The app keeps using its RevenueCat, Superwall, or custom-provider access checks.
A delegate success completes the purchase Journey but is not purchase evidence.
If StoreKit separately emits a verified update, Nuxie may sync it and apply the
authenticated Product's Boolean or unlimited local grants. Observer mode still
leaves finishing to the app or provider.

#### After Connector cutover

Signed provider authority suppresses Nuxie's native receipt sync and finish path.
That boundary gives the paywall the same immediate experience as the provider:
a successful delegate purchase can immediately expose the reviewed Boolean or
unlimited Feature locally, without waiting for Nuxie's backend. It does not invent
fixed quota or credit balances. Those remain server-authoritative and reconcile
through the configured provider Connector.

Add the matching maintained adapter source from `Examples/Adapters` to the app
target that already depends on RevenueCat or Superwall, then configure checkout:

```swift
configuration.purchaseHandlingMode = .observer
configuration.purchaseDelegate = NuxieRevenueCatPurchaseDelegate()

// Or:
configuration.purchaseHandlingMode = .observer
configuration.purchaseDelegate = NuxieSuperwallPurchaseDelegate()
```

A hand-written `NuxiePurchaseDelegate` can provide the same checkout result for
a custom billing stack. The delegate does not choose Feature Access: only the
reviewed mapping embedded in the signed Product can supply immediate local
Boolean grants. Durable subscription state, quotas, and credits still require
provider or Nuxie backend synchronization.

## Need Help?

- Learn more and get access at https://nuxie.ai

## License

Licensed under the terms in `LICENSE`.

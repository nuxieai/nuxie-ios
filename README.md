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
- Session tracking: automatic idle/lifetime rotation.
- Purchases: delegate‑based StoreKit integration for buy/restore.
- Automatic lifecycle events: $app_installed, $app_updated, $app_opened, and $app_backgrounded are always captured; `beforeSend` can drop them.
- Privacy & controls: sensitive-value log redaction and a `beforeSend` transform/drop hook.
- Offline-first, precisely: committed events are normally persisted locally before observers run and re-sent after relaunch (deduplicated server-side); a history-write failure advances the durable completeness fence so local evaluation fails closed instead of silently reasoning across a gap. Journey enrollment and feature-access decisions evaluate from cached config, so network failure degrades freshness, never function.
- Resilient Experiences: authenticated canonical plane profiles remain offline-usable without an age cutoff and revalidate opportunistically; legacy release profiles retain a 24-hour cache window. Verified release objects use a bounded 256 MiB disk LRU, speculative preparation respects Low Data Mode and app lifecycle, and StoreKit failures block only product-bound selected screens.

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
    config.environment = .production // or .development
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

Trigger an event for ordered Journey evaluation:

```swift
NuxieSDK.shared.trigger(
  "premium_feature_tapped",
  properties: ["feature": "pro_filters"]
)
```

Logout / clear identity:

```swift
NuxieSDK.shared.reset() // keepAnonymousId = false by default
```

## API Overview

- `NuxieSDK.shared.setup(with:)`: initialize the SDK (call once).
- `NuxieSDK.shared.identify(_:userProperties:userPropertiesSetOnce:)`: identify a user and set traits.
- `NuxieSDK.shared.trigger(_:properties:)`: capture an event for delivery and
  ordered Journey evaluation.
- `NuxieSDK.shared.reset(keepAnonymousId:)`: clear identity (e.g., logout).
- `NuxieSDK.shared.version`: current SDK version string.
- `NuxieSDK.shared.getDistinctId()`: current distinct ID (identified or anonymous).
- `try await NuxieSDK.shared.setLocaleIdentifier(_:)`: change the locale and
  refresh experience and feature state; the call completes with no return value.
- `NuxieSDK.shared.shutdown()`: tear down services (usually not needed).

### Experiences

- The experience engine owns presentation. Trigger matching and journey execution
  decide when an experience is shown; applications do not construct or present
  experience view controllers directly.
- `await NuxieSDK.shared.dismiss()`: dismisses the presented experience. It is a
  no-op when none is presented, waits for that experience's in-flight purchase or
  restore without interrupting StoreKit, and abandons its in-progress server-effect
  wait before dismissing. The Journey records the dismissal and resumes from its
  durable state when its authored policy allows it.
- On macOS, `target: "in_app"` link actions open in the default browser (no in-app Safari view).

## Configuration Highlights

Create with `NuxieConfiguration(apiKey:)` and optionally set:

- `environment`: `.production` (default) or `.development`.
- `testStoreEnabled`: the isolated, local-only purchase sheet (development +
  `pk_test_` key only).
- Logging: `logLevel`, `enableConsoleLogging`, `redactSensitiveData`.
- Locale: `localeIdentifier` for the initial locale; use
  `setLocaleIdentifier(_:)` for runtime changes.
- Hooks: `beforeSend` to transform or drop events, including the lifecycle
  events that the SDK always captures.
- Experience releases use the authenticated delivery origins supplied by the
  profile; applications cannot override signed object locations.
- Purchases: `purchaseDelegate` to handle StoreKit buy/restore in your app and
  `purchaseHandlingMode` to define transaction ownership.

Minimal example:

```swift
var config = NuxieConfiguration(apiKey: "NX_…")
config.environment = .production
config.beforeSend = { event in
  // Example: drop noisy dev events
  event.name.hasPrefix("dev_") ? nil : event
}
```

### Nuxie Test Store (development only)

Use the Test Store when qualifying a signed Experience, paywall copy, purchase
outcomes, restore branches, and Journey behavior without configuring App
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
successful test purchase emits the normal Experience/Journey purchase events
with `test_store: true`; it does not create verified StoreKit evidence and
therefore does not optimistically project Feature Access. It also does not call
StoreKit, a purchase delegate, the transaction listener, or a production
purchase endpoint.

This is different from an Xcode StoreKit Configuration file (which exercises
real StoreKit APIs with local products) and from Apple Sandbox (which exercises
Apple's purchase and receipt lifecycle). Test Store is for Nuxie Experience
qualification; use StoreKit Configuration or Sandbox before shipping native
purchase behavior.

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
        case .verified(let transaction):
          await transaction.finish()
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
transaction identifiers, or finish closures. Each `.purchased` callback is an
external declaration: Nuxie immediately advances the purchase Journey and
durably reports one `$purchase_completed` event with `source:
"external_delegate"` plus the authenticated Product and Placement mapping.
That event is the server carrier, not receipt evidence. It creates no evidence
row or optimistic Feature overlay and never asks StoreKit to finish anything.
A delegate `.restored` is handled the same way as an external declaration and
does not invoke Nuxie's native entitlement scanner. The host app or provider
continues to own checkout, restore, receipt submission, transaction finishing,
and durable billing state.

Native checkout records the authenticated release, Experience, Placement,
Product, customer, and StoreKit account token before Apple opens checkout. The
transaction listener uses that protected record to recover a completed purchase
after process death without attributing it to whichever customer happens to be
active on relaunch. A separate protected account-token mapping retains only the
customer owner needed to attribute later renewals; it does not retain the
one-shot Experience or Placement context. An interrupted checkout may be
retried after its 15-minute recovery window, while an explicit Ask-to-Buy/SCA
pending result remains recoverable for 30 days. Purchase recovery, account
ownership, and receipt evidence are stored in separate app, SDK-environment,
and Test Store/App Store namespaces. Receipt/JWS retry
evidence is removed after backend acceptance and expires after 90 days. While
that evidence is unreconciled, Feature Access is derived in memory from the
evidence and cached signed Product allowances; no separate access ledger is
persisted.

Verified StoreKit outcomes from checkout, the transaction stream, startup
recovery, and deferred updates enter one transaction committer. It deduplicates
by transaction identity, persists evidence, signals eligible Journey
advancement, refreshes the optimistic projection, and schedules backend receipt
synchronization in that order. The same transaction surfacing through several StoreKit paths
therefore produces one completion and one sync. External
delegate declarations enter the
same committer but deduplicate only per callback operation and bypass every
receipt and projection step.

Fresh-device current-entitlement recovery uses authenticated Products from the
active release profile as receipt authority. A Product with signed Connector
Feature Access remains provider-owned even when local checkout history is
empty; an unsigned Product remains native StoreKit-owned. Conflicting active
Products for the same App Store identifier fail closed until release authority
converges, so Nuxie does not guess, sync, or finish the receipt.

### Atomic purchase-backed Feature use

Ordinary `useFeatureAndWait` calls are durable too: the SDK journals the final
command before its first request and keeps one UUIDv7 operation id across
transport retry and relaunch. If the server accepted a request whose response
timed out, retry deduplicates the spend and the accepted result is mirrored
locally once.

When no active optimistic overlay can be derived, `useFeatureAndWait` can use
one matching pending App Store receipt when the signed Product mapping grants
the requested Feature. During active optimistic reconciliation it always uses
the ordinary durable command journal, so optimistic display never becomes
spend authority. The backend
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
Nuxie Feature Access before the published Product contains signed allowance
metadata.

#### Before Connector cutover

The app keeps using its RevenueCat, Superwall, or custom-provider access checks.
A delegate success immediately completes the purchase Journey and reports its
external `$purchase_completed` declaration, but is not purchase evidence.
Nuxie does not scan, sync, finish, or optimistically project StoreKit
transactions while an external purchase delegate owns billing.

#### After Connector cutover

A successful delegate purchase advances the purchase Journey, but it does not
create an optimistic Feature overlay. The configured provider Connector's
server snapshot is the first Nuxie Feature authority for Boolean, fixed-quota,
and credit access.

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
a custom billing stack. The delegate does not choose or immediately project
Feature Access. Provider- or Nuxie-synchronized server state supplies durable
subscription state, quotas, and credits.

## Need Help?

- Learn more and get access at https://nuxie.ai

## License

Licensed under the terms in `LICENSE`.

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
- Offline-first, precisely: every event is persisted locally before anything observes it and re-sent after relaunch (deduplicated server-side); journey enrollment and gate decisions evaluate from cached config, so network failure degrades freshness, never function.
- Resilient Experiences: authenticated profile snapshots remain offline-usable for 24 hours, verified release objects use a bounded 256 MiB disk LRU, speculative preparation respects Low Data Mode and app lifecycle, and StoreKit failures block only product-bound selected screens.

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

- `NuxieSDK.shared.experienceViewController(for:)`: asynchronously returns a
  view controller for a specific experience version, authenticating its signed
  release descriptor and acquiring its content-addressed RIV and assets on demand.
- `NuxieSDK.shared.showExperience(_:)`: presents an experience by version ID in
  a dedicated overlay window.
- On macOS, `target: "in_app"` link actions open in the default browser (no in-app Safari view).

Example (UIKit):

```swift
@MainActor
func debugExperience() async {
  do {
    let vc = try await NuxieSDK.shared.experienceViewController(
      for: "your_experience_version_id"
    )
    present(vc, animated: true)
  } catch {
    print("Failed to load experience: \(error)")
  }
}
```

## Configuration Highlights

Create with `NuxieConfiguration(apiKey:)` and optionally set:

- `environment`: `.production` (default), `.staging`, `.development`, `.custom` (+ `apiEndpoint`).
- `testStoreEnabled`: the isolated, local-only commerce sheet (development +
  `pk_test_` key only).
- Logging: `logLevel`, `enableConsoleLogging`, `redactSensitiveData`.
- Batching: `eventBatchSize`, `flushAt`, `flushInterval`, `maxQueueSize`,
  `retryCount`, and `retryDelay`.
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
    // product.introductoryOfferEligibilityJWS: fresh JWS for provider APIs
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
          return .purchasedWithStoreKitEvidence(.init(
            transactionJws: verification.jwsRepresentation,
            transactionId: String(transaction.id),
            originalTransactionId: String(transaction.originalID),
            productId: transaction.productID,
            finish: { await transaction.finish() }
          ))
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
      return .storeKitRestored
    } catch {
      return .failed(error)
    }
  }
}
```

Return `.providerPurchased`/`.providerRestored` only when an external provider
owns receipt submission and durable access. A custom StoreKit delegate returns
verified evidence and `.storeKitRestored`; Nuxie records, syncs, and finishes
that StoreKit work. Use
`purchaseHandlingMode = .observer` only when the app owns purchases without a delegate.

Native checkout records the authenticated release, Experience, Placement,
Product, customer, and StoreKit account token before Apple opens checkout. The
transaction listener uses that protected record to recover a completed purchase
after process death without attributing it to whichever customer happens to be
active on relaunch. A separate protected account-token mapping retains only the
customer owner needed to attribute later renewals; it does not retain the
one-shot Experience or Placement context. An interrupted checkout may be
retried after its 15-minute recovery window, while an explicit Ask-to-Buy/SCA
pending result remains recoverable for 30 days. Purchase recovery, account
ownership, receipt evidence, and optimistic local access are stored in separate
app, SDK-environment, and Test Store/App Store namespaces. Receipt/JWS retry
evidence is removed after backend acceptance and expires after 90 days; the
smaller StoreKit-reconciled local-access ledger does not retain receipt bytes.

### Connected provider Feature Access

RevenueCat, Superwall, and custom billing delegates remain the owners of their
receipts, transaction finishing, and durable subscription state. Importing a
provider entitlement into the Nuxie dashboard is initially evidence only. An
app builder must review the provider-to-Product mapping and explicitly enable
it as a Nuxie Boolean Feature before the published Product contains a local
Feature Access mapping.

That boundary gives the paywall the same optimistic experience as the provider:
a successful delegate purchase can immediately expose the reviewed Boolean
Feature locally, without waiting for Nuxie's backend. It does not invent quota
or credit balances. Those remain provider/server-authoritative and reconcile
through the configured provider connector. Before explicit enablement, a
delegate success still completes the purchase Journey but grants no Nuxie
Feature Access.

## Need Help?

- Learn more and get access at https://nuxie.ai

## License

Licensed under the terms in `LICENSE`.

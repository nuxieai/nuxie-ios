<p align="center">
  <a href="https://nuxie.ai" target="_blank" rel="noopener">
    <img alt="Nuxie" src="https://nuxie.ai/favicon-192.png" width="64" height="64" />
  </a>
</p>

<div align="center">
  <strong>Nuxie Apple SDK</strong>
  <br />
  Bring targeted in‑app Experiences, paywalls, and analytics to your iOS or macOS app.
  <br /><br />
  <a href="https://nuxie.ai" target="_blank" rel="noopener">Website</a>
</div>

---

## What is Nuxie?

Nuxie is a platform for running targeted in‑app experiences such as paywalls, upgrade prompts, surveys, and more — without shipping new app releases. This SDK connects your iOS or macOS app to Nuxie so you can track events, identify users, and automatically present experiences configured in the Nuxie dashboard. An Experience holds the screens and authored route graph. At runtime, a Journey advances across device and server work; this SDK executes armed device work delivered by the authenticated profile.

Learn more at https://nuxie.ai

## Features

- Event tracking: send custom events with properties and user traits.
- User identity: anonymous IDs, `identify`, and event linking on login.
- Experiences: signed screens and armed Journey work that present in-app UI from the authenticated profile.
- Session tracking: automatic idle/lifetime rotation.
- Purchases: delegate‑based StoreKit integration for buy/restore.
- Automatic lifecycle events: $app_installed, $app_updated, $app_opened, and $app_backgrounded are always captured; `beforeSend` can drop them.
- Privacy & controls: sensitive-value log redaction and a `beforeSend` transform/drop hook.
- Offline-first, precisely: committed events are normally persisted locally before observers run and re-sent after relaunch (deduplicated server-side); a history-write failure advances the durable completeness fence so local evaluation fails closed instead of silently reasoning across a gap. Armed Journey work and feature-access reads use authenticated cached profile state, so network failure degrades freshness without discarding already-delivered behavior.
- Resilient Experiences: authenticated canonical plane profiles remain offline-usable without an age cutoff and revalidate opportunistically. Verified Journey releases use a bounded 256 MiB disk LRU, speculative preparation respects Low Data Mode and app lifecycle, and StoreKit failures block only product-bound selected screens.

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

### Link events

Links use the same state table for runtime hrefs and Journey steps. A settled, owned
Experience opens web links in-app from its topmost controller for an omitted target,
`_self`, `_parent`, `_top`, or `in_app`. `_blank` and `external` use the browser.
Closing, closed, and screenless Experiences use the browser or system for every link.
Background apps open and record nothing. Non-web schemes go to the system only when
available. Broken Journey link steps advance without opening, recording, or dismissing.
`$link_opened` and the public `linkOpened` activity include the actual `destination`
(`in_app` or `external`) and the original optional `target`. Successful Journey links
record under the step identity before `$journey_leg_completed`.
A link already in flight still opens externally after identity change or current-customer profile clear, but its revoked run records no event.

## Requirements

- iOS 15+
- macOS 12+ for non-rendering SDK behavior
- Swift 5.9+ language support; iOS source builds require Xcode 27.1+ for the UIKit hinge APIs.

The iOS deployment target remains 15+. Hinge observation runs on iOS 27.1+
and supplies unavailable values on earlier systems. See
[runtime environment](docs/runtime-environment.md) for the fold contract.

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
- Dependency Rule: Up to Next Major Version, starting at `1.0.0`
- Add the `Nuxie` product to your app target

Each SDK release pins an immutable runtime release URL and checksum. Swift
Package Manager downloads that runtime automatically; app builds do not compile Rust.

Experiences use authenticated Journey routes, named screen actions, and declared
buffered outputs. Unsupported descriptors and actions are rejected.

Or via `Package.swift`:

```swift
dependencies: [
  .package(url: "https://github.com/nuxieai/nuxie-ios", from: "1.0.0")
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
    let config = NuxieConfiguration(apiKey: "pk_test_…") // pk_live_… only in App Store builds
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
    let config = NuxieConfiguration(apiKey: "pk_test_…") // pk_live_… only in App Store builds
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

- `environment`: the Nuxie service, `.production` by default. Keep the default
  for every build, including Debug and TestFlight: the publishable key, not the
  service environment, selects test or live content and purchases. Nuxie
  accepts Sandbox and Xcode StoreKit transactions only with a `pk_test_` key and
  App Store transactions only with a `pk_live_` key. TestFlight purchases are
  Sandbox purchases, so build TestFlight uploads with the test key even though
  they use a Release configuration.
- `testStoreEnabled`: the Nuxie Test Store purchase sheet (a `pk_test_` key in
  a Debug build only).
- Logging: `logLevel`, `enableConsoleLogging`, `redactSensitiveData`.
- Locale: `localeIdentifier` for the initial locale; use
  `setLocaleIdentifier(_:)` for runtime changes.
- Hooks: `beforeSend` to transform or drop events, including the lifecycle
  events that the SDK always captures.
- Journey releases use the authenticated delivery origins supplied by the
  profile; applications cannot override signed object locations.
- Purchases: `purchaseDelegate` to handle StoreKit buy/restore in your app and
  `purchaseHandlingMode` to define transaction ownership.

Minimal example:

```swift
let config = NuxieConfiguration(apiKey: "pk_test_…")
config.beforeSend = { event in
  // Example: drop noisy dev events
  event.name.hasPrefix("dev_") ? nil : event
}
```

### Nuxie Test Store (Debug builds)

Use the Test Store when qualifying a signed Experience, paywall copy, purchase
outcomes, restore branches, Feature access and Journey behavior without
configuring App Store products or charging an account:

```swift
let config = NuxieConfiguration(apiKey: "pk_test_demo")
#if DEBUG
config.testStoreEnabled = true
#endif
try NuxieSDK.shared.setup(with: config)
```

It works on the default service with the test key, like RevenueCat's Test
Store. Setup refuses it with a `pk_live_` key or in a Release build, which
includes TestFlight and App Store builds.

The sheet is deliberately branded `Nuxie Test Store` and says that it creates
no StoreKit transaction. It offers explicit Purchased, Pending, Cancelled, and
Failed outcomes, plus Restored, No Purchases, and Failed restore outcomes.
Purchased asks Nuxie to grant the Product's Features to the customer, so access
unlocks at once and stays on the server like a real purchase; if Nuxie cannot
grant it, the purchase fails. The grant records no transaction and never counts
as revenue, and it has no end: test again with a new customer. A successful test
purchase emits the normal Experience/Journey purchase events with
`test_store: true`. It never calls StoreKit, a purchase delegate, or the
transaction listener.

This is different from an Xcode StoreKit Configuration file (which exercises
real StoreKit APIs with local products) and from Apple Sandbox (which exercises
Apple's purchase, renewal and receipt lifecycle). Test Store is for Nuxie
Experience qualification; use StoreKit Configuration or Sandbox before shipping
native purchase behavior.

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
That event carries no transaction and grants no Feature or goal conversion.
It creates no evidence row or optimistic Feature overlay and never asks
StoreKit to finish anything.
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
ownership, and receipt evidence are stored in separate app, key-mode (test or
live), and Test Store/App Store namespaces. The StoreKit account token uses the
same app, key mode and store mode, which is how the server recognizes the
purchase's customer; the service environment takes no part. Receipt/JWS retry
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

### Provider checkout and planned Feature Access

RevenueCat, Superwall, and custom billing delegates own checkout, their provider
reporting, transaction finishing, and durable subscription state. Today, the
RevenueCat and Superwall webhook Connectors feed only Automations and
server-side Journeys. They grant no Feature access.

#### Current behavior

The app keeps using its RevenueCat, Superwall, or custom-provider access checks.
A delegate success immediately completes the purchase Journey and reports its
external `$purchase_completed` declaration, but is not purchase evidence.
Nuxie does not scan, sync, finish, or optimistically project StoreKit
transactions while an external purchase delegate owns billing. Features do
not change and no goal converts from that purchase.

#### Planned support (UNIV-5244)

After the Basis TestFlight build, the planned work will capture the signed
store transaction on the device after a delegate reports purchased and send
it to the purchase authority without finishing it. The Connectors will also
be rebuilt to keep access current. This support is not available today.

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
Feature Access. Keep using the provider's access checks until the planned
purchase-authority and Connector support is available.

## Need Help?

- Learn more and get access at https://nuxie.ai

## License

Licensed under the terms in `LICENSE`.

### Reuse native products in wrapper CI

Set `NUXIE_SDK_PREPARE_PRODUCTS=1` on a policy-v2 Buildkite build to export the
existing native artifact contract after the SDK checks pass. Download the
`output/pipeline/native-products/ios-products.tar.gz` artifact for wrapper builds.
The archive preserves the original `sdk-artifacts.json`, file hashes and symlinks;
wrapper native pins must match its source revision.
The archive contains both Debug and Release products for iOS devices and simulators.

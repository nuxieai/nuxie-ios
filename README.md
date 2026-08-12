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
  `.nux` package on demand.
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
- Logging: `logLevel`, `enableConsoleLogging`, `redactSensitiveData`.
- Batching: `eventBatchSize`, `flushAt`, `flushInterval`, `maxQueueSize`,
  `retryCount`, and `retryDelay`.
- Hooks: `beforeSend` to transform or drop events.
- Experience packages: `packageAssetBaseURL` can override the profile asset
  base URL for local development.
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

### Purchases (optional)

Provide a purchase delegate if your flows include purchases:

```swift
import StoreKit

final class MyPurchaseDelegate: NuxiePurchaseDelegate {
  func purchase(_ product: any StoreProductProtocol) async -> PurchaseResult {
    // Integrate with StoreKit here
    return .success
  }

  func restore() async -> RestoreResult {
    // Restore previous purchases
    return .noPurchases
  }
}
```

## Need Help?

- Learn more and get access at https://nuxie.ai

## License

Licensed under the terms in `LICENSE`.

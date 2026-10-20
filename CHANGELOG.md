# Changelog

Each SDK release is a git tag named `X.Y.Z` with a section here. The newest
release is at the top. [RELEASING.md](RELEASING.md) describes how a release is
made.

## 0.1.0 (unreleased)

The first tagged release of the Nuxie iOS SDK. Apps that followed the `main`
branch can move to a version rule; before 1.0 we recommend Xcode's "Up to Next
Minor Version" rule from 0.1.0, because a new minor version may break.

### Requirements

- iOS 15 deployment target. macOS 12 for the parts that do not render:
  events, identity, configuration, and networking.
- Xcode 27.1 or newer to build for iOS (SwiftPM builds the SDK from source,
  and it uses the UIKit hinge APIs). Swift 5.9 or newer.
- Nuxie runtime `apple-runtime-v0.10.16`, a published
  [nuxie-runtime](https://github.com/nuxieai/nuxie-runtime) release. The
  package pins its `NuxieRuntime.xcframework.zip` by URL and checksum, so this
  SDK version always resolves that runtime build.

### What it includes

- One entry point, `NuxieSDK.shared`: `setup(with:)`, `identify`, `trigger`,
  `reset`, `dismiss`, `setLocaleIdentifier`, `version`, and `shutdown`.
- Events kept in an on-device SQLite log and sent in batches. Events not yet
  delivered are sent again after a relaunch, and their idempotency keys let
  the server drop duplicates. `$app_installed`, `$app_updated`, `$app_opened`,
  and `$app_backgrounded` are always captured, and `beforeSend` can change or
  drop any event. Logs can redact sensitive values.
- Journeys and Experiences: the SDK admits a signed Journey profile, checks
  each signed release, runs its device work, and presents its screens
  (paywalls, onboarding, surveys) through the Nuxie runtime. Applications do
  not present Experience screens themselves.
- Purchases through StoreKit with no setup, or through a
  `NuxiePurchaseDelegate` when RevenueCat, Superwall, or your own billing runs
  checkout. Adapter sources for RevenueCat and Superwall are in
  `Examples/Adapters`. The Nuxie Test Store sheet tests purchase outcomes in
  development without StoreKit.
- Feature access through `features`, `hasFeature`, `useFeature`, and
  `useFeatureAndWait`. Usage commands keep one operation id across retries and
  relaunches.
- Offline use: a profile that was already authenticated keeps working without
  the network, and checked releases are kept in a disk cache of up to 256 MiB.

### Known limits

- Experiences render on iOS only. macOS apps get events, identity,
  configuration, and networking.
- Apps moving to this version from an earlier SDK commit must republish their
  Experiences in the current shape. Release descriptors and actions in an
  older shape fail closed; there are no compatibility decoders.

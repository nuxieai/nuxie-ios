# Nuxie iOS SDK — Public API Surface

This document is the prose companion to the executable contract in
`fixtures/` (the conformance vectors are authoritative for semantics; this
file explains the surface). The public surface below is the **wrapper
contract**: React Native, Flutter, Unity, and Unreal bind to exactly these
entry points, so every addition or change here fans out across six
platforms. Pre-1.0, breaking changes are allowed and are batched so
integrators break once.

All entry points live on the `NuxieSDK.shared` singleton facade.

## Lifecycle

| Entry point | Semantics |
| --- | --- |
| `setup(with: NuxieConfiguration) throws` | Builds the composition root and starts the SDK. Must be called before anything else; throws on an empty API key or a `.custom` environment without an explicit `apiEndpoint`. Calling twice is a warning no-op. |
| `shutdown() async` | Drains queued identity transitions, shuts down journeys, closes the event log (workers drain deterministically), and drops the object graph. Normally unnecessary. |
| `delegate: NuxieDelegate?` | Feature-access change callbacks. |
| `version: String` | SDK version. |

## Events & triggers

The single user-facing event entry point is `trigger` — it tracks the event
(durably: persisted pending before anything else observes it), evaluates
matching experiences, and may present UI.

| Entry point | Semantics |
| --- | --- |
| `trigger(_:properties:userProperties:userPropertiesSetOnce:handler:)` | Fire-and-forget. The optional handler observes progressive `TriggerUpdate`s (gate decisions, journey lifecycle, entitlement outcomes) for this trigger only. |
| `triggerAndWait(...) async -> TriggerResult` | Same, awaiting the terminal result. Wire encoding of `TriggerResult` is pinned by `fixtures/encodings/trigger-result.json`. |
| `flushEvents() async -> Bool` | Force delivery of the pending queue. |
| `getQueuedEventCount() async -> Int` | Pending delivery-queue size. |
| `pauseEventQueue()` / `resumeEventQueue()` | Suspend/resume automatic delivery (manual flush still works — identity ordering relies on it). |

Event names starting with `$` are reserved for the SDK ($identify,
$app_opened, $journey_*, $flow_*, $purchase_*, $session_*). The full
catalog — when each internal event fires, its properties, and delivery
guarantees — is `docs/sdk-events.md`.

## Identity & sessions

| Entry point | Semantics |
| --- | --- |
| `identify(_:userProperties:userPropertiesSetOnce:)` | Transition to a known user. Transitions are strictly FIFO and uncancellable; local event history migrates on anonymous→identified. Same-id identify is a no-op. |
| `reset(keepAnonymousId: Bool = false)` | Log out. Rotates the anonymous id by default. |
| `getDistinctId()` / `getAnonymousId()` / `isIdentified` | Current identity accessors. |
| `getCurrentSessionId() -> String?` | Read-only session accessor (30-minute idle / 24-hour max rotation is automatic). |

## Experiences

An **Experience** is the server-configured unit the SDK runs: the journey
definition plus the screens (riv bundle) plus StoreKit product enrichment. A
**Journey** is a runtime run of an experience for a user. Journeys execute
client-side from cached config — offline enrollment works and `$journey_start`
rides the durable event queue.

| Entry point | Semantics |
| --- | --- |
| `showExperience(_:from:)` | Present an experience by id. |
| `experienceViewController(for:) async throws` | Embedding: returns the presentable view controller without presenting. |
| `refreshProfile() async throws -> ProfileResponse` | Re-fetch cached config (experiences, segments, features). The SDK also refreshes automatically. |

## Features (entitlements)

| Entry point | Semantics |
| --- | --- |
| `features: FeatureInfo` | Observable (SwiftUI-friendly) feature-access snapshot. |
| `hasFeature(_:requiredBalance:entityId:policy:)` | Check access. `FeatureCheckPolicy.cacheFirst` answers locally and never blocks on the network; `.remote` forces a round trip. |
| `useFeature(...)` / `useFeatureAndWait(...)` | Record consumption of a metered feature. |

## Configuration

`NuxieConfiguration` carries only functional options: `apiKey`,
`environment`/`apiEndpoint`, delivery tuning (`flushAt`, `flushInterval`,
`eventBatchSize`, `maxQueueSize`, `retryCount`, `retryDelay`),
`trackApplicationLifecycleEvents`, `purchaseHandlingMode` (`.full` default /
`.observer` — observer mode never finishes transactions the host app owns),
`beforeSend` (drop/transform events pre-capture), logging and redaction
controls, and `customStoragePath`.

## Delivery guarantees (what "offline-first" means precisely)

- Every tracked event is persisted to SQLite marked pending **before** the
  network, journeys, or segments observe it; delivery acks flip it to
  delivered. Kill the app at any point and undelivered events send on next
  launch, deduplicated server-side by the event's UUIDv7 idempotency key.
- Journey enrollment, segment evaluation, and gate decisions evaluate from
  cached config; network failure degrades freshness, never function.

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

Journey updates use experience vocabulary throughout:
`JourneyRef` and `JourneyUpdate` expose `experienceId` and
`experienceVersion`, and the presentation decision is
`TriggerDecision.experienceShown`.

Event names starting with `$` are reserved for the SDK ($identify,
$app_opened, $journey_*, $experience_*, $purchase_*, $session_*). The full
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
client-side from cached config after the synchronous `$journey_enrolled` fact
is accepted. If that decision request fails, the SDK does not create a local
run whose server ledger is missing.

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
controls, `customStoragePath`, and `packageAssetBaseURL` (a development
override for the profile-delivered content-addressed asset base URL).

## Delivery guarantees (what "offline-first" means precisely)

- Every tracked event is persisted to SQLite marked pending **before** the
  network, journeys, or segments observe it; delivery acks flip it to
  delivered. Kill the app at any point and undelivered events send on next
  launch, deduplicated server-side by the event's UUIDv7 idempotency key.
- Ordinary trigger events remain durable while offline. Journey enrollment
  and gate decisions use the synchronous decision lane; segment membership is
  an authoritative server mirror delivered by profile snapshots.

## Experiences: enrollment and profile state

Journey execution events are internal analytics protocol details; no
application-facing tracking API changed. Profile down-facts and server-owned
segment membership seeds are decoded and applied internally.

`ProfileResponse.experiences` is the flat `RemoteExperience` wire model: every
item contains enrollment settings plus one signed-package pointer
(`artifact.url`, SHA-256, size, and package version). Journey content is never
delivered inline; it is decoded from the authenticated package after download.
`ProfileResponse.assetBaseUrl` resolves external content-addressed assets, and
`pinnedVersions` carries the same pointer shape for persisted or
mailbox-offered journeys. `timeLimitSeconds` is preserved on the hydrated
`Experience`.

Response-capture networking identifies the run as `journeyId` and sends
`journey_id`; `ResponseRecordPayload` exposes the same `journeyId`. The removed
`journeySessionId` / `journey_session_id` shape is not dual-supported.

## Experiences: server effects

There is no new application-facing API. Published experiences may contain server-effect actions. The SDK durably emits `$journey_effect_requested`, keeps the current screen presented while it waits, and consumes `$journey_effect_completed` from the ordinary event/profile down-fact channel. Completion properties are available to authored result bindings; failure and no-answer are distinct authored outcomes. Effect payloads support the normal structured value references plus persisted journey-context references shaped as `{ "ref": { "kind": "context", "path": "customer.email" } }`.

## Experiences: server-owned runs and handoff

`Experience.trigger` is now optional. This is an intentional pre-1.0 source
change: profiles include server-owned experiences so the SDK can render a
mailbox-claimed device region, but omit their server-only webhook or API
trigger configuration. Integrators that inspect `refreshProfile().experiences`
must unwrap `experience.trigger` before switching on or reading it. A missing
trigger means the experience cannot enroll from a local SDK event; it may still
start after the server offers and acknowledges a mailbox claim.

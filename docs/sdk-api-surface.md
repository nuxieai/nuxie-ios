# Nuxie iOS SDK — Public API Surface

This document is the prose companion to the executable contracts in
`fixtures/`, `api/public-api.txt`, and `api/public-api-ios.txt` (the
conformance vectors are authoritative for semantics; the platform API
allowlists are authoritative for exported declarations; this file explains
the surface). The public surface below is the **wrapper
contract**: React Native, Flutter, Unity, and Unreal bind to exactly these
entry points, so every addition or change here fans out across six
platforms. Pre-1.0, breaking changes are allowed and are batched so
integrators break once.

All entry points live on the `NuxieSDK.shared` singleton facade.

## Module boundary

Only the facade, configuration/delegate types, values appearing in facade
signatures, and the package-authored experience schema are supported public
API. Networking clients and response DTOs, persistence stores, service
protocols, query adapters, evaluators, clocks, and mutable journey runtime
state are implementation details. Tests use `@testable import Nuxie` when they
need those seams; applications must not construct or depend on them.

`make check-public-api` builds the macOS and iOS modules and applies two
platform checks: an exact declaration inventory plus Swift API Digester's
native source-compatibility diagnosis. The native baselines preserve details
such as protocol conformances and default arguments that declaration names do
not capture. An intentional API change therefore requires both code review and
an explicit baseline update with
`scripts/check-public-api.sh --update`.

Published releases carry behavior through authenticated routes, execution
plans, screen behaviors, and response sessions. `JourneyDocument` exposes
only the canonical package-authored journey schema; runtime behavior and
persistence remain private implementation details.

## Lifecycle

| Entry point | Semantics |
| --- | --- |
| `setup(with: NuxieConfiguration) throws` | Builds the composition root and starts the SDK. Must be called before anything else; throws on an empty API key or a `.custom` environment without an explicit `apiEndpoint`. Calling twice is a warning no-op. |
| `shutdown() async` | Drains queued identity transitions, shuts down journeys, closes the event log (workers drain deterministically), and drops the object graph. Normally unnecessary. |
| `delegate: NuxieDelegate?` | Feature-access change callbacks. |
| `isSetup: Bool` | Whether `setup(with:)` has completed and the facade has a live composition root. |
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
| `pauseEventQueue() async` / `resumeEventQueue() async` | Suspend/resume automatic delivery (manual flush still works — identity ordering relies on it). |

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
| `showExperience(_:colorSchemeMode:) async throws` | Present an experience by id, optionally overriding its color scheme. |
| `experienceViewController(for:colorSchemeMode:) async throws` | Embedding: returns the presentable view controller without presenting. |
| `refreshProfile() async throws -> ProfileResponse` | Re-fetch cached config (experiences, segments, features). The SDK also refreshes automatically. |

## Features (entitlements)

| Entry point | Semantics |
| --- | --- |
| `features: FeatureInfo` | Observable (SwiftUI-friendly) feature-access snapshot. |
| `hasFeature(_:requiredBalance:entityId:policy:)` | Check access. `FeatureCheckPolicy.cacheFirst` answers locally and never blocks on the network; `.remote` forces a round trip. |
| `useFeature(...)` / `useFeatureAndWait(...)` | Record consumption of a metered feature. When exactly one pending native purchase can fund the requested feature, `useFeatureAndWait` submits verification, grant, and first use as one idempotent command. A product that grants a credit system can fund a mapped metered feature; the SDK selects only from the authenticated release's signed direct and credit-schema targets, while the server independently verifies the current product and credit-system relationship. |

`FeatureUsageResult.success` means the usage command committed. It does not
mean that another use remains available. For an atomic purchase-backed use,
`authoritativeAccess` is the post-use state, so consuming the final finite
credit returns `success == true` together with
`authoritativeAccess.allowed == false` and a zero balance. Ordinary usage
responses leave `authoritativeAccess` nil.

Atomic purchase-backed failures retain the scoped receipt evidence and retry
with the same purchase-use event identity. A decoded successful response
retires the evidence before emitting one `$purchase_synced`; it does not fall
back to an ordinary post-request feature-use event.

## Configuration

`NuxieConfiguration` carries only functional options: `apiKey`,
`environment`/`apiEndpoint`, delivery tuning (`flushAt`, `flushInterval`,
`eventBatchSize`, `maxQueueSize`, `retryCount`, `retryDelay`),
`trackApplicationLifecycleEvents`, `purchaseHandlingMode` (`.full` default /
`.observer` — observer mode never finishes transactions the host app owns),
`beforeSend` (drop/transform events pre-capture), logging and redaction
controls, `featureCacheTTL`, `localeIdentifier`, `customStoragePath`, and
`purchaseDelegate`. For development-only commerce qualification,
`testStoreEnabled` requires a `pk_test_` key and `.development` environment;
it uses Nuxie's isolated no-charge Test Store instead of StoreKit or a
purchase delegate.

Setup validates delivery tuning before publishing any SDK state. Batch,
automatic-flush, and queue counts must be within `1...Int32.max`, and the
automatic flush threshold cannot exceed queue capacity. `retryCount` controls
how many failure attempts increase exponential backoff before its delay caps;
it does not stop later delivery attempts and must be nonnegative. `retryDelay`
must be finite and nonnegative. `flushInterval` and
`featureCacheTTL` must be finite and greater than zero, and configured
timer/backoff values must fit Swift concurrency's nanosecond scheduling range.
Invalid values fail setup with `NuxieError.invalidConfiguration` naming the
offending field.

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

`ProfileResponse.releases` is the sole experience-delivery authority. The SDK
authenticates and admits every exact inline descriptor envelope before behavior
can participate in routing, then acquires the standalone RIV and every referenced
content-addressed asset or script. Active entries are eligible for enrollment;
pinned entries remain available only for exact persisted or mailbox restoration.
`timeLimitSeconds` is preserved on the hydrated `Experience`.

Descriptor delivery follows a fixed resilience policy:

- A fully authenticated profile snapshot may launch offline for up to 24 hours
  from its recorded fetch time. Expired snapshots are evicted before any
  release behavior is installed; an unavailable refresh leaves signed
  experience authority empty rather than falling back to stale content.
- Content-addressed RIV, asset, and listener-script objects are retained in a
  256 MiB on-disk LRU. Verified cache hits refresh recency. Pruning runs under
  the cache's root transaction and protects every object in the release being
  assembled; memory pressure drops decoded/prepared state before verified disk
  objects.
- Profile warming is speculative: it does not opt into constrained networking,
  is cancelled while the application is backgrounded, and is rearmed on the
  next active transition. A foreground presentation may retry failed preload
  work with presentation network policy.
- StoreKit lookup is deferred until the signed journey has selected a screen.
  It blocks reveal only when that screen's authenticated root view model binds
  product data; current StoreKit name, price, and period replace publisher-time
  catalog display values before the native runtime opens.

`WindowUnit.second` is public so an authenticated `once_per_window` reentry
policy can preserve publisher-authored whole-second windows without rounding.

Response-capture networking identifies the run as `journeyId` and sends
`journey_id`; `ResponseRecordPayload` exposes the same `journeyId`. The removed
`journeySessionId` / `journey_session_id` shape is not dual-supported.

## Experiences: server effects

There is no new application-facing API. Published experiences may contain server-effect actions. The SDK durably emits `$journey_effect_requested`, keeps the current screen presented while it waits, and consumes `$journey_effect_completed` from the ordinary event/profile down-fact channel. Completion properties are available to authored result bindings; failure and no-answer are distinct authored outcomes. Effect payloads support the normal structured value references plus persisted journey-context references shaped as `{ "ref": { "kind": "context", "path": "customer.email" } }`.

## Experiences: server-owned runs and handoff

`Experience.trigger` is optional. Profiles include server-owned experiences so
the SDK can render a
mailbox-claimed device region, but omit their server-only webhook or API
trigger configuration. A missing trigger means the experience cannot enroll
from a local SDK event; it may still start after the server offers and
acknowledges a mailbox claim.

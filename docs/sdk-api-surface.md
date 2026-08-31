# Nuxie iOS SDK — Public API Surface

This document is the prose companion to the executable contracts in
`fixtures/`, the customer API allowlists (`api/public-api.txt` and
`api/public-api-ios.txt`), and the separate SPI allowlists (`api/spi-api.txt`
and `api/spi-api-ios.txt`). The conformance vectors are authoritative for
semantics; the platform API allowlists are authoritative for exported
declarations; this file explains the surface. The public surface below is the
**wrapper contract**: React Native, Flutter, Unity, and Unreal bind to exactly
these entry points, so every addition or change here fans out across six
platforms. Pre-1.0, breaking changes are allowed and are batched so integrators
break once.

All entry points live on the `NuxieSDK.shared` singleton facade.

## Module boundary

The supported public contract is the facade; configuration and delegates;
feature and trigger-result values; the presentation types returned by the
facade; and the commerce types used by the purchase seam. Signed release-wire,
journey-document, view-model, and IR representations are internal alongside
networking clients and response DTOs, persistence stores, service protocols,
query adapters, evaluators, clocks, and mutable journey runtime state. Tests
use `@testable import Nuxie` when they need those seams; applications must not
construct or depend on them.

`make check-public-api` builds the macOS and iOS modules and applies two
platform checks: an exact declaration inventory plus Swift API Digester's
native source-compatibility diagnosis. The native baselines preserve details
such as protocol conformances and default arguments that declaration names do
not capture. Customer inventories and digester baselines exclude every
`@_spi` declaration. SPI declarations are tracked in their own platform
inventories so SPI growth remains visible, but SPI is not a supported customer
contract; native source-compatibility diagnosis therefore applies to the
customer digest only. An intentional API change requires both code review and
an explicit baseline update with `scripts/check-public-api.sh --update`.

Published releases carry behavior through authenticated routes, execution
plans, screen behaviors, and response sessions. The SDK authenticates and
decodes that wire format internally; applications interact with the resulting
behavior only through the supported facade and delegate seams.

## Lifecycle

| Entry point | Semantics |
| --- | --- |
| `setup(with: NuxieConfiguration) throws` | Builds the composition root and starts the SDK. Must be called before anything else; throws on invalid configuration, including an empty API key. Calling twice is a warning no-op. |
| `shutdown() async` | Drains queued identity transitions, shuts down journeys, closes the event log (workers drain deterministically), and drops the object graph. Normally unnecessary. |
| `delegate: NuxieDelegate?` | Main-actor feature-access, activity-forwarding, and Run App Action callbacks. |
| `isSetup: Bool` | Whether `setup(with:)` has completed and the facade has a live composition root. |
| `version: String` | SDK version. |

## Events & triggers

The single user-facing event entry point is `trigger` — it tracks the event
(durably: persisted pending before anything else observes it), evaluates
matching experiences, and may present UI.

| Entry point | Semantics |
| --- | --- |
| `trigger(_:properties:handler:)` | Fire-and-forget. The optional handler observes progressive `TriggerUpdate`s (experience decisions and journey lifecycle) for this trigger only. |
| `triggerAndWait(_:properties:progress:) async -> TriggerResult` | Same, awaiting the terminal result. Its Testing-SPI wire encoding is pinned by `fixtures/encodings/trigger-result.json`. |

`ExperienceRef` carries `experienceId`, `experienceVersion`, and an optional
`journeyId`; `JourneyUpdate` carries the completed journey identity.
`TriggerResult` reports `.noMatch`, `.journeyCompleted`, or `.error` for the
current journey-routing path.
`TriggerError.code` is a typed `TriggerError.Code`.

Designer-authored Run App Action steps arrive through
`NuxieDelegate.nuxie(_:didRequestAppAction:)`; see
[Run App Action](run-app-action.md).

Durably captured, curated SDK activity arrives through
`NuxieDelegate.nuxieDidEmit(_:)`; see
[Forward Nuxie activity to your analytics tool](forward-nuxie-activity.md).

Event names starting with `$` are reserved for the SDK ($identify,
$app_opened, $journey_*, $experience_*, $purchase_*). The canonical machine
catalog, covering when each internal event fires, its properties, and delivery
guarantees, is `fixtures/events/catalog.json`; its human-readable view is
`docs/events-catalog.md`.

The local event database is not a lifetime analytics store. Delivered history
is retention-bounded, and authored lifetime conditions that require an exact
answer fail closed when only that retained window is available. Lower-bounded
conditions are deterministic only when their complete window is inside the
reported durable, monotonic horizon. Retention deletion advances that horizon
in the same transaction; failed history writes fence the gap, while corrupt
property payloads, query saturation, or storage failure also fail closed. See
`docs/event-history-semantics.md` for the query-by-query contract and current
v1 schema guidance.

## Identity & sessions

| Entry point | Semantics |
| --- | --- |
| `identify(_:userProperties:userPropertiesSetOnce:)` | Transition to a known user. Transitions are strictly FIFO and uncancellable; local event history migrates on anonymous→identified. Same-id identify is a no-op. |
| `reset(keepAnonymousId: Bool = false)` | Log out. Rotates the anonymous id by default. |
| `getDistinctId()` / `getAnonymousId()` / `isIdentified` | Current identity accessors. |

## Experiences

An **Experience** is the server-configured unit the SDK runs: the journey
definition plus the screens (riv bundle) plus StoreKit product enrichment. A
**Journey** is a runtime run of an experience for a user. Journeys execute
client-side from cached config after the synchronous `$journey_enrolled` fact
is accepted. If that decision request fails, the SDK does not create a local
run whose server ledger is missing.

The experience engine owns presentation. Trigger matching and journey execution
decide when an experience is shown; applications do not obtain an experience
view controller or present an experience by version ID.

| Entry point | Semantics |
| --- | --- |
| `dismiss() async` | Callable from any task. Dismiss the presented experience; no-op if none is presented. It waits for that experience's in-flight purchase or restore without interrupting StoreKit, abandons its in-progress server-effect wait, then exits the journey as dismissed. `$journey_exited` carries `reason: "dismissed"` and `dismissed_by: "host"`; a pending `triggerAndWait` resolves to `TriggerResult.journeyCompleted` with `JourneyUpdate.exitReason == .dismissed`. |

## Features (feature access)

| Entry point | Semantics |
| --- | --- |
| `features: FeatureInfo` | Observable (SwiftUI-friendly) feature-access snapshot. |
| `FeatureInfo.state` | Snapshot readiness: `.unknown` before a profile is admitted, `.reconciling` while verified StoreKit evidence widens visible access, and `.ready` once no optimistic purchase overlay remains. |
| `hasFeature(_:requiredBalance:entityId:policy:)` | Check access. `FeatureCheckPolicy.cacheFirst` answers locally and never blocks on the network; `.remote` forces a round trip. |
| `useFeature(...)` / `useFeatureAndWait(...)` | Record consumption of a metered feature. Ordinary `useFeatureAndWait` persists a stable command before sending and reuses its operation id across same-process and relaunch retry. During an active optimistic purchase overlay it always uses that durable command journal, and any local decrement affects only the visible joined value. Without an active overlay, exactly one pending native purchase can instead submit verification, grant, and first use as one idempotent command. A product that grants a credit system can fund a mapped metered feature; the SDK selects only from the authenticated release's signed direct and credit-schema targets, while the server independently verifies the current product and credit-system relationship. |

`FeatureUsageResult.success` means the usage command committed. It does not
mean that another use remains available. For an atomic purchase-backed use,
`authoritativeAccess` is the post-use state, so consuming the final finite
credit returns `success == true` together with
`authoritativeAccess.allowed == false` and a zero balance. Ordinary usage
responses leave `authoritativeAccess` nil.

An ambiguous ordinary usage result remains in the command journal. Relaunch or
an explicit retry sends the same operation id, and an accepted durable result
is reconciled into `$feature_used` history once. Its balance projection is
applied only when it is at least as fresh as the latest admitted profile
snapshot. Commands for the same feature and optional entity apply in capture
order. A retryable older command defers younger local projection for that target
without blocking its delivery or caller completion; other targets are
independent. A feature-not-found response retires the command, surfaces the
server's 404 outcome, and is not replayed. The journal is scoped to the host app
and selected Nuxie environment.

Atomic purchase-backed failures retain the scoped receipt evidence and retry
with the same purchase-use event identity. A decoded successful response
retires the evidence before emitting one `$purchase_synced`; it does not fall
back to an ordinary post-request feature-use event.

## Configuration

`NuxieConfiguration` carries only customer-facing functional options: `apiKey`
(supplied to `init(apiKey:)`), `environment` (`.production` or `.development`),
`logLevel`, `enableConsoleLogging`, `redactSensitiveData`, `localeIdentifier`,
`beforeSend`, `testStoreEnabled`, `purchaseDelegate`, and
`purchaseHandlingMode` (`.full` default / `.observer` — observer mode never
finishes transactions the host app owns). For development-only commerce
qualification, `testStoreEnabled` requires a `pk_test_` key and `.development`
environment; it uses Nuxie's isolated no-charge Test Store instead of StoreKit
or a purchase delegate.

Application lifecycle events are always captured. `beforeSend` is the escape
hatch for applications that need to transform or drop those events before
they are persisted and delivered.

`setLocaleIdentifier(_:) async throws` changes the runtime locale, refreshes
the profile, and synchronizes feature state. It completes with `Void`.

Console logging treats every interpolated value as sensitive by default. With
`redactSensitiveData` enabled, identifiers, response bodies, paths,
caller-supplied values, and error descriptions are replaced by stable
HMAC-SHA-256 summaries for the life of the process. Error types and explicitly
annotated structure such as HTTP status codes remain visible. Setting
`redactSensitiveData` to `false` is an explicit diagnostic opt-in that can emit
those raw values.

## Delivery guarantees (what "offline-first" means precisely)

- Every tracked event is persisted to SQLite marked pending **before** the
  network, journeys, or segments observe it; delivery acks flip it to
  delivered. Kill the app at any point and undelivered events send on next
  launch, deduplicated server-side by the event's UUIDv7 idempotency key.
- Ordinary trigger events remain durable while offline. Journey enrollment
  and feature-access decisions use the synchronous decision lane; segment
  membership is an authoritative server mirror delivered by profile snapshots.

## Experiences: enrollment and profile state

Journey execution events are internal analytics protocol details; no
application-facing tracking API changed. Profile down-facts and server-owned
segment membership seeds are decoded and applied internally.

The internal profile release set is the sole experience-delivery authority.
The SDK authenticates and admits every exact inline descriptor envelope before
behavior can participate in routing, then acquires the standalone RIV and every
referenced content-addressed asset or script. Active entries are eligible for
enrollment; pinned entries remain available only for exact persisted or mailbox
restoration. The authored time limit is preserved on the internal hydrated
experience model.

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

The internal reentry-window wire preserves publisher-authored whole-second
`once_per_window` durations without rounding.

Response-capture networking identifies the run as `journeyId` and sends
`journey_id`; `ResponseRecordPayload` exposes the same `journeyId`. The removed
`journeySessionId` / `journey_session_id` shape is not dual-supported.

## Experiences: server effects

There is no new application-facing API. Published experiences may contain server-effect actions. The SDK durably emits `$journey_effect_requested`, keeps the current screen presented while it waits, and consumes `$journey_effect_completed` from the ordinary event/profile down-fact channel. Completion properties are available to authored result bindings; failure and no-answer are distinct authored outcomes. Effect payloads support the normal structured value references plus persisted journey-context references shaped as `{ "ref": { "kind": "context", "path": "customer.email" } }`.

## Experiences: server-owned runs and handoff

The internal hydrated experience trigger is optional. Profiles include
server-owned experiences so the SDK can render a
mailbox-claimed device region, but omit their server-only webhook or API
trigger configuration. A missing trigger means the experience cannot enroll
from a local SDK event; it may still start after the server offers and
acknowledges a mailbox claim.

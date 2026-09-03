# Nuxie iOS SDK — Public API Surface

This document explains the customer-facing SDK contract. The declaration
inventories in `api/public-api.txt` and `api/public-api-ios.txt` are the
executable source of truth for exported API. The corresponding `spi-api`
inventories cover test and companion SPI only.

The SDK is pre-1.0. The current API intentionally exposes one Journey system;
there is no compatibility surface for the deleted runtime.

## Module boundary

Applications configure and use the `NuxieSDK.shared` facade. Journey profiles,
signed Journey releases, fact tables, execution plans, journals, render models,
network DTOs, and persistence stores are internal implementation details.
Applications do not construct Journey objects or select release versions.

`make check-public-api` builds the macOS and iOS modules, compares the exact
declaration inventories, and runs Swift API Digester against the checked-in
customer baselines. Intentional API changes update those baselines with
`scripts/check-public-api.sh --update` after review.

## Lifecycle

| Entry point | Semantics |
| --- | --- |
| `setup(with: NuxieConfiguration) throws` | Validates configuration, builds the object graph, restores durable work, and starts profile, event, feature, purchase, and Journey services. Calling it again while configured is a warning no-op. |
| `shutdown() async` | Stops Journey execution, drains SDK-owned work, closes persistence, and drops the object graph. Most applications do not call it. |
| `delegate: NuxieDelegate?` | Receives feature changes, curated SDK activity, and authored Run App Action requests. |
| `isSetup: Bool` | Whether the facade has a live object graph. |
| `version: String` | SDK version. |

## Events

`trigger(_:properties:)` is the only customer event entry point. It is
fire-and-forget: the event is durably committed to the ordered EventLog and the
Journey service evaluates that committed event. There is no per-trigger result,
progress callback, or synchronous decision API.

Designer-authored Run App Action steps arrive through
`NuxieDelegate.nuxie(_:didRequestAppAction:)`; see
[Run App Action](run-app-action.md). Curated SDK activity arrives through
`NuxieDelegate.nuxieDidEmit(_:)`; see
[Forward Nuxie activity to your analytics tool](forward-nuxie-activity.md).

Names beginning with `$` are reserved for SDK events. The canonical event list,
properties, emitter, and delivery semantics live in
`fixtures/events/catalog.json`, with a prose view in
[`events-catalog.md`](events-catalog.md).

Delivered event history is retention-bounded. Exact lifetime queries fail
closed if retained history cannot prove an answer; bounded queries are valid
only inside the durable coverage horizon. See
[`event-history-semantics.md`](event-history-semantics.md).

## Identity

| Entry point | Semantics |
| --- | --- |
| `identify(_:userProperties:userPropertiesSetOnce:)` | Enqueues a FIFO transition to a known user. Anonymous event history migrates during the transition. Re-identifying the current distinct ID is a no-op. |
| `reset(keepAnonymousId: Bool = false)` | Logs out and normally rotates the anonymous ID. |
| `getDistinctId()` / `getAnonymousId()` / `isIdentified` | Read the current identity. |

## Journeys

A Journey is the sole client-side experience program and runtime. The server
delivers one exact `nuxie.journey-plane-profile.v1` document containing:

- the complete fact table required by the delivered programs;
- enrollment arms and exact continuation bindings;
- inline signed Journey releases; and
- render and asset base URLs.

The SDK validates the whole profile before publishing any part of it. It then
authenticates each signed release, verifies every arm-to-release reference, and
admits the snapshot atomically for one app, environment, and identity. A
previously authenticated snapshot remains the offline execution authority
without an age cutoff while refresh is unavailable.

Committed events may start eligible Journeys from their authored entry
conditions. Each run pins its authenticated release and durable journal. A
Journey executes local conditions, timers, controls, effects, presentation,
and outputs without a second routing system. Only authored park points survive
process death; an interrupted active run otherwise closes from its durable
state. Stable `$journey_leg_started` and `$journey_leg_completed` facts report
the client-owned execution boundary to the server.

Experiments always choose an authored outcome. A valid assignment selects its
variant. A missing, malformed, or unavailable assignment selects the signed
`fallbackVariantId`; it never skips the experiment or abandons the Journey.
Exposure is emitted only when the selected variant is actually revealed.

The presentation engine owns Journey UI. Applications do not receive an
experience view controller or request a release by version.

| Entry point | Semantics |
| --- | --- |
| `dismiss() async` | Dismisses the currently presented Journey UI, if any. It waits for in-flight purchase work that must finish safely and then lets the Journey continue through its authored dismissal outcome. |

## Features

| Entry point | Semantics |
| --- | --- |
| `features: FeatureInfo` | Observable, SwiftUI-friendly feature snapshot. |
| `FeatureInfo.state` | `.unknown` before profile admission, `.reconciling` while verified purchase evidence affects the visible projection, and `.ready` after reconciliation. |
| `hasFeature(_:requiredBalance:entityId:policy:)` | Checks access. `.cacheFirst` reads admitted local state; `.remote` requests current server authority. |
| `useFeature(...)` | Starts an authoritative metered-usage command in the background. |
| `useFeatureAndWait(...)` | Persists the command, waits for its authoritative result, and returns `FeatureUsageResult`. |

Feature-use commands keep a stable operation ID across ambiguous delivery and
relaunch recovery. Commands for the same feature and optional entity reconcile
in capture order. `FeatureUsageResult.success` means the command committed; it
does not promise that another unit remains available.

When one pending native purchase can fund the requested feature, the SDK may
verify the purchase, grant access, and consume the first unit as one idempotent
command. Signed Journey product mappings constrain the client choice and the
server verifies the relationship independently.

## Configuration

`NuxieConfiguration` is a mutable setup builder. `setup(with:)` snapshots it;
later mutations do not reconfigure a running SDK.

Customer options are:

- `apiKey` and `environment`;
- `logLevel`, `enableConsoleLogging`, and `redactSensitiveData`;
- `localeIdentifier`;
- `beforeSend` for transforming or dropping events before persistence;
- `testStoreEnabled` for isolated development purchase qualification;
- `purchaseDelegate`; and
- `purchaseHandlingMode` (`.full` or `.observer`).

`setLocaleIdentifier(_:)` changes the runtime locale, invalidates the old
locale claim, refreshes the canonical profile, and synchronizes feature state.
`setPurchaseDelegate(_:)` and `setPurchaseHandlingMode(_:)` update future
purchase behavior.

A configured purchase delegate owns its checkout flow. Its completed and
restored callbacks become external purchase declarations; those paths do not
create StoreKit evidence or finish StoreKit transactions. In native StoreKit
mode, `.full` lets Nuxie finish verified transactions after durable sync and
`.observer` leaves finishing to the host.

Application lifecycle events are captured by default. `beforeSend` may
transform or drop any event, including SDK-authored lifecycle events. Identity
fields are pinned by the SDK and cannot be changed by the hook.

With sensitive-data redaction enabled, interpolated identifiers, payloads,
paths, caller values, and error descriptions become process-stable keyed
digests in console output. Disabling redaction is an explicit diagnostic opt-in.

## Offline and delivery guarantees

- EventLog commits accepted events locally before network delivery or Journey
  evaluation. Pending events retry after relaunch with their stable event IDs.
- A fully authenticated canonical Journey profile can execute offline. The SDK
  revalidates opportunistically and atomically replaces it only after the new
  profile passes transport authority, exact-shape, signature, linkage, and
  replay checks.
- Content-addressed render, asset, and script objects are hash-verified and
  cached on disk. A Journey pins the release it started with.
- Journey outcomes are buffered durably and reported through stable completion
  facts. Network failure does not create a second local execution path.

There is no legacy profile decoder, legacy Journey runtime, alternate trigger
service, ownership mailbox, response session, or compatibility alias in the
SDK.

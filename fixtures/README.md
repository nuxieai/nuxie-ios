# Portable SDK fixtures

These JSON vectors define the contracts shared by SDK implementations.

## Published runtime values

- `runtime/screen-exit-reason/`: published dismissed-only and field-absent scenes for optional exit-reason binding, navigation skipping, and the retained terminal pose over the default screen backing.
- `runtime/paywall-selection/`: portable compiled product-ID tap and signed link setup, with native feedback/read-back proof.
- `runtime/paywall-catalog-selection/` and `runtime/paywall-placement-selection/`: real `valueFrom` taps from the annual child; catalog remapping and placement selection of two rows with one product are SDK-native assertions. They do not establish normal publication or checkout.
- `journeys/planes/file-paywall-selection.json`: file-made flat rows, dynamic purchase reference, signed identities and at-open cases with duplicate product IDs or a different baked root ID.

- `runtime/published-input/`: F3 input and greeting from publisher `09081fd6591bb5f24c33693d0b06a7c3a207ea65`. Preserves the published text-input table, source, behavior oracle and provenance. The native input handler runs on the advance after the text changes; no authored key handler or emit is present. Native field delivery and signed release admission require separate platform proof.
- `runtime/emit-values/`: the parent's `tools/sdk-fixtures/emit-values`, published through its `publish_folder` example. One screen whose emits read a value from state (beside a payload field named `screenId`), a repeated row's item, a copy's output, an action's value, a value set before the send and one cleared after it, and a row of `experience.goals` that removes its own item. Platform tests play it through the real Journey and check each emit's values and the parked run's values; the points and values are in its `NOTES.md` (D2.54).
- `runtime/await-values/`: the parent's `tools/sdk-fixtures/await-values`, published through its `publish_folder` example. One screen whose copy calls its action with a number, a choice, a text and a yes or no, and whose handler awaits a save before emitting them. Platform tests make two calls before the first save is confirmed and check that each confirmation goes on with its own call's values, which the save keeps in `keep:<value>` paths and the SDK writes back before it fires the save's trigger; the points and values are in its `NOTES.md` (spec decision 120).
- `runtime/run-values/`: F4 tap and level screens from publisher `97d23aae674d8035ffda773cefdf936f85a1ea46`, with unchanged source, handwritten expectations and file hashes. Platform tests check native `continue` admission in a signed Journey, write-before-route ordering and the component copy's first drawn pixels. The published event has no action id; the test release keeps its control table empty.
- `runtime/state-rules/`: SDK-authored rules on values in `state`, carried in the optional top-level `stateRules` list. Every state rule refuses; `refused` cases must fail validation, and `engine` writes `trip_days` on the F4 screen against a minimum and a maximum.

## Journey

- `journeys/planes/release.json`: signed Journey release envelopes and canonical release schema.
- `journeys/planes/admission.json`: release admission, authenticated identity, controls, render closure, boundary outputs, and host-dismiss safety.
- `journeys/planes/conversion-delivery.json`: original Journey start and revisioned conversion context on continuation arms.
- `journeys/planes/conversion-watch.json`: attribution across retained watches, explicit-context rejection, inclusive windows, equal-time ordering, and occurrence-time admission.
- `journeys/planes/profile-fact-admission.json`: exact signed fact projection across multiple legs of one publication, including missing and extra delivered keys.
- `journeys/planes/publication-admission.json`: identical publication replay, equal-sequence conflicts and newer publication admission.
- `journeys/planes/entry-evaluation.json`: profile fact, membership, event-edge, foreground, and unknown-value admission.
- `sdk/early-event-admission.json`: an event starts from the copy installed when it is handled, never dropped for being captured under an earlier copy or before the first one; it never starts another customer's Journey. iOS consumes it in `JourneyEarlyEventAdmissionTests`.
- `sdk/held-event-time.json`: on first launch, onboarding_started at 0 ms starts a wait at 0 ms when the first copy lands at 800 ms; the held plan_viewed at 100 ms takes its satisfied outlet, including a 500 ms wait already overdue at replay. Catch-up timeouts wait for held follow-up events to replay. An event-started run runs behind the handling clock by how late its event was handled (never ahead) until it first parks. iOS consumes it in `JourneyEarlyEventAdmissionTests.testHeldEventTimeVectors`.
- `sdk/committed-event-timeout-order.json`: timeouts query undelivered committed events by customer and inclusive deadline without draining the queue. A trigger at 0 ms handled at 800 ms starts a 1000 ms wait; preparation finishes at 1200 ms, but the follow-up committed at 900 ms still takes satisfied. Without a queued follow-up, the same wait promptly times out. Delivery completion rechecks any timeouts that event blocked, including when its wait evaluation finished before the deadline. Screenless background events can resolve expired checkpoints; pending-route read failures receive a bounded retry. iOS consumes the vectors in `JourneyEarlyEventAdmissionTests.testQueuedLiveEventTimeoutVectors`, with delivery-completion, background and retry coverage in the same test class.
- `sdk/refetch-event-hold.json`: while a customer has no usable copy (withdrawn after a language change in the app) and a fetch of it runs, their events wait, then replay against the copy that lands before any wait is resolved. The hold lasts until a copy lands or their last running fetch settles; then the events go through without a copy. Even an empty active hold blocks timeouts; its release catches up expired waits after replay. With no fetch nothing waits. iOS consumes it in `JourneyRefetchEventHoldTests`.
- `journeys/planes/occurrence-evaluation.json`: occurrence queries, aggregates, predicates, windows, and unknown propagation.
- `journeys/planes/history-coverage.json`: retained-history horizons, gaps, pending captures, restart, and known-empty windows.
- `journeys/planes/executor-controls.json`: waits, routes, experiments, authored fallback selection, and terminal controls.
- `journeys/planes/run-recovery.json`: park-point recovery, abandonment, pending report retry, and delivered generation handling.
- `journeys/planes/reports.json`: stable start/completion reports, declared outputs, privacy drops, retries, and forwarding names.
- `journeys/planes/values.json`: exact JSON value resolution and three-valued conditions.
- `journeys/planes/presentation-readiness.json`: show readiness (cold, prepared, built) from the reserved release's verified bytes and native preparation (both are required, and a release missing an optional object is never kept), shimmer only when cold, and a reservation held until the show ends. iOS consumes it in `ExperienceShellPresentationChromeTests` and `JourneyPreparedReleaseStoreTests`.

The signed release fixture is the only release wire shape. Tests consume it directly and never rebuild a retired runtime model.

- `journeys/planes/text-input-typography.json`: native multiline font size and baseline intervals, natural line-height sentinel, contain/geometry scaling, and restyling invariants. Consumers compare actual native layout with independently configured platform controls.

## Events

- `events/catalog.json`: every reserved event, property contract, capture path, emitter, and forwarding decision.
- `events/batch-item-encoding.json`: canonical batch encoding and idempotency identity.
- `events/delivery-disposition.json`: retry, authentication, split, partial acknowledgement, and poison-event handling.
- `events/generated-control-routing.json`: generated native controls cannot be forged by ordinary analytics payloads.
- `events/atomic-purchase-sync.json`: stable purchase synchronization identity, evidence retention, and retry ordering.
- `events/runtime-event-sources.json` (version 2): whose event it is comes from the runtime's report alone. The source carries the alias of the native instance that reported the event; a property named `instanceId` is the author's value, sent as written, and never changes or rejects the source (the data plan's phone events step, D2.54).
- `events/runtime-event-values.json`: an emit's values as the editor and Preview send them. A literal property goes under its name; a text property named `$<field>` names a path in the screen's root view model (names joined by `/`, never split at dots), and the text, number or yes or no there goes under `<field>`. No `$` property is sent itself, and a number is its shortest decimal (D2.54).

## Public values and adjacent subsystems

- `encodings/app-action.json`, `encodings/feature-usage.json`, and `encodings/forwarded-activity.json`: public Codable and forwarding contracts.
- `encodings/feature-consumption.json`: `/feature/consume` commands and receipts, including App Store evidence with camelCase `customerKind` (`identified` or `anonymous`) frozen at consume admission. Ordinary consumes and retries reconstructed from legacy evidence with no recorded kind omit it, including after sign-in. iOS consumes it in `FeatureConsumptionApiTests`; the upgrade retry is covered through `useFeatureWithPendingPurchase` in `PurchaseBackedFeatureUsageTests` and `TransactionEvidencePersistenceOrchestrationTests`.
- `features/optimistic-entitlement-projection.json`: authoritative feature state combined with retained purchase evidence.
- `features/command-recovery.json`: persisted server cooldowns and active-session retry eligibility for durable Feature commands.
- `purchases/app-store-intro-eligibility.json`: iOS-owned App Store eligibility. Unavailable forced eligibility uses automatic terms for display and checkout without an override; an active subscription in the group blocks automatic intro terms. iOS consumes it in the App Store intro eligibility fixture runner in `TransactionServiceTests`.
- `purchases/outcome-commit.json`: one purchase outcome committer across StoreKit and host-delegate sources.
- `purchases/purchase-outbox.json`: the purchase outbox contract (`docs/purchase-outbox.md`): what each producer sends (`reason`, `customer_kind`, requester), how each server answer clears or keeps an entry and refetches the profile, the retry backoff, and the Restore outcome. iOS consumes it in `PurchaseOwnershipClaimTests`.
- `purchases/app-account-token.json`: the StoreKit `appAccountToken` for each key mode and StoreKit environment. The server derives the same value to decide who owns a purchase; the SDK's service environment takes no part. iOS consumes it in `AppAccountTokenFixtureTests`; nuxie-dev's connectors tests read the same file.
- `ir/eval-vectors.json` and `ir/response-field-conformance.json`: expression and buffered-response evaluation used by Journey controls.

- `runtime/forms-saves/goals/`: F5 goals from publisher `81fa73c87f0638d151d0a4082fbcab1cd61ec73c`. The unchanged source and oracle qualify ordered native list snapshot/recovery. SDK timed-wait persistence remains its own proof; this fixture has no row-remove event, forms or saves.

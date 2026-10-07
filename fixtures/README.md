# Portable SDK fixtures

These JSON vectors define the contracts shared by SDK implementations.

## Published runtime values

- `runtime/published-input/`: F3 input and greeting from publisher `09081fd6591bb5f24c33693d0b06a7c3a207ea65`. Preserves the published text-input table, source, behavior oracle and provenance. The native input handler runs on the advance after the text changes; no authored key handler or emit is present. Native field delivery and signed release admission require separate platform proof.
- `runtime/run-values/`: F4 tap and level screens from publisher `97d23aae674d8035ffda773cefdf936f85a1ea46`, with unchanged source, handwritten expectations and file hashes. Platform tests check native `continue` admission in a signed Journey, write-before-route ordering and the component copy's first drawn pixels. The published event has no action id; the test release keeps its control table empty.

## Journey

- `journeys/planes/release.json`: signed Journey release envelopes and canonical release schema.
- `journeys/planes/admission.json`: release admission, authenticated identity, controls, render closure, boundary outputs, and host-dismiss safety.
- `journeys/planes/conversion-delivery.json`: original Journey start and revisioned conversion context on continuation arms.
- `journeys/planes/conversion-watch.json`: attribution across retained watches, explicit-context rejection, inclusive windows, equal-time ordering, and occurrence-time admission.
- `journeys/planes/profile-fact-admission.json`: exact signed fact projection across multiple legs of one publication, including missing and extra delivered keys.
- `journeys/planes/publication-admission.json`: identical publication replay, equal-sequence conflicts and newer publication admission.
- `journeys/planes/entry-evaluation.json`: profile fact, membership, event-edge, foreground, and unknown-value admission.
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

## Public values and adjacent subsystems

- `encodings/app-action.json`, `encodings/feature-usage.json`, and `encodings/forwarded-activity.json`: public Codable and forwarding contracts.
- `features/optimistic-entitlement-projection.json`: authoritative feature state combined with retained purchase evidence.
- `features/command-recovery.json`: persisted server cooldowns and active-session retry eligibility for durable Feature commands.
- `purchases/outcome-commit.json`: one purchase outcome committer across StoreKit and host-delegate sources.
- `ir/eval-vectors.json` and `ir/response-field-conformance.json`: expression and buffered-response evaluation used by Journey controls.

- `runtime/forms-saves/goals/`: F5 goals from publisher `81fa73c87f0638d151d0a4082fbcab1cd61ec73c`. The unchanged source and oracle qualify ordered native list snapshot/recovery. SDK timed-wait persistence remains its own proof; this fixture has no row-remove event, forms or saves.

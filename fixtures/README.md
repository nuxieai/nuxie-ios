# Portable SDK fixtures

These JSON vectors define the contracts shared by SDK implementations.

## Journey

- `journeys/planes/release.json`: signed Journey release envelopes and canonical release schema.
- `journeys/planes/admission.json`: release admission, authenticated identity, controls, render closure, boundary outputs, and host-dismiss safety.
- `journeys/planes/entry-evaluation.json`: profile fact, membership, event-edge, foreground, and unknown-value admission.
- `journeys/planes/occurrence-evaluation.json`: occurrence queries, aggregates, predicates, windows, and unknown propagation.
- `journeys/planes/history-coverage.json`: retained-history horizons, gaps, pending captures, restart, and known-empty windows.
- `journeys/planes/executor-controls.json`: waits, routes, experiments, authored fallback selection, and terminal controls.
- `journeys/planes/run-recovery.json`: park-point recovery, abandonment, pending report retry, and delivered generation handling.
- `journeys/planes/reports.json`: stable start/completion reports, declared outputs, privacy drops, retries, and forwarding names.
- `journeys/planes/values.json`: exact JSON value resolution and three-valued conditions.

The signed release fixture is the only release wire shape. Tests consume it directly and never rebuild a retired runtime model.

## Events

- `events/catalog.json`: every reserved event, property contract, capture path, emitter, and forwarding decision.
- `events/batch-item-encoding.json`: canonical batch encoding and idempotency identity.
- `events/delivery-disposition.json`: retry, authentication, split, partial acknowledgement, and poison-event handling.
- `events/generated-control-routing.json`: generated native controls cannot be forged by ordinary analytics payloads.
- `events/atomic-purchase-sync.json`: stable purchase synchronization identity, evidence retention, and retry ordering.

## Public values and adjacent subsystems

- `encodings/app-action.json`, `encodings/feature-usage.json`, and `encodings/forwarded-activity.json`: public Codable and forwarding contracts.
- `features/optimistic-entitlement-projection.json`: authoritative feature state combined with retained purchase evidence.
- `purchases/outcome-commit.json`: one purchase outcome committer across StoreKit and host-delegate sources.
- `ir/eval-vectors.json` and `ir/response-field-conformance.json`: expression and buffered-response evaluation used by Journey controls.

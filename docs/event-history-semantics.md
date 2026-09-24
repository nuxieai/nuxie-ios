# Event-history semantics

Nuxie persists events locally before downstream observers see them. That
durability guarantee applies to the delivery queue; it does not make the device
database a complete lifetime analytics record.

## Coverage model

An event-query source explicitly reports one of two coverage states:

- `complete`: the source guarantees that it can answer lifetime queries over
  all relevant history. Test fixtures and a future server-backed source may
  make this guarantee.
- `retainedWindow(startingAt:)`: the source guarantees its local history only
  at or after a concrete timestamp. A query is exact only when its authored
  lower bound is at or after that timestamp.

Production `EventLog` always reports a retained window backed by durable SQLite
metadata. A fresh database establishes its starting timestamp at the first SDK
open. The boundary survives process restarts and is cleared only when the event
database itself is reset. The current schema is v3. A verified v2 store upgrades
transactionally while retaining event and purchase evidence; unsupported or
malformed layouts are rejected without mutation.

The boundary is monotonic. Age and count retention advance it only when rows
are actually removed, and the deletion plus metadata update commit in one
SQLite transaction. Count pruning moves it one persisted timestamp tick past
the newest removed row so equal timestamps cannot straddle a claimed window.
Rows awaiting network or local subscriber delivery are never reaped. If an old
pending row is acknowledged later, the
retention pass either deletes it and atomically preserves/advances the boundary,
or leaves both history and boundary unchanged. Wall-clock rollback cannot move
the persisted boundary backward.

If the SDK knows about an event but its history write fails, it first moves a
process-local boundary past that event and then persists the same fence. A
recovered store therefore remains fail closed after relaunch. If the event write
and the fence write both fail at the storage layer, the process-local fence is
still safe for the current run, but no implementation can promise that fence
survives process death; this simultaneous failure is logged as a durability
fault.

A fresh install, identity history from another device, and previously pruned or
failed rows are outside this local-history contract.

## Event delivery and Feature commands

Ordinary capture creates one canonical `NuxieEvent`, persists it as pending,
and sends it through batch delivery. Its UUIDv7 remains the wire
`idempotency_key` across retries. Stable Journey and system facts use the same
store and batch transport under a producer-supplied id; the producing state
machine advances only after durable capture. Renderer response controls update
the Journey journal directly and do not enter EventLog.

Local subscriber delivery records preserve eligibility captured with the event
and the next subscriber to retry. Ordinary capture, stable capture, and batches
write that metadata in the same transaction as their events. A refused event
holds later deliveries in capture order; the worker retains the current retry
and loads durable followers one at a time. A single ordinary-event cache keeps
fresh capture usable through transient history-query failures. Events that
cannot persist use a best-effort buffer limited by `maxQueueSize`; additional
unpersisted events are dropped with a warning when that buffer is full.

Process-local subscriber authority is discarded on the next SDK open. Stable
route receipts and the conversion inbox survive independently: retained stable
routes recover under authenticated current Journey state, while discovering
old event or purchase history does not create a new conversion. Network
acknowledgement alone never releases an event still awaiting local delivery.

Ordinary `useFeatureAndWait` calls use a separate v1 Feature-command journal,
not an undelivered history row. The final command is written atomically before
its first send, and its UUIDv7 operation id is reused as the wire idempotency
key for every retry. The decoded response is made durable before local
reconciliation. An accepted command is mirrored into delivered history under
the operation id; duplicate reconciliation observes the existing row, so
forwarding remains at-most-once. Journals are isolated by an opaque host-app
identity and Nuxie environment so a command cannot cross backend scopes. The
pre-GA command journal is created directly at its final v1 shape and has no
migration reader.

## Authored-query behavior

Lifetime event queries have no lower bound (`since` and `within` are absent).
When their source reports `retainedWindow(startingAt:)`, conditions that
require an exact lifetime answer are **unknown** inside the interpreter:

- existence and count;
- first/last occurrence and last age;
- numeric aggregates;
- ordered sequences;
- stopped/restarted behavior.

The public journey/segment runtime converts that unknown result to a
fail-closed `false` for the complete authored expression. Unknown propagates
through comparisons and nested predicate values before boolean operators are
applied, so `not(unknown)` also fails closed rather than becoming `true`.

A lower bound (`since`, `within`, or the implicit calendar start of an
active-period query) is deterministic only when the entire window starts at or
after the source's reported horizon. The interpreter checks coverage both
before and after the storage query so retention advancing during evaluation
cannot produce a definitive answer from a newly incomplete snapshot.

Predicate evaluation, aggregates, sequences, and other row-scanning queries
read at most 10,000 same-name rows. They fetch one sentinel row beyond that
limit; observing the sentinel makes the result unknown instead of evaluating a
truncated prefix. A coverage lookup or event-store query failure is handled the
same way. Event-property JSON is decoded strictly on every IR path that uses
properties; malformed payloads are unknown rather than an empty object (which
could otherwise make `is_not_set` authorize). Predicate-free SQL counts are not
row-limited, but still require a fully covered window and a successful store
query.

## Schema and authoring guidance

`event_history_metadata` is part of the complete schema v3, alongside stable
route receipts, the conversion inbox, and process-scoped subscriber delivery.
Fresh-store table creation, required-column and index verification, and the
`user_version = 3` write occur in one transaction. The singleton coverage row is established when
`EventLog` first opens that fresh store and its monotonic `coverage_start_ms` is
preserved across reopen. An empty unversioned database is initialized; a
nonempty unversioned store, v1 store, unknown future version, or malformed
supported schema is rejected without mutation. The verified v2-to-v3 upgrade
adds delivery and conversion metadata without replaying historical events as
new conversions. Database reset
remains the only operation that intentionally discards the watermark.

After this change, an existing unbounded condition may stop qualifying on a
device where earlier SDK versions produced a definitive answer from truncated
history. This is intentional: a retained subset must not authorize an
experience based on a false lifetime conclusion.

Authors should add a meaningful `since` or `within` bound when the product rule
is genuinely window-based, and keep that window within the device retention
contract. Merely supplying a large lower bound does not make the answer exact.
Rules that require exact cross-device or lifetime analytics need a query source
that can explicitly guarantee `complete` coverage; the on-device log does not
provide that guarantee.

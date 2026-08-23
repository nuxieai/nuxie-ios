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
database itself is reset. Databases that do not exactly match the current v1
schema are rejected; the SDK has no legacy event-store reader or migration path.

The boundary is monotonic. Age and count retention advance it only when rows
are actually removed, and the deletion plus metadata update commit in one
SQLite transaction. Count pruning moves it one persisted timestamp tick past
the newest removed row so equal timestamps cannot straddle a claimed window.
Pending rows are never reaped. If an old pending row is acknowledged later, the
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

`event_history_metadata` is part of the complete schema v1. Fresh-store table
creation, required-column and index verification, and the `user_version = 1`
write occur in one transaction. The singleton coverage row is established when
`EventLog` first opens that fresh store and its monotonic `coverage_start_ms` is
preserved across reopen. A version 0 store, a version greater than 1, or a v1
store missing the metadata table is rejected without mutation. Database reset
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

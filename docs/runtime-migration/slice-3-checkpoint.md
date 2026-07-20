# Slice 3 checkpoint — typed state, pointer input and ordered output

Date: 2026-07-19

Slice 3 is ready for stacked code review. It replaces the product-facing Rive
state and interaction seam, but does not yet activate the Rust runtime as the
SDK's only renderer; script, native-text, lifecycle, and final cutover work stay
in the following slices.

## Delivered

`nuxie-runtime` now:

- exposes product-shaped schema, instance, scalar, list, trigger, and ordered
  output batches through ABI 1.3 while preserving the ABI 1.2 output prefix;
- preserves list-index values as their own type and publishes ordered enum
  labels plus referenced ViewModel schema identity;
- supports atomic, identity-preserving outer ViewModel replacement with shared
  retained state, schema and cycle validation, parent-path mutation routing,
  and durable deferred mirror refresh;
- reports outer ViewModel references as identity-bearing structural changes
  before child-owned scalar changes and includes authoritative reconciliation
  snapshots for structural results;
- reports exact authored OpenURL values and targets without performing host side
  effects;
- retains player fallback, stable pointer IDs, down/move/up/exit/cancel, and
  phase/sequence metadata from the earlier Slice 3 commits; and
- packages those contracts in a generated fixed-width C header with strict
  layout, export, architecture, provenance, and Swift link checks.

`nuxie-ios` now:

- decodes the complete typed catalog and value contract, including enum labels,
  list indexes, nested schema references, and canonical image identities;
- translates canonical snapshots and mutations without committing speculative
  identity mappings, preserves origin/echo semantics, and emits authoritative
  list indexes after every reorder;
- maps authored enum labels to runtime indexes and maps runtime changes back to
  labels while rejecting unknown labels and raw numeric host enum values;
- resolves dynamic images in both directions without exposing runtime numeric
  asset IDs to canonical journey state;
- creates, settles, reuses, and replaces stable outer nested ViewModel
  references, including publisher-flattened reference envelopes and child-first
  snapshots; and
- reconciles structural results atomically against authoritative values, routes
  exact OpenURL data to the product-owned result sink, and decodes only output
  kinds the runtime says are present; and
- routes UIKit pointer input through the canonical centered `.contain`
  transform using a bounded, generation-aware queue that coalesces moves,
  reserves terminal events, and prevents input from starving frame progress.

The display host now owns an explicit, exactly-once result sink and isolates
callbacks by surface generation. This is lifecycle-aware host groundwork only;
the complete background/foreground, visibility, and memory-pressure contract
remains in Slice 5.

Inner nested ViewModel cascades are intentionally not designed in this slice.
Identity-free nested objects such as `{}` fail closed instead of receiving an
unstable synthetic identity. Publisher data must carry `vmInstanceId` or
`instanceId` for an outer reference.

## Runtime artifact

- Source revision: `e17e114f2c84ee991cb047f866b8cef59c4360ce`
- ABI: 1.3
- SwiftPM checksum:
  `b457c097f9e59e87bf4b929917df39c4050363c0bdae0eb120e9cca599dddd54`
- Minimum iOS version: 15.0

This is a local reviewed artifact for the stacked integration PR, not a
published immutable runtime release.

## Verified locally

- `nuxie-runtime` library tests: 116 passed.
- `nuxie` tests: 79 unit, 3 flow-session contract, 12 public API, 121 scene
  authoring, and 1 allocation test passed.
- Apple runtime ABI tests: 48 passed.
- Strict `nuxie` clippy, changed-file Rust formatting, generated-header build,
  C header smoke, packaged-XCFramework verification, and diff checks passed.
- The packaged XCFramework passed 77 native Swift adapter/state-bridge tests
  and 53 fixture-trace tests with zero failures.
- The complete iOS unit suite passed: 634 tests, zero failures.
- The macOS framework build passed.

The workspace-wide Rust formatting command also reports an untouched baseline
formatting mismatch in `crates/nuxie/build.rs`; all files changed by Slice 3
pass `rustfmt --check`.

## Open qualification gates

- Exercise data binding, pointer presses, list reordering, nested references,
  dynamic images, and event ordering with a publisher-produced signed corpus.
- Require stable identity for every published outer ViewModel reference; remove
  identity-free `{}` defaults or replace them with deterministic instances at
  the producer boundary.
- Run the interaction corpus on supported physical devices before final
  qualification.
- Publish and exact-pin the immutable runtime artifact used for final cutover.

None of these gates creates a rollback or dual-runtime path.

## Next slice

Slice 4 adds authenticated bounded Luau, the private allowlisted Nuxie module
and FIFO host commands, scripted-listener actions, and native text-run/control
geometry so the remaining Rive script and text-overlay internals can be
replaced.

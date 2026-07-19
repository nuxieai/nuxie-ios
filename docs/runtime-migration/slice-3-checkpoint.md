# Slice 3 checkpoint — typed state, pointer input and ordered output

Date: 2026-07-19

Slice 3 is ready for stacked code review. It replaces the product-facing Rive
state and interaction seam, but does not yet activate the Rust runtime as the
SDK's only renderer; script, native-text, lifecycle, and final cutover work stay
in the following slices.

## Delivered

`nuxie-runtime` now:

- exposes product-shaped schema, instance, scalar, list, trigger, and ordered
  output batches through ABI 1.2;
- preserves list-index values as their own type and publishes ordered enum
  labels plus referenced ViewModel schema identity;
- supports atomic, identity-preserving outer ViewModel replacement with shared
  retained state, schema and cycle validation, parent-path mutation routing,
  and durable deferred mirror refresh;
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
- routes bounded UIKit pointer input through the canonical centered `.contain`
  transform and decodes only output kinds the runtime says are present.

Inner nested ViewModel cascades are intentionally not designed in this slice.
Identity-free nested objects such as `{}` fail closed instead of receiving an
unstable synthetic identity. Publisher data must carry `vmInstanceId` or
`instanceId` for an outer reference.

## Runtime artifact

- Source revision: `dac13c39c0647869d10e20d05d77e508b6623546`
- ABI: 1.2
- SwiftPM checksum:
  `970a0b4488b3113be7e33654ed9f672acc0a3c1db9137d892a3a4b34077e354c`
- Minimum iOS version: 15.0

This is a local reviewed artifact for the stacked integration PR, not a
published immutable runtime release.

## Verified locally

- `nuxie-runtime` library tests: 115 passed.
- `nuxie` tests: 76 unit, 3 flow-session contract, 12 public API, 121 scene
  authoring, and 1 allocation test passed.
- Apple runtime ABI tests: 45 passed.
- Strict `nuxie` clippy, changed-file Rust formatting, generated-header build,
  C header smoke, packaged-XCFramework verification, and diff checks passed.
- The packaged XCFramework passed the native Swift adapter, fixture trace, and
  state-bridge tests.
- The complete iOS unit suite passed.
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

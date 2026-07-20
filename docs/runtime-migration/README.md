# Nuxie Apple Runtime Migration Research

Status: research complete; Slices 1–4B implemented in stacked review branches
Evidence date: 2026-07-19

## Outcome

`nuxie-ios` will replace `rive-ios` and its linked C++ runtime with a narrow,
internal Apple host for `nuxie-runtime`. The initial cutover preserves current
`.riv` and JSON delivery unchanged. A `.nux` superset is a later, separate
product phase.

There is no production rollback or dual-runtime plan because the current SDK
has no external consumers. Rive remains only long enough to produce development
and CI comparison evidence, then is removed from the customer package.

## Read this set in order

1. [`product-definition-and-migration-plan.md`](product-definition-and-migration-plan.md)
   is the authoritative product interface, target architecture, prototype gate,
   acceptance contract, and vertical migration sequence.
2. [`current-renderer-contract.md`](current-renderer-contract.md) records the
   observable behavior `nuxie-ios` consumes today.
3. [`rive-apple-capabilities.md`](rive-apple-capabilities.md) decomposes the
   exact Rive Apple fork into port, adapt, reference-only, and omit decisions.
4. [`rust-apple-gap-analysis.md`](rust-apple-gap-analysis.md) maps those
   requirements onto the current Rust core, C API, renderer, packaging, and CI.
5. [`publisher-artifact-baseline.md`](publisher-artifact-baseline.md) records
   the current producer, artifact/trust boundaries, corpus, and operational
   prerequisites.
6. [`../../RUNTIME_MIGRATION_DECISION_MAP.md`](../../RUNTIME_MIGRATION_DECISION_MAP.md)
   preserves the completed interview decisions and the one open proof ticket.
7. [`slice-2-checkpoint.md`](slice-2-checkpoint.md),
   [`slice-3-checkpoint.md`](slice-3-checkpoint.md), and
   [`slice-4a-checkpoint.md`](slice-4a-checkpoint.md), and
   [`slice-4b-checkpoint.md`](slice-4b-checkpoint.md) record implementation
   evidence, artifact provenance, and the remaining qualification gates.

## Slice 1 implementation status

Implemented and verified locally:

- a versioned, panic-contained Rust product ABI with opaque context, session,
  surface, and owned-result handles;
- CAMetalLayer-backed `wgpu` presentation with main-actor layer configuration
  and bounded drawable acquisition, worker-confined encoding/presentation,
  command-buffer completion backpressure and asynchronous Metal error capture,
  structured outcomes, `.contain` rendering, resize, detach, reattach, and
  deterministic ownership-aware teardown;
- reproducible device plus universal-simulator XCFramework assembly, archive
  provenance, checksum/header/symbol/architecture checks, and Swift link smoke;
- CI qualification and retention of the verified archive plus provenance;
- tag-only release automation that requires GitHub release immutability,
  validates the pinned build metadata and draft assets, then anonymously
  re-downloads the published archive and verifies its SwiftPM checksum; and
- a Swift ownership adapter, CAMetalLayer view, screen-aware display link,
  lifecycle scheduler, and fake-backed ownership/concurrency tests. The
  concrete adapter also compiles and links against the packaged simulator
  slice through the Make-based Xcode workflow; and
- a standalone reference app that compiles only the narrow Swift runtime seam,
  renders the current `layout-paint` fixture onscreen through the packaged Rust
  library, waits for a positive first-frame presentation result, captures UI
  evidence, and audits its app bundle for the expected `nux_*` symbols and the
  absence of Rive artifacts or linked dependencies.

Slice 1 is not complete or active in the SDK. An immutable release URL does not
yet exist, so `Package.swift` cannot exact-pin a real binary URL/checksum and
the adapter remains behind `canImport(NuxieRuntime)`. The onscreen simulator
gate is closed; immutable release/pinning and authorized physical-device
evidence remain. Rive remains the production dependency until those gates
close.

## Current gate

Provision the publisher signing key and matching Nuxie-owned SDK trust root,
then require the expected signature and key ID on the scripted qualification
fixture. Until that operational work lands, production script authentication
intentionally fails closed while ordinary visuals remain available.

The private bounded Nuxie Luau module, typed FIFO host commands, scripted
listener actions, stable script diagnostics, and complete pointer invocation
payload now cross the Rust/Apple/Swift seam in Slice 4B. The next checkpoint
adds native text-run mutation and outer-ViewModel control geometry. Complete
lifecycle recovery, final Rive removal, and physical-device
performance/memory/app-size qualification follow in the remaining slices.

Source-linked implementation work, an offscreen renderer sample, a mock or
unsigned artifact, a single screen, or simulator-only evidence does not close
the prototype gate.

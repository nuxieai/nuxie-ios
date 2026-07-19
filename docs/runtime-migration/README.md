# Nuxie Apple Runtime Migration Research

Status: research complete; Slice 1 implementation prepared, activation blocked
Evidence date: 2026-07-18

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
- CI qualification and retention of the verified archive plus provenance; and
- a Swift ownership adapter, CAMetalLayer view, screen-aware display link,
  lifecycle scheduler, and fake-backed ownership/concurrency tests. The
  concrete adapter also compiles and links against the packaged simulator
  slice through the Make-based Xcode workflow.

Slice 1 is not complete or active in the SDK. An immutable release URL does not
yet exist, so `Package.swift` cannot exact-pin a real binary URL/checksum and
the adapter remains behind `canImport(NuxieRuntime)`. The real packaged path
also still needs onscreen simulator and authorized physical-device evidence.
Rive remains the production dependency until those gates close.

## Current gate

Before prototype implementation, freeze the producer plus active-artifact
baseline, provision signing and the matching SDK keyring, require the expected
signature/key ID on the scripted qualification fixture, and prove or repair the
jobs worker's deployed compiler-WASM path without changing delivery contracts.

The next step is the real Apple integration prototype. It must use the intended
production path: a checksummed device/simulator XCFramework, versioned C ABI,
SwiftPM binary consumption, signed current artifact and assets, onscreen
`wgpu`/Metal rendering, typed state/input/ordered output, Luau, native text, two
live screens, background/surface recovery, panic isolation, and physical-device
performance/memory/app-size measurements.

Source-linked implementation work, an offscreen renderer sample, a mock or
unsigned artifact, a single screen, or simulator-only evidence does not close
the prototype gate.

# Nuxie Apple Runtime Migration Research

Status: research complete; Slices 1–5 implemented, with the Slice 6 client
cutover implemented in stacked review and external acceptance gates still open
Evidence date: 2026-07-20

## Outcome

`nuxie-ios` now replaces `rive-ios` and its linked C++ runtime with a narrow,
internal Apple host for `nuxie-runtime`. The cutover preserves current
`.riv` and JSON delivery unchanged. A `.nux` superset is a later, separate
product phase.

The ratified repository direction separates three interfaces: portable
`nux-capi` remains baseline-only; `nuxieai/nuxie-product` owns a separately
named product ABI for `.nux`, ProjectDO, scripting, and sessions; and
`nuxie-ios` owns Apple surfaces and XCFramework packaging. The SDK pins one
exact qualified product revision, which itself pins one exact runtime revision.

There is no production rollback or dual-runtime plan because the current SDK
has no external consumers. Rive has been removed from the customer package and
the production Swift source on the Slice 6 branch.

## Read this set in order

1. [`swift-runtime-module.md`](swift-runtime-module.md) records the current
   Swift-native adapter decision and supersedes the earlier Rust product-adapter
   placement.
2. [`product-definition-and-migration-plan.md`](product-definition-and-migration-plan.md)
   is the authoritative product interface, target architecture, prototype gate,
   and acceptance contract except where the Swift-module decision supersedes it.
3. [`current-renderer-contract.md`](current-renderer-contract.md) records the
   observable behavior `nuxie-ios` consumes today.
4. [`rive-apple-capabilities.md`](rive-apple-capabilities.md) decomposes the
   exact Rive Apple fork into port, adapt, reference-only, and omit decisions.
5. [`rust-apple-gap-analysis.md`](rust-apple-gap-analysis.md) maps those
   requirements onto the current Rust core, C API, renderer, packaging, and CI.
6. The publisher/artifact baseline record (producer, artifact/trust
   boundaries, corpus, and operational prerequisites) lives in the private
   monorepo (`docs/runtime-migration/publisher-artifact-baseline.md` there),
   since it deep-links monorepo sources.
7. [`apple-runtime-distribution.md`](apple-runtime-distribution.md) records the
   binary target, immutable archive, local staging, privacy, and link-audit
   contract.
8. [`../../RUNTIME_MIGRATION_DECISION_MAP.md`](../../RUNTIME_MIGRATION_DECISION_MAP.md)
   preserves the completed interview decisions and the one open proof ticket.
9. [`slice-2-checkpoint.md`](slice-2-checkpoint.md),
   [`slice-3-checkpoint.md`](slice-3-checkpoint.md),
   [`slice-4a-checkpoint.md`](slice-4a-checkpoint.md),
   [`slice-4b-checkpoint.md`](slice-4b-checkpoint.md),
   [`slice-4c-checkpoint.md`](slice-4c-checkpoint.md),
   [`slice-5-checkpoint.md`](slice-5-checkpoint.md), and
   [`slice-6-checkpoint.md`](slice-6-checkpoint.md) record implementation
   evidence, artifact provenance, and remaining qualification gates.

## Apple host implementation status

Implemented and verified locally:

- a versioned, panic-contained Rust product ABI with opaque context, session,
  surface, and owned-result handles;
- CAMetalLayer-backed `wgpu` presentation with main-actor layer configuration
  and bounded drawable acquisition, worker-confined encoding/presentation,
  command-buffer completion backpressure and asynchronous Metal error capture,
  structured outcomes, `.contain` rendering, resize, detach, reattach, and
  deterministic ownership-aware teardown;
- reproducible device plus universal-simulator XCFramework assembly, archive
  provenance, header/symbol/architecture checks, and Swift link smoke;
- an in-repository verified archive plus source provenance;
- dispatch-only refresh automation that rebuilds the artifact, records its
  source inputs, and opens a pull request without creating tags or releases;
  and
- a Swift ownership adapter, CAMetalLayer view, screen-aware display link,
  lifecycle scheduler, and fake-backed ownership/concurrency tests. The
  concrete adapter also compiles and links against the packaged simulator
  slice through the Make-based Xcode workflow; and
- a standalone reference app that compiles only the narrow Swift runtime seam,
  renders the current `layout-paint` fixture onscreen through the packaged Rust
  library, waits for a positive first-frame presentation result, captures UI
  evidence, and audits its app bundle for the expected `nux_*` symbols and the
  absence of Rive artifacts or linked dependencies; and
- a mandatory `NuxieRuntime` binary dependency in the iOS SDK, an SDK-owned
  privacy manifest, post-link audits of the actual customer framework, and the
  deletion of the Rive package, bridge code, and Rive-only fixtures and tests.

Slices 1–5 and the Slice 6 customer cutover are active in the SDK.
`Package.swift` declares the committed runtime archive, with an ignored local
artifact path for development. The SDK commit selected by a consumer is also
the runtime version. CI compares the committed provenance with the Apple crate
tree and nested engine revision, while packaging validates the Apple slices,
load commands, headers, notices, and ABI symbols before updating the archive.
Frozen-producer and exhaustive/golden corpus qualification, signed
publisher-path proof, privacy-owner confirmation, and authorized
physical-device evidence remain as release and operational qualification.

## Current gate

Provision the publisher signing key and matching Nuxie-owned SDK trust root,
then require the expected signature and key ID on the scripted qualification
fixture. Until that operational work lands, production script authentication
intentionally fails closed while ordinary visuals remain available.
Swift preserves the exact signed-manifest evidence and selects only candidate
Nuxie key material; Rust alone verifies that evidence against the imported
artifact and decides whether scripts may execute.

The private bounded Nuxie Luau module, typed FIFO host commands, scripted
listener actions, stable script diagnostics, complete pointer invocation
payload, named text-run mutation, and outer-ViewModel control geometry now
cross the Rust/Apple/Swift seam through Slice 5. Each presentation now owns one
fresh imported context, its screens own independent sessions and surfaces, and
the Swift host completes bounded settled/offscreen scheduling, surface
recovery, and deterministic presentation teardown. Slice 6 makes that path
mandatory and removes Rive; physical-device performance, memory, recovery,
soak, and app/IPA-size qualification remain external merge gates.

Source-linked implementation work, an offscreen renderer sample, a mock or
unsigned artifact, a single screen, or simulator-only evidence does not close
the prototype gate.

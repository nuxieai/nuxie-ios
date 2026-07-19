# Slice 2 checkpoint — trust-bearing import and assets

Date: 2026-07-19

Slice 2 is ready for stacked code review. It is not yet a production
qualification sign-off: production signing material, a publisher-signed corpus,
and physical-device evidence remain external acceptance gates.

## Delivered

`nuxie-runtime` now:

- requires the complete ABI 1.1 import contract and rejects the old
  artifact-only ABI 1.0 prefix;
- verifies the exact signed manifest, selected Nuxie Ed25519 key, acquisition
  flow/build identity, RIV digest, and declared external assets;
- returns visual-only authorization for missing, malformed, unknown-key, or
  invalid signature evidence without accepting a trusted Boolean;
- returns structured import and authorization diagnostics;
- validates image decoding during import, retains valid encoded image bytes,
  attaches font bytes, fails invalid required assets, and omits invalid optional
  assets with a warning; and
- enforces fixed request, identity, diagnostic, asset-count, and byte bounds.

`nuxie-ios` now:

- preserves exact manifest/signature evidence and selects keys only from the
  internal Nuxie key ring;
- binds authorization to the acquired flow/build identity;
- adapts the current artifact directory into container-neutral RIV and asset
  byte inputs without exposing paths or URLs to Rust;
- bounds files before reading, hashes all prepared bytes, preserves
  required/optional behavior, and retains content-scoped CoreText fonts;
- normalizes authorization-only transport defects into visual-only evidence
  while keeping manifest/integrity failures hard; and
- marshals a flat, synchronously borrowed C request and copies bounded owned
  results through focused import and result bridge files.

## Verified locally

- Apple runtime library tests: 26 passed.
- Artifact validator tests: 15 passed.
- Runtime public API tests: 12 passed.
- Strict Apple-product clippy, formatting, generated-header staleness, header
  smoke, verifier syntax, and diff checks passed.
- Native Swift adapter tests passed through the packaged XCFramework seam.
- Focused trust, artifact-store, asset, font, and text-overlay tests passed.
- The macOS framework build passed.
- The standalone reference app presented and switched fixtures through Rust;
  its link audit found Rust present and Rive absent.

The final packaged-XCFramework adapter and reference-app gates are rerun after
every runtime binary rebuild before this slice is published.

## Open qualification gates

- Provision the production public-key ring and backend signing secret/key ID.
- Produce a real publisher-signed artifact containing real image and font
  assets; run positive rendering and negative no-script-registration cases.
- Run the onscreen, resize, lifecycle, and trusted-import corpus on supported
  physical devices.
- Cut and consume the immutable checksummed runtime release used for final
  qualification.

Deterministic ephemeral-key tests prove the cryptographic and ABI contract, but
they do not substitute for those operational gates. None of these gates creates
a rollback or dual-runtime path.

## Next slice

Slice 3 adds the product-shaped typed state batch, player fallback, stable
pointer input, and phase-ordered outputs, then replaces the Rive ViewModel and
event/input bridge internals in Swift.

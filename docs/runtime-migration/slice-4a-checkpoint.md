# Slice 4A checkpoint — authenticated script import

Date: 2026-07-19

Slice 4A is ready for stacked code review. It closes the script-import trust
boundary and enables the pinned Luau VM in the Apple product, but it does not
yet expose the private Nuxie Luau module, FIFO host commands, scripted listener
actions, or native text mutation. Those remain in the following Slice 4
checkpoints.

## Delivered

`nuxie-runtime` now:

- replaces the unsigned-script import escape hatch with a sealed
  `ScriptImportCapability` minted only by strict Ed25519 verification over an
  exact manifest whose RIV size and SHA-256 match the imported bytes;
- rechecks the capability against the bytes at import, keeps visual-only
  artifacts fully renderable while skipping every script mount and advance,
  and contains the in-process authoring exception behind a crate-private seam;
- gives every `FlowSession` a fresh script VM while sharing only immutable
  parsed runtime, graph, and script-asset data;
- moves executable authority into the core import boundary so the Apple
  adapter cannot pass a trusted Boolean or recreate signature policy; and
- enables the pinned Luau runtime in the Apple product for macOS, iOS devices,
  and both simulator architectures.

The upstream `luaur-common` and `luaur-vm` 0.1.8 crates are vendored unchanged
except for four documented target-condition edits that reuse their existing
Mach monotonic clock on every Apple platform. The release artifact records the
Luau version in metadata and embedded target provenance, packages `LICENSE`
and `THIRD_PARTY_NOTICES.md`, and verifies all of them byte-for-byte.

`nuxie-ios` now:

- owns an internal `FlowScriptTrustPolicy` instead of accepting arbitrary
  application-provided verification keys;
- provides a fail-closed production root set and a deterministic internal
  ephemeral policy used only by tests;
- normalizes bounded manifest/signature/key evidence before runtime import;
- requires the runtime's authenticated key ID to equal the policy-selected key
  ID before publishing an authenticated context; and
- disposes the native context when authenticated evidence is missing or
  mismatched, while unsigned complete requests remain visual-only.

## Runtime artifact

- Source revision: `ed8350147f1a3a8bf0e71c92ae2af6bd0833216b`
- ABI: 1.3
- Luau: 0.1.8
- SwiftPM checksum:
  `8b6fb46afbdfd3547e03a57f78ee71725c5dab42fba40067a782d7a71a1509bd`
- Minimum iOS version: 15.0

This is a local reviewed artifact for the stacked integration PR, not a
published immutable runtime release.

## Verified locally

- `nuxie` scripting and visual-only library tests: 84 and 79 passed.
- Exact-artifact scripted rendering tests: 3 passed.
- Apple runtime product tests: 48 passed; artifact validator tests: 15 passed;
  no-feature ABI tests: 20 passed.
- Strict first-party `nuxie` and Apple-runtime Clippy, changed-file Rust
  formatting, shell syntax, release-workflow syntax, generated-header build,
  C header smoke, and diff checks passed.
- The clean release command built all three Apple targets and passed packaged
  XCFramework architecture, export, provenance, notice, checksum, C-header,
  and Swift device/simulator link verification.
- The exact packaged XCFramework passed 53 native Swift adapter,
  fixture-trace, and state-bridge tests with zero failures.
- Focused Swift trust-policy, artifact-store, and runtime-host tests passed.
- The complete iOS unit suite passed: 638 tests, zero failures.
- The macOS framework build passed.

## Open qualification gate

The production public-key ring is intentionally empty until the backend
signing key and key ID are provisioned. Production therefore fails closed for
script execution today. Provisioning that Nuxie-owned public key is required
before a publisher-signed script corpus can pass authentication; host apps do
not receive an override or an `allowExternalScripts` equivalent.

Physical-device and publisher-corpus qualification remain final migration
gates. None of these gates creates a rollback or dual-runtime path.

## Next checkpoint

Slice 4B adds the readonly allowlisted `require("nuxie")` module, typed and
bounded FIFO host commands, scripted listener actions, per-session resource
budgets, creation-time HostWork output, and terminal session-local script
failure semantics.

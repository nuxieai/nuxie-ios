# Slice 6 checkpoint — Rust-only customer SDK cutover

Date: 2026-07-20

Slice 6 makes the Rust Apple host mandatory for iOS, removes the Rive Apple
package and production bridge code, and qualifies both the standalone renderer
and the assembled customer framework. There is no runtime fallback, rollback
path, or dual-engine release. Current `.riv` plus JSON delivery is preserved;
the `.nux` superset remains a separate product phase.

## Delivered

The customer SDK now:

- imports `NuxieRuntime` directly on supported iOS builds and creates every
  production flow context through the Rust adapter;
- declares a binary target for the immutable
  `apple-runtime-v0.1.0/NuxieRuntime.xcframework.zip` release, with an ignored
  local XCFramework path for development and qualification;
- validates device arm64 and simulator arm64/x86_64 slices, public headers,
  iOS 15 Mach-O load commands, module maps, notices, and required ABI symbols
  before any local artifact is staged;
- links the Rust static archive and its Foundation, QuartzCore, Metal,
  CoreGraphics, and Security dependencies into iOS targets while leaving the
  macOS SDK build independent of the iOS artifact;
- ships an SDK-wide `PrivacyInfo.xcprivacy` with tracking disabled; linked
  contact traits, identifiers, purchase, interaction, usage, diagnostics,
  memory performance, response, and custom-property collection declared; and
  System Boot Time `35F9.1`, User Defaults `CA92.1`, and File Timestamp
  `C617.1` required-reason coverage;
- audits the final `Nuxie.framework` and standalone reference app for Rust ABI
  symbols, the expected privacy manifest, and the absence of Rive artifacts,
  dependencies, and Rive C++ namespace symbols;
- removes `rive-ios`, `RiveRuntime`, the package-pin workaround, Rive-backed
  ViewModel/script bridges, and obsolete Rive-only fixtures and tests;
- keeps Swift as an exact authorization-evidence carrier and candidate-key
  selector while Rust alone validates the signature and authorizes scripts; and
- makes the documented privacy sanitizer recursively remove email, phone,
  name, address, and other sensitive fields inside identity dictionaries and
  arrays, while the compliance sanitizer recursively removes empty strings and
  null values before upload.

Wire-format names such as `flow.riv` and `riveUniqueName` deliberately remain
because changing the delivery container is outside this migration.

## Repository-local qualification evidence

The cutover implementation's repository-local qualification completed without
a failure or skip:

- 716 iOS SDK unit tests passed on an iPhone 17 Pro simulator running iOS 26.5;
- 60 focused concrete runtime-adapter tests passed against the staged binary;
- both standalone reference UI tests passed, including first-frame presentation
  and replacement-renderer startup;
- 603 macOS SDK unit tests passed on macOS 26.4.1;
- the final simulator `Nuxie.framework` audit found the required Rust symbols
  and byte-exact privacy manifest while rejecting all Rive evidence;
- an unsigned Release framework linked for generic arm64 iOS and passed the
  same customer-framework audit; and
- the reference application audit independently found the Rust runtime and
  privacy declaration with no packaged or linked Rive dependency.

SwiftPM manifest evaluation and an arm64 iOS 15 simulator cross-build,
XcodeGen generation, XCFramework structure/load-command/symbol validation,
shell syntax, property-list validation, and whitespace checks also passed. The
generated iOS SDK and reference application both link at the iOS 15 deployment
target. The macOS target builds without a staged runtime artifact.

This evidence qualifies the client cutover mechanics. It does not close the
cross-repository corpus, publisher, golden-comparison, or physical-device
acceptance contract listed below.

## Artifact provenance

The qualified ABI 1.5 artifact was built from clean `nuxie-runtime` revision
`c1ee86b7efebc616918a185bf32ce0688ccf0427`. Its runtime version is `0.1.0`,
minimum deployment target is iOS 15, and its provenance records Rust 1.94.1,
Xcode 26.6, and the iOS 26.5 SDK.

The exact SwiftPM archive checksum is:

```text
02f1083cfe7490c5d2d06f2fbd5aeb7e589ece42ce33ccc99ecd84166447f717
```

## Remaining merge gates

- Enable immutable GitHub releases for `nuxie-runtime`, publish the qualified
  archive at the declared `apple-runtime-v0.1.0` URL, and anonymously verify
  the downloaded bytes and checksum. The URL currently returns HTTP 404, so a
  clean remote SwiftPM resolution and the iOS CI fetch jobs cannot yet pass.
- Freeze and retain every actively deliverable `/profile` artifact for each
  supported app/environment, together with the exact publisher, compiler,
  Rive, Luau, and compiler-WASM identities and a reproducible corpus registry.
- Reproduce and verify the deployed jobs-worker compiler-WASM publish path,
  provision the publisher signing key and matching Nuxie-owned SDK trust root,
  and publish a genuine signed qualification fixture. Production script
  authorization intentionally remains visual-only until the root is shipped.
- Run the frozen inventory through exhaustive identity/trust, manifest/RIV
  import, asset resolution, script initialization, and initial-session checks.
  Run the versioned golden corpus through Rive-reference-versus-Rust pixel,
  interaction, event-order, binding, text, transition, lifecycle, recovery,
  teardown, stress, and soak comparisons, including signed-positive and
  tampered/replayed/unknown-key/wrong-environment/unsigned security cases.
- Capture physical-device performance, memory, background/foreground, surface
  recovery, render/interaction, soak, and stripped app/IPA-size evidence on the
  agreed oldest-supported and current ProMotion devices, then record the
  measured release thresholds and results.
- Have the backend/privacy owner confirm that Nuxie's use of the SDK's linked
  data does not meet Apple's tracking definition. The client does not access
  advertising identifiers or declare tracking domains, but this repository
  cannot prove how exported data is combined or shared after upload.

These are release and operational qualification gates, not reasons to retain
Rive or introduce a rollback path. After they close, the stacked cutover can
merge. The `.nux` container is the next separately designed phase.

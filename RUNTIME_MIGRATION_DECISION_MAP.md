# Nuxie Apple Flow Runtime — Decision Map

Goal: remove `rive-ios` and the C++ `rive-runtime` from `nuxie-ios`, replacing
them with `nuxie-runtime` while building only the Apple host needed to render
trusted, server-delivered Nuxie flows.

Evidence baseline (2026-07-18):

- `nuxie-ios` `5116b9bb`; dependency pin `rive-ios` `aa9be09f`.
- The pinned package ships an XCFramework built from the Nuxie fork source at
  `205bba2d` (generic script modules, dotted module names, and the verified-host
  opt-in for otherwise-unverified embedded scripts are fork-specific).
- Local `nuxie-runtime` `eb0e2527`; Rust runtime/renderer parity work is mature,
  but there is no Apple package, onscreen Apple surface, or product-complete
  Swift-facing ABI yet.

Research and product definition are complete. Current frontier: complete the
operational evidence prerequisites recorded under #8, then run the real Apple
integration proof. #10 records the agreed vertical migration sequence;
production migration does not begin until the prototype has established the
missing surface, packaging, isolation, performance, and size evidence.

## #1: Product Boundary

Blocked by: none
Type: Discuss

### Question

Are we recreating a general Rive Apple SDK or an internal Nuxie flow host?

### Answer

Resolved from the product goal and current public API: build an internal,
flow-specific Apple runtime host. Preserve the public `NuxieSDK` flow APIs; do
not reproduce Rive's public animation-player API, authoring API, or source/API
compatibility. Compatibility is defined by Nuxie flow behavior, subject to #2.

Concretely, retain `showFlow(...)` for Nuxie-managed presentation and
`getFlowViewController(...)` for host-controlled UIKit containment. Keep
runtime contexts, render sessions, surfaces, scripting modules, and all
Rive-shaped controls internal. Do not add a standalone public SwiftUI player or
animation view in this migration; SwiftUI hosts use the same Nuxie-level entry
points.

## #2: Artifact Compatibility Contract

Blocked by: none
Type: Discuss

### Question

Which already-published artifacts, editor/runtime versions, and platforms must
continue to work without republishing when the runtime changes?

### Answer

Resolved. The initial migration is a client-only, behavior-preserving
runtime substitution: no publisher schema, wire payload, artifact layout,
manifest format, or artifact-regeneration changes. Signing provisioning and
publisher build/deployment repairs that do not change those contracts remain
allowed prerequisites. Every currently deliverable `.riv` plus existing JSON
contracts must work unchanged. A subsequent, distinct phase introduces `.nux`,
a superset of `.riv` that replaces the transitional multi-surface delivery
contract. The initial migration must not depend on `.nux`, although its runtime
interface should avoid making the later
container unnecessarily difficult. Flow rendering is iOS-only; the non-rendering
Nuxie SDK continues supporting macOS with its current behavior. Adding macOS
flow rendering is a separate feature, not migration parity.

Freeze the publisher/exporter to the currently supported Rive file/runtime
format from migration start until `.nux` replaces it. Compatibility with later
Rive format versions or editor features is not implicit; accepting one requires
an explicit compatibility project and corpus update. Nuxie must not inherit
Rive's future product roadmap merely because `.riv` is the transitional input.

Preserve the package's existing deployment contract: iOS 15 remains the
minimum for the flow renderer, while macOS 12 remains supported for the SDK's
existing non-rendering behavior. The migration does not justify raising either
deployment target.

## #3: Current Nuxie Flow Renderer Contract

Blocked by: #1
Type: Research

### Question

Exactly which runtime behaviors does `nuxie-ios` consume today, including
Nuxie-fork-only behavior and observable failure/lifecycle semantics?

### Answer

Resolved in `docs/runtime-migration/current-renderer-contract.md`. The audit
finds six directly coupled production files and no public Rive type. It records
the exact import/player, rendering, ViewModel, Luau, assets/fonts, native text,
pointer/event ordering, transition, lifecycle, platform-effect, failure, and
fixture behavior to preserve, while keeping Nuxie-owned acquisition, journey,
presentation, policy, persistence, and telemetry outside the runtime.

## #4: Rive Apple Layer Decomposition

Blocked by: #1
Type: Research

### Question

What does the exact `rive-ios` fork add above C++ `rive-runtime`, and which
parts are bridge mechanics, Apple platform integration, or general-animation
product conveniences?

### Answer

Resolved in `docs/runtime-migration/rive-apple-capabilities.md`. The
source-backed matrix distinguishes Apple bridge/platform responsibilities from
Rive's general animation product conveniences, identifies the exact binary
source and Nuxie fork changes, and assigns every capability a port, adapt,
reference-only, or omit disposition.

## #5: Rust Engine and Apple-Binding Delta

Blocked by: #1
Type: Research

### Question

For every capability in #3 and #4, is it present in `nuxie-runtime` core,
exposed through `nux-capi`, or still missing for a production Apple host?

### Answer

Resolved in `docs/runtime-migration/rust-apple-gap-analysis.md`. The Rust core
and retained `wgpu` renderer are mature and strongly reference-tested, but the
current C API is a generic test/embedding surface rather than the Apple product
seam. Onscreen surface presentation, trust-bearing import, product-complete
typed state/events/input/assets/text, safe ownership and diagnostics, an
unwind-capable Apple profile, static/XCFramework packaging, ABI versioning,
physical-device qualification, and meaningful linked-app size/performance
evidence remain implementation work.

Repository boundary resolved: `nuxie-runtime` owns the product-shaped C ABI,
iOS static-library/XCFramework build, headers, and low-level ABI tests;
`nuxie-ios` owns Swift context/session wrappers, the UIKit/Metal host,
lifecycle/display timing, native controls, event mapping, and flow integration.

`nuxie-runtime` CI builds immutable iOS device/simulator XCFramework releases.
`nuxie-ios` consumes a pinned, checksummed prebuilt artifact. Customer builds
must not invoke Cargo or require a Rust toolchain/build plugin.

Version `nuxie-runtime` independently from `nuxie-ios`. Each Apple SDK release
pins one exact runtime artifact and verifies an explicit ABI version so an
accidental binary/header mismatch fails immediately.

Use a narrow, versioned C ABI with opaque handles and thin hand-written Swift
ownership wrappers. Generate and verify the C header mechanically, but do not
use UniFFI or expose a generated/generalized Swift runtime object model.

The current Rust release profiles use `panic = "abort"`, which would terminate
the host app and cannot satisfy per-flow failure isolation. The Apple artifact
must use an unwind-capable panic strategy and catch panics inside every exported
C entry point, converting them to structured fatal-session errors without ever
unwinding across C/Swift. Measure the resulting size/performance cost in the
prototype and continue the runtime's panic-freedom lint/fuzz ratchet; do not
silently weaken the isolation contract.

The shipped Apple package must also preserve required privacy-manifest
declarations, including the existing system-boot-time API reason used by the
frame timer. Validate the assembled SDK archive, not merely the Swift target,
so the binary runtime cannot accidentally drop required bundle resources.

## #6: Version-One Capability Policy

Blocked by: #2, #3, #4, #5
Type: Discuss

### Question

Which capabilities are required, deferred, or intentionally unsupported for
the first Rust-backed Nuxie flow runtime?

### Answer

Resolved. On-device Luau execution and the existing Nuxie host
functions are required for unchanged-artifact compatibility. For v1, Luau is
extended through an internal, allowlisted registry of Nuxie-owned native
modules, functions, and types. Do not fork Luau grammar/bytecode or expose
host-app extension registration without a concrete future use case. Script execution must be
authorized by cryptographic validation using validation material supplied by
`nuxie-ios`; a generic `allowsExternalScripts` / `allowsUnverifiedScripts`
bypass is not an acceptable production interface.

The intended trust source is a Nuxie-controlled public-key ring. The audited
deployed ring is currently empty and must be provisioned before the prototype.
Keys are selected by key ID and support rotation; private signing keys remain
in the Nuxie publishing/backend path, and host apps cannot replace the trust
roots.
The migration should integrate this verifier directly into the Rust runtime
instead of adapting it to Rive's script-authorization design.

Today, `nuxie-ios` verifies an Ed25519 signature over the exact manifest; the
manifest hashes `flow.riv`, so that verification transitively covers embedded
scripts. It then maps that trusted-artifact result onto Rive's unsigned-script
escape hatch. `nuxie-runtime` parses Rive script envelopes but does not yet
verify their signatures and similarly exposes an unsigned-script import path.
The replacement needs a first-class trust-bearing import interface. The
artifact-level signature over `nuxie-manifest.json` is the only trust unit for
this migration; the unsigned outer `BuildManifest` is not authorization. Do
not design individual script signatures, artifact/script fallback rules, or an
inner-signature interface.

For the initial migration, retain the native `UITextField` / `UITextView`
overlay design. Rust supplies precise control geometry and runtime text state;
UIKit owns editing, keyboard behavior, selection, autofill, secure entry, and
accessibility. Runtime-native text editing is out of scope.

Nuxie currently uses one presentation transform: `.contain` with centered
alignment. Implement that exact view/artboard transform and its inverse for
rendering, pointer input, native text geometry, and safe-area mapping. Do not
port Rive's generalized public fit/alignment API until a Nuxie artifact contract
requires another mode.

The unchanged current artifact requires runtime schema introspection; its flow
JSON carries values, not the complete typed view-model schema. A typed
schema inside the later `.nux` format may be evaluated separately.

One loaded flow shares its parsed file, decoded assets, GPU resources, and
serial worker. Each screen retains an independent artboard, state machine,
view-model instance, input state, event state, and render surface so native
transitions can keep multiple screens live.

Scope all mutable runtime state to one presentation. Every presentation creates
fresh screen sessions, view-model/response values, Luau VM state, input state,
and event queues. Caches may retain only immutable parsed artifacts and decoded
assets, shared render pipelines, and other explicitly rebuildable resources
keyed by verified artifact identity. Never reuse a prior presentation's mutable
session state.

For accessibility, preserve current migration parity only: the render surface
and native text controls retain their existing behavior. A semantic remote-UI
accessibility tree requires a future `.nux` authoring contract and is out of
scope here.

Audio is not part of the current Nuxie artifact contract: the manifest model,
asset store, and checked-in flow fixtures contain image and font assets only.
Do not port `rive-ios` audio support for the initial migration. Reconsider it
only when a Nuxie flow product requirement and artifact contract exist.

Preserve the current external-asset policy. Swift verifies and prepares every
manifest-declared image and font before runtime import. A missing, corrupt, or
unsupported required asset fails the flow load; an optional asset is omitted
with a diagnostic and the runtime uses its ordinary missing-asset behavior.
Preserve lookup by Rive `uniqueName`, runtime font decoding, and CoreText font
registration/identity so the native UIKit text overlay and rendered text select
the same font.

Named text-run lookup and mutation are required capabilities: Nuxie directly
sets `TextValueRun` values and expects the render surface and native input
overlay to update on the next cycle. Preserve the current player-selection
fallback—default state machine, then state machine index zero, then the first
linear animation—unless the exhaustive artifact corpus proves a branch is
unreachable before implementation is scoped.

Preserve the current script-trust failure behavior for unchanged artifacts: a
missing or invalid artifact-level signature may still allow the visual artifact to
load, but no embedded script may register or execute. The Rust import path must
make this an explicit authorization result, not a generic unsigned-script
bypass, and must never leave a partially initialized script environment.

Sandbox signed Luau with deterministic resource ceilings in addition to its
restricted globals/modules. Bound script work or instruction execution per
runtime cycle and cap VM memory so a valid-but-buggy published script cannot
hang or exhaust the host process. A limit violation terminates only the
affected flow session and emits structured diagnostics. Calibrate concrete
limits from representative scripted flows during the Apple prototype, then
lock them into repeatable adversarial and regression tests.

## #7: Swift/Rust Ownership and Interface

Blocked by: #3, #5, #6
Type: Discuss

### Question

What coarse-grained session/surface interface and ownership split should join
Swift flow orchestration to the Rust engine and renderer?

### Answer

Resolved. Swift owns UIKit containment, app/view lifecycle,
display timing, native text/accessibility overlays, and Nuxie orchestration;
Rust owns import, independent screen instances, state machines, data binding,
scripting, assets needed by the engine, and GPU rendering. Renderer ownership
is resolved: Rust presents directly into an Apple GPU surface hosted by Swift.
The per-draw callback C ABI remains a test/general embedding surface, not the
production iOS seam. Avoid per-draw-call Swift FFI and make invalid handle
destruction/thread use unrepresentable.

Use the existing parity-tested Rust `wgpu` renderer with its Metal backend as
the intended production renderer. Extend it from offscreen readback to an
onscreen Apple surface; do not build a second native-Metal renderer in parallel.
Consider a separate backend only if the Apple prototype demonstrates that this
path cannot satisfy measured performance, binary-size, or lifecycle gates.

Swift owns the `UIView`/`CAMetalLayer` and its main-actor lifecycle; Rust owns
the corresponding `wgpu::Surface`, configuration, texture/drawable acquisition,
GPU submission, and presentation. Do not pass `MTLDrawable` or externally
wrapped Metal textures across the C ABI. Surface attach/detach must explicitly
coordinate layer lifetime, and the prototype must prove that bounded frame
latency and work coalescing keep acquisition off the main actor and prevent
unbounded blocking.

Swift owns the app-facing frame clock and issues one coarse
`advanceAndRender(timestamp:)` operation per active surface. Rust may schedule
GPU work internally but does not own an independent app-facing loop or invoke
Swift from arbitrary threads. Reuse proven `rive-ios` patterns for Apple
display-link lifecycle, visibility/backgrounding, Metal surface management,
coordinate mapping, teardown, and concurrency where they fit this narrower
contract.

Adopt Rive's modern non-blocking shape in v1: UIKit/display links remain on the
main actor, while runtime state and GPU commands are confined to a serial Rust
worker. Bound in-flight drawables and skip/coalesce work when busy rather than
blocking the UI thread. Expose a small Nuxie command set, not Rive's generalized
command-queue API.

Model the ownership explicitly as a shared `FlowRuntimeContext` per loaded flow
artifact and an independent `FlowRenderSession` per screen/surface.

Separate logical session lifetime from surface lifetime. A render session
preserves its artboard, state machine, view-model, Luau, input, and event state
while its Apple surface detaches, resizes, backgrounds, or is recreated. Rebuild
only presentation and rebuildable GPU resources, then redraw with zero resumed
delta. Enter the flow-failure path only when device/surface/resource recovery
is genuinely unrecoverable.

Keep Rust network-blind. Swift owns artifact/asset download, caching, path and
hash/content-type validation, and resolution. Rust receives only verified
content, then owns runtime decoding and GPU upload. It never follows CDN URLs
or initiates network access.

Keep runtime import independent of the transitional container shape. Swift
adapts the current manifest/directory into exact `.riv` bytes, a verified asset
table, and artifact-level script-authorization evidence. Rust must not know current JSON
paths or anticipate the `.nux` container; a later `.nux` loader can produce the
same runtime import inputs without redesigning the engine ABI.

An alive but offscreen session continues advancing state machines/scripts and
processing host mutations while suppressing GPU draws, matching current Rive
behavior. Once settled it stops ticking; input, data mutation, or a runtime
wake request restarts it.

When the host scene backgrounds, pause every flow session and preserve its
state. Do not advance or catch up wall-clock time in the background. Reset
timing on foreground so the first resumed frame advances by zero.

Do not flatten all output into a generic post-render event bucket. Each worker
operation returns phase-ordered output matching the current Rive host: preserve
events pending before advance ahead of advance-produced outputs, then preserve
the relative order of view-model listener changes, script commands, player
advance notification, text-overlay layout, and runtime events established by
the reference traces. Swift receives the completed ordered batch afterward on
the main actor. Never invoke Swift reentrantly during FFI or directly from the
Rust worker. Encode the phase/order in the result so asynchronous dispatch does
not reorder observable effects.

Pointer commands preserve legacy zero-delta semantics, including same-cycle
down/up, immediate `advance(0)` where the current Rive path performs it, and an
exit after pointer up or cancel. Support stable pointer IDs and explicit
down/move/up/exit/cancel rather than collapsing UIKit input into taps.

Implement pure Nuxie-owned Luau modules inside Rust. Host-affecting functions
such as `Nuxie.trigger` and `Nuxie.response.set` remain one-way operations that
return no host-derived value, enqueue typed `FlowHostCommand` values inside the
session, and leave Rust in the ordered operation result. This also applies to
host calls made during file import or script registration: queue them without a
reentrant Swift callback. Do not expose a generic Swift closure/module registry
across FFI. A future script API that truly needs an asynchronous host result
requires a separately designed request/resume protocol; v1 does not speculate
about it.

For the transitional `.riv` plus current JSON-contract product, Swift's
`FlowJourneyRunner` and flow view-model state coordinator remain authoritative
for journey state, persisted responses, and values shared across screens. Rust
owns typed runtime ViewModel instances per screen and returns ordered runtime
changes; Swift applies accepted changes to canonical state and fans typed deltas
back to the appropriate sessions. Preserve mutation origin/source metadata and
host-write echo suppression. Reconsider moving canonical flow semantics only
as part of the later `.nux` design.

Rust and Luau never directly perform platform effects. URL opening, navigation,
purchases, restores, permissions, clipboard access, networking, and similar
operations leave the session as typed intents. Swift validates them and routes
them through existing Nuxie/UIKit/platform services on the correct actor. Any
asynchronous outcome re-enters later as a normal ordered input or canonical
state mutation; it never blocks the Rust worker or requires a reentrant FFI
callback.

Import, script initialization, worker, or rendering failures terminate only the
affected flow/session set, emit structured diagnostics, and enter the existing
flow failure/dismissal path. Contain Rust panics at the FFI boundary. Invalid or
untrusted content fails closed before any partial script execution.

## #8: Apple Integration Proof

Blocked by: #7 plus signing/keyring provisioning, a frozen producer/artifact
baseline, and a verified jobs compiler deployment path
Type: Prototype

### Question

Can the proposed seam load and present a real signed flow on iOS, preserve
input/events/bindings across two live transitioning screens, and package as a
SwiftPM-consumable XCFramework within performance and size budgets?

### Answer

Open. First capture the exact producer identities and active artifact bytes,
provision signing plus the matching SDK keyring, and prove that the jobs worker
can publish the signed qualification fixture through its deployed WASM path.
Then the prototype is throwaway implementation work but must produce real
evidence through the intended production seam. Build the actual iOS
device/simulator XCFramework, publish or stage it as a checksummed SwiftPM
binary artifact, and consume it from `nuxie-ios` without source-linking Cargo.
Through the proposed versioned C ABI, load a genuinely signed current artifact,
resolve real image/font assets, execute Luau and Nuxie host commands, present
with the Rust `wgpu` Metal surface, process UIKit pointer/text input, and return
ordered typed outputs. Extend the slice to two simultaneously live screen
sessions during a native transition, plus background/resume and surface
recreation. A mock renderer, offscreen readback demo, or direct Rust source
dependency does not close this ticket.

## #9: Acceptance and Rollout Contract

Blocked by: #2, #3, #6, #8
Type: Discuss

### Question

What evidence permits removing `rive-ios`, and how can the cutover be rolled
back safely?

### Answer

Resolved. Base the contract on runtime-neutral versions of the existing flow unit
and UI fixtures plus pixel/interaction traces, artifact compatibility,
multi-screen transitions, lifecycle/memory, crash isolation, performance,
binary size, and script-signature security. Dual-runtime comparison is limited
to development, CI, and reference tooling. Customer builds ship only the Rust
engine; there is no production engine fallback or mid-flow engine switching.

Runtime behavior, layout, text content, event ordering, and interaction traces
must match exactly. Pixel comparison may use only a small, documented tolerance
for GPU edge rasterization. Structural shifts, typography/color changes,
missing content, or broader pixel differences fail acceptance.

Performance is also a release gate, measured on representative production
flows on both the oldest supported iPhone and a current ProMotion device.
Compare time to first interactive frame, steady-state frame pacing, main-thread
work, CPU use, and peak resident memory against the current Rive implementation.
Establish the concrete non-regression tolerances from the Apple integration
prototype rather than inventing unsupported budgets before measurements exist.

Binary footprint is a release gate based on the runtime's incremental
contribution to a stripped customer app and its compressed IPA, compared with
the current Rive-backed build. Do not use the raw multi-platform XCFramework
archive size as the product metric; track it separately as a dependency
download and CI/developer-experience metric. Allow no material regression, with
the concrete tolerance established from repeatable prototype measurements.

There is no rollback requirement because the current SDK has no external
consumers. After the acceptance gates pass, cut over completely and delete the
Rive dependencies. During migration, Rive may exist only in development, CI,
or reference tooling long enough to produce comparison evidence; do not retain
a Rive-backed maintenance branch, replacement-release path, production engine
flag, embedded fallback, or mid-flow swap.

Run exhaustive compatibility checks across every currently deliverable flow
artifact for artifact-level trust validation, manifest and `.riv` import, asset
resolution, script initialization, and initial screen/session creation. Run
full pixel, event-order, data-binding, text-input, transition, lifecycle, and
interaction-trace comparisons on a curated golden corpus that covers every
runtime capability and important Nuxie flow pattern. The corpus must be
versioned and diagnosable rather than a small set of incidental examples.

Every `nuxie-runtime` artifact selected for an SDK release also requires a
repeatable physical-device qualification run. In addition to simulator CI, run
the render/interaction corpus, background and surface-recovery scenarios,
stress/soak tests, performance and memory measurements, and stripped-app/IPA
size measurement on the agreed oldest-supported and current ProMotion devices.
This is a runtime-release gate, not necessarily a per-commit device job.

## #10: Migration PRD and Implementation Slices

Blocked by: #9
Type: Discuss

### Question

What independently verifiable sequence lands the new runtime, migrates flows,
and deletes both Rive dependencies?

### Answer

Resolved in
`docs/runtime-migration/product-definition-and-migration-plan.md`. Implement
cross-repository vertical slices;
each slice ends in a runnable iOS reference fixture through the real Swift/C
ABI/XCFramework boundary:

1. checksummed XCFramework, ABI/version handshake, and onscreen `wgpu` surface;
2. trust-bearing import plus verified image/font assets;
3. typed ViewModels, UIKit pointer input, and phase-ordered runtime outputs;
4. sandboxed/resource-bounded Luau, Nuxie host commands, and native text input;
5. independent live screens, native transitions, lifecycle, and GPU recovery;
6. exhaustive artifact checks, golden behavior/performance/device qualification,
   production cutover, and deletion of `rive-ios`/C++ from the customer SDK.

Break each slice into smaller commits in the PRD, but never land a layer-only
pile that cannot demonstrate an end-to-end Nuxie behavior. The C++ reference
may remain in `nuxie-runtime` development/CI tooling; it must not remain linked
or packaged in `nuxie-ios` after slice 6.

# Rust Runtime to Apple Product Gap Analysis

- Status: research baseline
- Evidence date: 2026-07-18
- `nuxie-runtime` baseline: `eb0e2527dacd68cf55fc181d124cf619f7d11615`
- Comparison contract: [Current Nuxie iOS Renderer Contract](current-renderer-contract.md)

## Conclusion

`nuxie-runtime` is not an early rewrite that needs its engine rebuilt. Its
importer, runtime graph, state machines, data binding, text stack, Luau port,
and pure-Rust `wgpu` renderer already carry substantial C++-comparison and
pixel evidence. The missing work is concentrated at the product seam:

- there is no on-screen Apple `wgpu::Surface` path;
- the current C ABI intentionally links neither the Rust renderer nor Luau;
- artifact-level trust, verified external images, Nuxie Luau modules, bounded
  script execution, ordered result batches, and complete typed session output
  do not exist as a product API;
- the current raw handles have caller-managed lifetime and thread hazards;
- there is no iOS static library, XCFramework, ABI version contract, SwiftPM
  artifact, privacy resource, or device qualification lane; and
- the existing size and performance numbers are macOS/offscreen measurements,
  not evidence for the linked iOS customer product.

The migration should therefore extend the proven Rust engine behind a new,
product-shaped Apple ABI. It should not expose the current callback renderer
to Swift or build a Swift mirror of the Rust object graph.

## Status vocabulary

Every row below uses one of four states:

- **Present**: the capability is available through the current public Rust
  facade and has meaningful tests.
- **Present but unexposed**: the implementation exists in lower-level Rust,
  but the current `nuxie` facade and/or `nux-capi` cannot express what iOS
  needs.
- **Missing**: no implementation of the required capability was found.
- **Needs productization**: useful implementation exists, but its API,
  ownership, failure behavior, ordering, or Apple lifecycle is unsuitable for
  the shipping SDK.

These labels describe the pinned revision, not the difficulty of the work.

## Agreed product interface

This analysis assumes the following target rather than a generalized animation
SDK:

- `nuxie-ios` retains only its Nuxie-level `showFlow(...)` and
  `getFlowViewController(...)` public rendering entry points.
- Swift owns UIKit, `CAMetalLayer`, the display link, application lifecycle,
  native text controls, network/cache/hash work, journey state, and platform
  effect policy.
- Rust owns `.riv` import, runtime state, ViewModels, state machines, Luau,
  decoded runtime assets, the complete renderer, and `wgpu` encoding,
  submission, and drawable presentation through Metal.
- One immutable/rebuildable runtime context is shared by independent mutable
  per-screen sessions. A logical session can outlive and recover its surface.
- The first migration consumes the current `.riv` plus existing JSON contracts.
  It must not couple import to the current cache paths or pre-design `.nux`.
- There is no production Rive fallback or rollback runtime. Rive remains only
  temporary development/reference machinery until the hard cutover gates pass.

## What is already strong

### Import and runtime parity

The facade imports `.riv` bytes into both a `RuntimeFile` and an `ArtboardGraph`,
supports named/default artboard selection, creates borrowed and `Arc`-owning
artboard instances, advances nested artboards and data binds, and exposes state
machines, retained drawing, ViewModels, hit testing, world transforms, and text
geometry. The owning `OwnedArtboardInstance` is especially relevant to FFI: it
already proves that an instance can retain its file safely instead of relying
on a forged `'static` borrow.

The pinned status record reports:

- full import comparison: 263 exact files and 584 exact segments;
- scripted comparison: 27 exact files and 35 exact segments; and
- no remaining `not-yet` rows in those comparison lanes.

This is strong engine evidence. It is not yet current-Nuxie-artifact evidence:
the runtime CI compares against Rive runtime
`7c778d13c5d903b3b74eec1dd6bb68a811dea5f2`, while the current iOS binary was
built from a different pinned Rive line. Every deliverable Nuxie artifact must
therefore be imported and initialized through the new production seam before
cutover.

### Renderer parity

The Rust renderer is a retained, pure-Rust `wgpu` implementation, not a stub.
At the pinned revision its status is:

- contract-exact: 1,468 / 1,468 entries;
- decoded-RGBA byte-exact: 757 entries;
- divergent: 0; and
- gated: 0.

“Contract-exact” is the repository's primary, provenance-bound pixel contract;
it is intentionally not a claim of universal byte identity. The corpus covers
real `.riv` frames, upstream geometry streams, both MSAA and clockwise-atomic
paths, images, fonts, clipping, gradients, advanced blends, scripting, and
adversarial replay. Renderer R4 also records a same-adapter macOS C++
Dawn-versus-Rust `wgpu` comparison of 1.3718x by summed p50 with a 1.6431x
slowest row and zero deterministic counter-excess rows.

That evidence supports extending `wgpu` to an Apple surface before considering
a native-Metal renderer. It does not prove iPhone frame pacing, surface
acquisition behavior, main-thread cost, memory, thermal behavior, or customer
app size.

### Runtime primitives relevant to Nuxie

The lower layers already implement more of the current Nuxie contract than the
C ABI reveals:

- state-machine pointer IDs plus down, move, up, and exit;
- reported events with runtime identity, name, delay, and source-local index;
- deeply typed ViewModel contexts and binding for numbers, booleans, strings,
  colors, enums, symbol/list indexes, assets, artboards, triggers, lists, and
  nested ViewModels;
- linear-animation instances and state-machine `needs_advance` state;
- external font attachment with asset-kind and dual-parser validation;
- stable component slots carrying local ID, global ID, type, and name;
- text caret, hit, selection, world bounds, and world transforms; and
- a generic string-property write that dirties a `TextValueRun` for reshape.

Most of these are **present but unexposed**, not engine rewrites.

## Current `nux-capi` is a test/embed seam, not the Apple seam

The current C API has useful smoke coverage, but its crate configuration and
surface make its intended scope explicit:

- `crate-type = ["cdylib", "rlib"]`; there is no `staticlib` target.
- Its `nuxie` dependency uses `default-features = false`, so the C artifact
  contains neither `nuxie-renderer` nor `nuxie-scripting` by default.
- Drawing crosses a large caller-provided `NuxRenderCallbacks` vtable. Swift
  would have to implement paths, paints, buffers, images, decoding, state
  stack, clips, and every draw call. This is the opposite of the agreed
  Rust-owned renderer boundary.
- The API exposes file/artboard metadata, artboard advance/draw, state-machine
  creation and scalar inputs, a single implicit pointer, and ViewModel
  number/boolean/string setters. It has no product context, render session,
  surface, coarse frame operation, result batch, or recovery operation.
- Pointer down/move/up always use ID `0`; exit and cancel are absent.
- ViewModel getters, schema/instance enumeration, enum/color/trigger/list/
  image operations, list identity operations, recursive change observation,
  and origin metadata are absent.
- Reported events, typed event properties, state changes, script commands,
  player settled state, text-run lookup/mutation, and text geometry are absent.
- Import errors are collapsed to six `NuxStatus` values; underlying context is
  discarded and there is no structured diagnostic or last-error object.
- `NuxStringView` borrows the file. Handles are documented as not thread-safe.
- `NuxArtboardInstance` transmutes a file borrow to `'static`; release safety
  depends on the caller freeing every child before its file. Misuse aborts only
  in debug and can become use-after-free undefined behavior in release.
- The handwritten header has no ABI-version query, compatibility check,
  generated-layout verification, or runtime build provenance.

The right response is not to keep adding one C function for every Rust method.
Create a narrow context/session/surface ABI and leave the existing callback API
as low-level test/reference tooling if it remains useful.

## Capability and gap matrix

| Capability | Pinned status | Evidence in Rust | Production gap |
| --- | --- | --- | --- |
| `.riv` parsing and graph construction | **Present** | `File::import`, `RuntimeFile`, `GraphFile`; exact import comparison corpus. | Run the actual Nuxie deliverable corpus and return stable structured diagnostics. |
| Owning file/artboard lifetime | **Present** | `OwnedArtboardInstance` retains `Arc<File>`. | Use the owning model in product handles; do not carry the current C ABI transmute/lifetime contract forward. |
| Named/default artboard selection | **Present** | `artboard_named`, `default_artboard`, instantiate by index. | Bind exact artifact-screen names and report selection context in diagnostics. |
| Default state-machine selection | **Present** | Authored default index, otherwise state-machine index zero. | Fold into one session player-selection operation and parity trace. |
| First-linear-animation fallback | **Present but unexposed** | Core artboard exposes linear-animation instances; facade exposes animation count but no product fallback player. | Add default SM → SM 0 → animation 0 selection, advance, loop/settled semantics, and C ABI result. |
| Retained GPU renderer | **Present** | `WgpuFactory`, retained paint/path caches, MSAA and clockwise-atomic modes, complete renderer corpus. | Move it behind the product context/session; do not surface render callbacks to Swift. |
| On-screen Metal presentation | **Missing** | Renderer creates offscreen RGBA8 textures and returns or waits on them. | Export the renderer's retained Metal device, configure/acquire from Swift's `CAMetalLayer` on `MainActor`, and validate/wrap/submit/present each bounded drawable in Rust. |
| Resize, scale, detach, and surface-loss recovery | **Missing** | Offscreen factory dimensions are fixed at construction. | Reconfigure/recreate presentation resources while preserving logical session state. |
| Nonblocking frame submission | **Needs productization** | Async constructors/finish exist; no-readback benchmark finish still waits for submitted work. | Bound acquisition and in-flight work; eliminate per-frame CPU readback and indefinite `device.poll(wait_indefinitely())`. |
| Shared GPU/file context plus independent sessions | **Needs productization** | `Arc<File>`, retained caches, and cloneable/independent instances are available. | Define `FlowRuntimeContext` and `FlowRenderSession` ownership, two-live-screen behavior, and fresh state per presentation. |
| Embedded image decode/render | **Present** | Renderer factory decodes in-band images; image cases are in renderer goldens. | Convert failures to artifact/session diagnostics and share immutable decoded resources where safe. |
| Verified external image bytes | **Missing** | No facade/core equivalent of external font attachment was found for images. | Accept Swift-verified image bytes keyed by the imported asset's stable identity, decode/upload in Rust, and support dynamic image ViewModel values. |
| External font bytes | **Present but unexposed** | `OwnedArtboardInstance::attach_font_asset_bytes` validates asset ID/kind/font and affects shaping. | Expose through context/session import, cover nested artboards, reconcile stable `uniqueName` with asset ID, and return the font identity Swift registers with CoreText. |
| Runtime-owned networking | **Missing** | No product network loader is present; this is an intentional omission. | Keep it absent. Swift remains responsible for URLs, cache paths, hashes, MIME policy, and delivery of verified bytes. |
| Outer-artifact authorization | **Missing** | `File::import` keeps scripts inert; `import_with_unsigned_scripts` is a caller opt-in. Script envelope parsing does not verify signatures. | Add Nuxie-keyring verification/evidence bound to the exact manifest, `.riv` bytes, and asset table. Never expose a generic allow-unverified boolean. |
| All-or-nothing unauthorized behavior | **Needs productization** | Inert import exists and script mount preparation tries to avoid partial attachment. | Make visual-only unauthorized import an explicit result; create no module/protocol VM state on failed/missing artifact-level authorization. |
| Luau import/runtime | **Present** | `luaur` VM, bytecode structural validation, module/protocol registration, runtime bindings, and sandbox activation. | Enable it in the Apple artifact and integrate it transactionally with trusted import/session lifetime. |
| Internal Nuxie Luau extensions | **Missing** | `ScriptVm::lua()` can support binding work, but the facade uses `NoopScriptHost`; no `Nuxie.trigger`/`response.set` module or command queue exists. | Install a fixed allowlist of Nuxie modules/functions/types before sandboxing. Return `nil` and enqueue typed commands, including import-time calls. No public app registry. |
| Script instruction/work budget | **Missing** | No instruction interrupt/step budget was found. | Add a deterministic per-cycle ceiling and terminate only the affected flow on violation. |
| Script memory ceiling | **Missing** | No VM memory allocator/accounting limit was found. | Add a per-session VM cap, bounded recursive host values, and resource-limit diagnostics. |
| Full typed ViewModel engine | **Present but unexposed** | Lower runtime has typed source handles and nested/list/asset/artboard/trigger machinery. | Create a product schema/value/list API; do not mirror every Rust type into Swift. |
| Basic ViewModel facade/C ABI | **Needs productization** | Facade sets number/bool/string/enum; C API sets only number/bool/string and requires rebinding after mutation. | Add getters, complete types, instance/schema enumeration, identity-preserving list operations, batching, and one consistent binding model. |
| Runtime-originated ViewModel changes | **Missing** | Internal data-bind propagation exists, but no facade/C API change collector with origin/path/value/trigger identity was found. | Return recursive typed changes in ordered batches. Swift retains canonical journey state and echo suppression. |
| Reported event generation | **Present but unexposed** | `StateMachineReportedEvent` carries local identity, core type, name, and delay. | Resolve and serialize typed properties/OpenURL data, preserve authored order, and expose through session results. |
| Phase-ordered operation output | **Missing** | No single operation returns state changes, VM changes, events, script commands, dirty/settled state, and render outcome with phase/sequence metadata. | Add one coarse `advanceAndRender`-style operation and non-reentrant ordered result batch. |
| Pointer IDs and exit | **Present but unexposed** | Core state machine accepts ID-bearing down/move/up/exit. | Expose IDs plus down/move/up/exit/cancel; encode up/cancel-then-exit and immediate zero-delta behavior. |
| Pointer C ABI | **Needs productization** | C API sends down/move/up with hard-coded ID `0`. | Replace with batched product input; validate finite coordinates and session ownership. |
| Text shaping and geometry | **Present but unexposed** | World bounds/transform plus caret, hit, and selection geometry exist in facade. | Expose the smaller current native-input geometry contract with stable identifiers and shared presentation transform. |
| Named `TextValueRun` mutation | **Needs productization** | Slots retain names and `set_string_property` dirties text shape; the property key is internal. | Add first-class named lookup/write, ambiguity/not-found diagnostics, zero-delta wake, reshape, and redraw. |
| Dirty/settled state | **Present but unexposed** | State machine has `needs_advance`; advances return change booleans. | Aggregate animation, scripts, data binds, pending input/output, redraw, and surface state into session scheduling flags. |
| Structured diagnostics | **Needs productization** | Rust APIs use rich errors internally; C ABI discards them. | Stable domain/code/severity/operation/context fields, bounded message strings, recoverable/fatal classification, and Nuxie telemetry mapping. |
| Panic containment | **Needs productization** | Every current C entry uses `catch_unwind`, but release profiles use `panic = "abort"`. | Build the Apple artifact with unwinding enabled, catch every entry, and convert panic to fatal-session output without crossing C. |
| ABI versioning and compatibility | **Missing** | Crate version is `0.1.0`; no exported ABI version/query exists. | Export an explicit ABI major/minor and build provenance; Swift refuses incompatible binaries before creating handles. |
| iOS static library/XCFramework | **Missing** | No `staticlib`, Apple target build, module map, XCFramework, or SwiftPM binary artifact exists. | Publish immutable iOS device/simulator XCFrameworks and exact-pin their checksum from `nuxie-ios`. |
| Privacy manifest | **Missing** | No `PrivacyInfo.xcprivacy` exists in the runtime repository. | Audit actual Rust/wgpu/Swift API use and ensure the assembled Nuxie package contains the correct declaration after Rive is removed. |
| iOS simulator/device CI | **Missing** | CI covers macOS/Ubuntu Rust, C smoke, C++ comparisons, browser rendering, fuzz smoke, and linting. | Add iOS 15 compile/link, simulator integration, and repeatable physical-device qualification. |

## Critical design work

### 1. Turn the offscreen renderer into an Apple surface renderer

The current native `WgpuFactory` creates an instance with
`new_without_display_handle()`, requests an adapter with
`compatible_surface: None`, allocates a fixed `Rgba8Unorm` offscreen target,
and exposes finish paths that wait for GPU completion. The default finish also
copies and maps the entire target into CPU RGBA bytes.

The Apple path needs a distinct production lifecycle:

1. Swift creates and owns a UIKit view and `CAMetalLayer` on `MainActor`.
2. Rust creates the Metal `wgpu` device without touching the layer and returns
   a +1 retained `MTLDevice` through the product ABI.
3. Swift configures the layer on `MainActor` for BGRA8 presentation using that
   exact device. Resize and contents-scale changes update drawable size there;
   zero-size, detached, hidden, and background states do not acquire a frame.
4. Swift performs bounded `nextDrawable()` acquisition only when the display
   host has selected a coalesced frame, and retains the opaque drawable until
   the synchronous worker operation returns.
5. The serial Rust worker validates drawable dimensions, format, and device,
   temporarily wraps its texture through `wgpu-hal`, records the retained
   runtime draw, submits it, and schedules presentation. A one-shot Metal
   command-buffer completion releases Swift's drawable permit and records an
   asynchronous failure into device health. No layer pointer, externally
   reusable texture handle, or per-primitive callback crosses FFI.
6. Nil drawable, device loss, out-of-memory, validation, and presentation
   failure receive explicit policies. A command-buffer failure is returned by
   the next render operation without synchronously waiting for the GPU. Recoverable
   presentation changes preserve the artboard, ViewModel, Luau, input, and
   event state.
7. Acquisition and submission are bounded. A frame already in flight causes
   coalescing/skipping rather than main-actor blocking or unbounded queueing.
   Production presentation must not perform CPU readback or an indefinite
   `device.poll(wait_indefinitely())` per frame.
8. Two surfaces must render concurrently during UIKit transitions while
   sharing only safe immutable/device resources.

This is the highest-risk prototype because it exercises wgpu's real Apple
surface ownership and pacing rather than the already-proven offscreen pixel
path.

### 2. Replace a script bypass with trust-bearing import

The current Rust choice is binary: ordinary `File::import` leaves scripted
drawables inert, while `File::import_with_unsigned_scripts` lets the caller
declare the content trusted. The signed-content envelope parser only strips an
optional per-script signature; it explicitly does not verify it.

The target trust unit is the detached signature over the artifact-local
`nuxie-manifest.json`, not the unsigned outer `BuildManifest` and not each
inner script. A
production context-import transaction must therefore:

- accept the exact manifest bytes, signature/key identifier, `.riv` bytes, and
  verified asset identity table (or equivalent evidence that cannot be
  detached from those exact inputs);
- validate with Nuxie-owned trust roots and rotation policy, not a host-app
  replacement key or caller-provided “trusted” boolean;
- verify that the authorized manifest binds the imported `.riv` hash and
  supplied asset hashes/identities;
- return explicit `authorizedScripts` / visual-only state and diagnostics;
- register all modules/protocols and initialize concrete scripts only after
  authorization succeeds; and
- on missing, malformed, unknown-key, wrong-key, replayed, or tampered
  evidence, preserve the current visual-only behavior with no partial VM or
  script environment.

The first migration does not need an inner/per-script signature policy and
must not entangle import with current JSON paths. The same context import
should later be able to receive members extracted from `.nux` without changing
the runtime session model.

### 3. Make verified assets first-class import inputs

Swift already owns download, path safety, content type, declared size, hash,
required/optional policy, and cache resolution. Rust should receive bytes and
stable identities, never URLs or cache paths.

The runtime needs a typed asset table that can reconcile:

- Rive file-asset ID and stable `uniqueName`;
- Nuxie source key and manifest path where needed for dynamic image values;
- image versus font kind;
- verified bytes and content metadata; and
- required versus deliberately omitted optional assets for diagnostics.

External font attachment is a good starting primitive, but it is currently
instance-local and does not cover nested artboards. External image attachment
is absent. The product context should decode immutable images/fonts once where
safe, make them visible to all nested occurrences and per-screen sessions, and
keep mutable binding state session-local. The exact font bytes also remain
available to Swift for CoreText registration so runtime and UIKit text use the
same identity and metrics.

### 4. Build a coarse session protocol, not a broad object ABI

The ABI should expose opaque context, session, and surface handles with a small
set of operations:

- import/create context from `.riv`, asset table, authorization evidence, and
  internal runtime configuration;
- create a fresh session for a named artboard and default player policy;
- attach, resize, detach, and recover a Swift-owned Apple surface;
- apply a batch of canonical ViewModel/list/text/input/host mutations;
- advance and optionally render one cycle; and
- take one owned, phase-ordered result batch and structured diagnostics.

The result batch needs explicit sequence and phase fields so Swift can preserve
the current observable ordering instead of receiving an unordered collection.
It must be able to carry:

- player/state changes;
- typed recursive ViewModel changes with path and trigger identity;
- reported events with name, delay, typed properties, URL/target data;
- typed Nuxie Luau commands from both import and runtime execution;
- text/native-input geometry changes;
- dirty, settled, needs-render, and recovery state; and
- recoverable and fatal diagnostics.

Rust never calls Swift reentrantly. Swift delivers a completed batch on
`MainActor`, applies canonical-state and echo policy, validates platform
intents, and wakes the session later with asynchronous results.

The phase model must reproduce the pinned legacy ordering, including its
one-cycle delay for newly reported state-machine events:

1. fire runtime events already present in the delayed/event queue;
2. drain state-machine reported events that were queued before this advance;
3. advance the selected state machine or linear animation;
4. deliver state changes;
5. collect bound ViewModel listener changes;
6. emit the `didAdvance`-equivalent phase, where Nuxie updates bridge
   listeners, lays out native inputs, and drains Luau host commands FIFO; and
7. request/present rendering only after the mutation/output phases.

Reported events generated by step 3 remain queued for the next pre-advance
drain; eagerly returning them in the current batch would be an observable
ordering change. The rapid pointer path also needs its own trace: UIKit
ended/cancelled delivery sends up/cancel, then exit, then performs the private
zero-delta state-machine advance. That immediate advance drains prior reported
events and produces state/ViewModel changes, but does not emit the ordinary
`didAdvance` callback phase.

### 5. Productize Luau without making it an app plugin system

The current VM already installs Rive globals before calling the Luaur sandbox,
validates bytecode structure before the raw loader, and supports module
dependency retry. The Nuxie extension should use that same internal binding
point:

- install only Nuxie-owned allowlisted modules/functions/types;
- provide the current `Nuxie.trigger` and dotted `Nuxie.response.set` behavior;
- return `nil` and enqueue typed one-way commands;
- capture calls made during module/protocol registration as well as ordinary
  frame execution;
- use a recursive value envelope with explicit depth, entry-count, string, and
  total-byte bounds; and
- provide no public host-app registration API.

Sandboxing globals is necessary but insufficient. The VM also needs a
deterministic instruction/work limit for every import/advance/input cycle and
a memory cap for the session. A violation produces one fatal flow diagnostic,
destroys that session's script environment, and cannot terminate or stall the
host app.

### 6. Encode ownership, serialization, and recovery

All mutable runtime/GPU/Luau state is confined to one serial worker. Swift's
thin wrappers enqueue operations and never use a handle concurrently. The
display link remains a Swift clock; Rust does not create an independent
app-facing frame loop.

Product handles must encode these relationships:

```text
FlowRuntimeContext
├── FlowRenderSession A
│   └── replaceable Apple surface A
└── FlowRenderSession B
    └── replaceable Apple surface B
```

- The context owns parsed file data, trust result, immutable decoded assets,
  shared GPU/device resources, and worker ownership.
- A session owns independent artboard/player, bound ViewModel, Luau state,
  pointer state, event/output queues, and scheduling flags.
- A surface owns presentation configuration only. Detach/loss/recreate does
  not reset the session.
- Every presentation gets fresh sessions. No mutable user, response, script,
  navigation, pointer, or event state survives a prior presentation.
- Child teardown is submitted before parent teardown on the owning worker.
  A Swift wrapper cannot free the context out from under a session.

The existing `OwnedArtboardInstance` provides the right internal ownership
direction. The current C ABI's borrowed file plus transmuted lifetime does not.

### 7. Make panic containment real in release

`nux-capi` wraps every exported function body in `catch_unwind`, but both the
workspace `release` and inherited `release-size` profiles use
`panic = "abort"`. In those profiles a panic terminates the customer process
before `catch_unwind` can return a status. The current firewall tests run in an
unwinding development profile and do not prove the shipping behavior.

The Apple artifact must use an unwind-capable profile and enforce all of the
following:

- every exported C entry catches panic around the complete operation;
- no unwind ever crosses C/Swift;
- a caught panic poisons only the affected session/context as necessary and
  returns a stable fatal diagnostic;
- destructors and error extraction remain safe after poisoning;
- device callbacks or any Rust-owned worker path cannot panic outside the same
  containment boundary; and
- the unwind profile's stripped linked-app size and hot-path cost are measured.

This is defense in depth, not a substitute for the repository's panic-freedom
lint ratchet, hostile-input fuzzing, validation, and ordinary error returns.

## Apple packaging and ABI work

`nuxie-runtime` should own the low-level distributable artifact and
`nuxie-ios` should consume it as an implementation detail.

Required release output:

1. A Rust `staticlib` for `arm64-apple-ios` with iOS 15 as the minimum.
2. A simulator library containing `arm64` and `x86_64` slices.
3. A generated or mechanically verified C header plus module map.
4. One immutable XCFramework containing device/simulator libraries and public
   C headers, with debug symbols handled as an explicit release artifact.
5. An exported ABI major/minor query and runtime build/version/provenance query.
6. A repeatable build that verifies exported symbols, architecture slices,
   deployment target, link frameworks, no unexpected dynamic dependencies,
   and header/implementation agreement.
7. A published checksum consumed by an exact-pinned SwiftPM binary target in
   `nuxie-ios`. Customers run neither Cargo nor a Rust build plugin.

ABI rules:

- opaque handles only; no Rust layout crosses C;
- fixed-width integer representations and explicit enum discriminants;
- `(pointer, length)` byte/string inputs, never implicit ownership;
- caller-owned versus runtime-owned output buffers stated and tested;
- no borrowed result whose parent can disappear before Swift copies it;
- stable structured status and diagnostic codes, with messages supplementary;
- nullability and idempotent teardown specified; and
- explicit rejection of ABI-major mismatch before context creation.

Removing Rive also removes its bundled privacy manifest. The replacement must
audit the APIs actually used by the final Rust/wgpu/Swift implementation and
ship the corresponding `PrivacyInfo.xcprivacy` in the assembled Nuxie package.
This is an output-package gate even if the resource ultimately lives in
`nuxie-ios` rather than inside the static XCFramework.

## Evidence that does not yet transfer to the iOS product

### Size

The checked-in size report measures an `aarch64-apple-darwin` **cdylib**, not an
iOS static library linked into a customer app. Its table records roughly
2.6–2.8 MiB depending on scripting/profile; the later renderer status records
2,768,624 bytes without scripting and 2,935,728 with scripting. More
importantly, `nux-capi` sets `nuxie/default-features = false`, and the size
report itself notes that no real renderer is linked into that artifact.

Those figures are useful trend signals for parser/runtime/text/Luau. They say
nothing reliable about the production combination of renderer + wgpu Metal +
surface support + unwind runtime + static-link dead stripping. The product
gate is the incremental size of a stripped release customer app and its
compressed/thinned IPA contribution, measured against the same app linked to
the current Rive binary.

### Performance

The renderer's same-adapter macOS parity work is valuable evidence for GPU
algorithm and command-count maturity. It excludes:

- iPhone GPU/driver families and oldest-supported-device behavior;
- `CAMetalLayer` drawable acquisition and worker-side `wgpu` presentation;
- UIKit/display-link scheduling and two-surface transitions;
- main-thread time, first interactive frame, background/foreground, and
  surface recovery;
- on-device Luau, native text overlays, and asset bootstrap; and
- peak/steady memory, thermal behavior, and long-running leaks.

Do not invent acceptance thresholds from the macOS ratios. Calibrate release
gates on representative Nuxie flows using the current Rive-backed SDK as the
device baseline.

## Existing tests to preserve

The runtime already has unusually strong lower-layer evidence:

- C++ import/schema/runtime golden comparison;
- scripted import/runtime comparison;
- the 1,468-entry renderer golden contract;
- renderer fuzz replay with hostile numeric/path inputs;
- Rust workspace unit/integration tests;
- C API Rust tests and a compiled C smoke test;
- Luau boot, bytecode, corpus-script, renderer-binding, and ViewModel tests;
- browser WebGPU/WebGL2 smoke and pixel tests;
- panic-freedom lint gates; and
- macOS performance/counter tooling.

Keep those lanes. C++ may remain as a development/CI oracle inside
`nuxie-runtime`; it must not ship in `nuxie-ios`.

## Missing release evidence

Add product-level tests that the current lanes cannot supply:

- exhaustive import, trust, asset decode, Luau initialization, and initial
  session creation for every currently deliverable Nuxie artifact;
- wrong-key, unknown-key, missing-signature, tampered manifest, tampered
  `.riv`, tampered asset, replay/cross-artifact, and visual-only trust cases;
- checksummed SwiftPM XCFramework integration in the real `nuxie-ios` package;
- on-screen simulator and device rendering through the actual C ABI;
- golden visual and trace fixtures for player fallback, ViewModels/lists,
  reported events, Luau commands, native text, safe area, and transitions;
- phase/order traces including queued event → state-machine advance → VM
  change → script command → render request;
- stable pointer IDs, rapid same-cycle down/up, cancel, and up/cancel-then-exit;
- two live screens, cached offscreen session advance, settle/wake, resize,
  background/foreground with first delta zero, layer detach/reattach, surface
  loss, and device-loss recovery;
- repeated presentations proving no mutable state leakage;
- malformed/truncated/oversized FFI values, stale/wrong-parent handles, ABI
  mismatch, panic injection, and teardown under in-flight work;
- physical-device soak, memory growth, frame pacing, first interactive time,
  main-thread cost, CPU, and thermal runs; and
- stripped app plus compressed/thinned IPA size comparison.

A runtime release consumed by the SDK requires repeatable physical-device
qualification in addition to per-commit simulator/host CI.

## Prioritized production-seam prototype checklist

This prototype is a release gate, not a throwaway offscreen demo. It must use
the same C ABI and checksummed SwiftPM XCFramework intended for production.

### P0 — Packaging and failure containment

- [ ] Build unwind-capable iOS device and simulator static libraries with the
  renderer and Luau enabled.
- [ ] Assemble the real headers/module map/XCFramework and consume it through
  a checksummed SwiftPM binary target in `nuxie-ios`.
- [ ] Verify ABI-major negotiation, structured diagnostic round trips, owned
  output memory, thin Swift lifetime wrappers, and child-before-parent teardown.
- [ ] Inject a Rust panic through a release-equivalent entry and prove it
  returns a fatal session error without terminating the fixture app.

**Exit evidence:** a minimal iOS app launches on simulator and physical device,
links no Rive/C++ runtime, reports compatible ABI/provenance, and survives the
panic/lifetime negative suite.

### P0 — Real on-screen `wgpu`/Metal drawable path

- [ ] Host and configure a `CAMetalLayer` in a main-actor UIKit view, acquire a
  bounded drawable there, and prove Rust validates, wraps, submits, and
  presents it through `wgpu`/Metal without touching the layer.
- [ ] Render a real current Nuxie `.riv` through retained Rust resources with
  no CPU pixel readback and no per-draw Swift callback.
- [ ] Prove pixel-size/scale resize, detach/reattach to a replacement layer,
  temporary drawable unavailability, structured device failure, zero-size
  handling, command-buffer completion/error propagation, and ownership-aware
  deterministic destruction.
- [ ] Instrument acquisition/submission latency and show bounded in-flight
  work with display-link coalescing on a current ProMotion device.

**Exit evidence:** stable on-screen frames on the oldest supported iPhone and a
current ProMotion device, no unbounded main-actor stall, and no unbounded
operation or drawable growth.

### P0 — Trusted artifact, assets, and Luau through the real seam

- [ ] Import the current signed artifact-local `nuxie-manifest.json`, `.riv`,
  external image, and external font table as one trust-bearing context
  transaction.
- [ ] Require `nuxie-manifest.sig.json` with the expected key ID for the
  scripted qualification build; fail or alert publication when signing is
  expected but the signer instead produces an unsigned success.
- [ ] Render verified external images and matching runtime/UIKit font text.
- [ ] Prove valid authorization enables all scripts; missing/invalid/tampered
  authorization renders visually with zero module/protocol registration.
- [ ] Install the internal Nuxie module and return import-time and runtime
  `trigger`/`response.set` commands as bounded typed values.
- [ ] Prove instruction and memory limit violations terminate only the fixture
  flow.

**Exit evidence:** the production signed/scripted fixture behaves end to end,
and the complete trust/resource-limit negative matrix fails closed.

### P0 — Session behavior and ordered output

- [ ] Select the named artboard and prove default SM → SM 0 → animation 0
  fallback fixtures.
- [ ] Apply typed ViewModel snapshots and identity-preserving list mutations;
  return runtime changes with path, type, trigger identity, screen/instance,
  phase, and sequence.
- [ ] Deliver ID-bearing down/move/up/exit/cancel, including same-cycle
  down/up and zero-delta flush behavior.
- [ ] Return typed reported events and Nuxie commands in an ordered batch with
  no Rust-to-Swift reentrant callback.
- [ ] Mutate a named `TextValueRun`, reshape/redraw at delta zero, and place a
  native UIKit input from the same contain/center transform.

**Exit evidence:** one scripted interactive fixture matches the current Rive
visual, event, binding, text, and trace goldens through the actual ABI.

### P1 — Multiple sessions and lifecycle

- [ ] Create two independent sessions/surfaces from one context and render both
  during a native transition.
- [ ] Keep a detached cached session processing logical mutations without GPU
  drawing, then wake and reattach it without state loss.
- [ ] Pause every session in background, perform no wall-time catch-up, and
  resume with delta zero.
- [ ] Repeatedly create/dismiss presentations and prove mutable ViewModel,
  Luau, pointer, event, and response state never leaks.

**Exit evidence:** transition/lifecycle/soak traces and memory graphs remain
bounded on physical devices.

### P1 — Cutover qualification

- [ ] Run exhaustive current-artifact initialization plus the curated deep
  golden corpus on simulator and device.
- [ ] Compare release first-interactive time, frame pacing, main-thread time,
  CPU, peak/steady memory, and thermal/soak behavior against current Rive.
- [ ] Compare stripped linked-app and compressed/thinned IPA contributions.
- [ ] Verify the final package privacy manifest, deployment target, symbols,
  architectures, checksum, and absence of Rive/RiveRuntime/C++ customer code.

**Exit evidence:** every parity, reliability, performance, size, packaging, and
physical-device gate passes. At that point hard-cut to Rust and delete the Rive
dependency; do not add a production dual-runtime switch.

## Source index

All Rust links below are pinned to
`eb0e2527dacd68cf55fc181d124cf619f7d11615`.

- Public Rust facade, trusted-import bypass, owning artboards, ViewModels,
  fonts, text geometry, retained draw:
  [`crates/nuxie/src/lib.rs`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nuxie/src/lib.rs)
- Current C ABI and panic firewall:
  [`crates/nux-capi/src/lib.rs`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nux-capi/src/lib.rs)
- C ownership contract and callback renderer surface:
  [`crates/nux-capi/include/nux_capi.h`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nux-capi/include/nux_capi.h)
- C artifact type and disabled facade features:
  [`crates/nux-capi/Cargo.toml`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nux-capi/Cargo.toml)
- Wgpu offscreen factory, adapter selection, fixed targets, finish/readback and
  indefinite native poll:
  [`crates/nuxie-renderer/src/lib.rs`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nuxie-renderer/src/lib.rs)
- Renderer dependency/version:
  [`crates/nuxie-renderer/Cargo.toml`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nuxie-renderer/Cargo.toml)
- Renderer exactness and performance evidence:
  [`docs/renderer-status.md`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/docs/renderer-status.md)
- Core pointer IDs, exit, settled state and reported events:
  [`crates/nuxie-runtime/src/state_machine/instance.rs`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nuxie-runtime/src/state_machine/instance.rs),
  [`crates/nuxie-runtime/src/state_machine.rs`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nuxie-runtime/src/state_machine.rs)
- Core external fonts, component slots, text-run dirt and animation instances:
  [`crates/nuxie-runtime/src/artboard.rs`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nuxie-runtime/src/artboard.rs),
  [`crates/nuxie-runtime/src/objects.rs`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nuxie-runtime/src/objects.rs)
- Deep typed ViewModel contexts and list/binding machinery:
  [`crates/nuxie-runtime/src/view_model.rs`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nuxie-runtime/src/view_model.rs)
- Luau VM, sandbox and bytecode validation:
  [`crates/nuxie-scripting/src/vm.rs`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nuxie-scripting/src/vm.rs),
  [`crates/nuxie-scripting/src/vm/bytecode.rs`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nuxie-scripting/src/vm/bytecode.rs)
- Inner signed-content parsing without verification:
  [`crates/nuxie-scripting/src/envelope.rs`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/crates/nuxie-scripting/src/envelope.rs)
- Release panic profiles:
  [`Cargo.toml`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/Cargo.toml)
- Current size evidence and its stated renderer limitation:
  [`docs/SIZE.md`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/docs/SIZE.md)
- Current host CI and upstream reference pin:
  [`.github/workflows/ci.yml`](https://github.com/nuxieai/nuxie-runtime/blob/eb0e2527dacd68cf55fc181d124cf619f7d11615/.github/workflows/ci.yml)

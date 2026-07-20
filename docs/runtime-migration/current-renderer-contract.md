# Current Nuxie iOS Renderer Contract

Status: migration baseline
Evidence date: 2026-07-18
`nuxie-ios` baseline: `5116b9bb713b12d561a51de86d8096e71479ee84`

## Contract in one sentence

The current renderer is an internal, main-actor UIKit screen host that imports
one verified `.riv` file plus prepared image/font assets, creates an independent
Rive artboard/player/ViewModel/script session per flow screen, and translates
runtime output into Nuxie journey events, canonical ViewModel changes, native
text controls, navigation, and platform effects.

The migration must preserve that product behavior without preserving Rive's
public API or object model.

## Public product interface

Rive types do not escape the `Nuxie` module. The only public flow-rendering
entry points are:

- `NuxieSDK.showFlow(with:colorSchemeMode:)`, which asks Nuxie to present a
  flow; and
- `NuxieSDK.getFlowViewController(with:colorSchemeMode:)`, which returns a
  Nuxie `FlowViewController` for host-controlled UIKit containment.

There is no public Rive view, artboard, animation, state-machine input,
ViewModel, script, renderer, fit/alignment, or SwiftUI player API to preserve.
The Rust-backed replacement should stay behind the same two Nuxie-level entry
points.

Rendering is currently compiled only when both UIKit and `RiveRuntime` exist.
The package contract remains iOS 15 for rendering and macOS 12 for the SDK's
existing non-rendering loading/error behavior.

## Direct dependency surface

Only six production files directly depend on Rive:

| File | Current responsibility | Replacement responsibility |
| --- | --- | --- |
| `FlowScreenViewController.swift` | Imports the file, selects the artboard/player, attaches assets and scripts, owns the Rive view, advances it, and converts runtime events. | Own one thin Swift `FlowRenderSession`, one surface view, input delivery, result-batch delivery, and native overlay coordination. |
| `FlowViewModelBridge.swift` | Discovers Rive schemas, creates/binds instances, applies typed values/lists/triggers, listens for changes, and suppresses host-write echoes. | Move runtime schema/instance operations behind a coarse Rust session API; retain Nuxie path resolution, canonical-state coordination, origin tracking, and echo policy in Swift. |
| `FlowTextInputOverlayBridge.swift` | Builds and lays out `UITextField`/`UITextView` overlays, reads geometry from a runtime ViewModel, and writes named text runs. | Keep UIKit editing; obtain geometry and mutate named text runs through the Rust session. |
| `NuxieRiveScriptBridge.swift` | Registers `nuxie` host functions and queues script calls as renderer events. | Implement the allowlisted `Nuxie` Luau module in Rust and return typed host commands in ordered operation results. |
| `FlowViewController.swift` | Mounts the renderer, buffers commands until ready, exposes loading/error UI, and routes renderer output/platform effects. | Remains the Nuxie host and failure/policy boundary; change only its internal runtime adapter. |
| `FlowScreenTransitionCoordinator.swift` | Caches one screen controller per screen and performs native push/modal/fade/replacement transitions. | Remains UIKit-owned; cached controllers instead hold independent Rust sessions/surfaces sharing one immutable runtime context. |

Everything else around acquisition, journey execution, telemetry,
presentation, StoreKit, permissions, URL policy, and canonical response state is
already Nuxie-owned and should not be pushed into the runtime.

## Artifact-to-screen startup path

The observable startup contract is:

1. `FlowArtifactStore` downloads every server-manifest file into a cache using
   relative-path validation and declared byte-size checks.
2. It decodes `nuxie-manifest.json`, verifies `flow.riv` size and SHA-256, and
   prepares all declared runtime image/font assets.
3. Required asset failure aborts flow loading. Optional asset failure is logged
   and omitted.
4. It independently verifies `nuxie-manifest.sig.json`, an Ed25519 signature
   over the exact manifest bytes, against the Nuxie keyring. A missing, invalid,
   malformed, or unknown-key signature does not reject visual loading; it sets
   `scriptsEnabled` to false.
5. `FlowViewController` installs a `FlowScreenTransitionCoordinator` and asks it
   for the manifest entry screen.
6. The screen imports the same `.riv` bytes with CDN loading disabled, supplies
   the prepared asset loader and script runtime, selects the manifest's named
   artboard, and configures `.contain`, `.center`, autoplay.
7. It selects and binds the screen's flow-JSON-declared ViewModel instance where
   possible, falling back to the artboard's default ViewModel instance.
8. It creates and mounts the render view, builds native text overlays, pushes
   safe-area values, and forces `advance(0)` before showing content.
9. The host marks the flow ready, changes loading state to loaded, and flushes
   ViewModel/navigation commands that arrived while loading.

`FlowScriptTrustPolicy.production` is backed by an intentionally empty Nuxie
key ring in this audited checkout. That is a current provisioning gap, not the
desired trust model: with the empty keyring, production-default verification
always fails closed and scripts remain disabled.

## Required engine behavior

### Import and selection

- Import arbitrary bytes as the frozen current `.riv` format and return
  structured errors rather than crash.
- Resolve an artboard by the exact `FlowArtifactScreen.artboardName`.
- Preserve current player fallback: default state machine, then state machine
  index zero, then the first linear animation. `nuxie-ios` passes no animation
  name and relies on `RiveViewModel` selection behavior.
- Instantiate each screen independently even though every screen imports the
  same file today.
- Advance with a nonnegative elapsed delta and support an explicit zero-delta
  flush that processes pending state without consuming time.
- Report whether a session remains active/dirty or has settled so Swift can
  suspend its display link and wake it after input or mutation.

### Retained rendering

- Render the complete artboard through the Rust renderer and present through
  Metal.
- Retain immutable file, decoded asset, pipeline, and GPU resources where safe;
  do not replay a per-primitive Swift callback API every frame.
- Render two live screens at once during native transitions.
- Redraw after resize, scale, zero-delta mutation, surface recreation, or
  foreground resume even when the animation is otherwise settled.
- Preserve logical session state when only the Apple presentation surface is
  detached or rebuilt.

### State machines, input, and events

- Drive the selected state machine and linear-animation fallback.
- Accept stable pointer IDs and explicit down, move, up, exit, and cancel
  semantics in artboard coordinates.
- Preserve rapid pointer behavior: down and up can occur within one display
  interval; began sends down then an immediate zero-delta state-machine
  advance; ended/cancelled sends up/cancel, then exit, then the immediate
  zero-delta state-machine advance.
- Return state-machine reported events in authored order, including name,
  delay, typed properties, and OpenURL URL/target data.
- Never execute URL or other platform effects in Rust. Emit typed data/intents
  for Swift policy and actor routing.

### ViewModels and data binding

The current flow JSON carries ViewModel values and response schemas, but not
the complete typed runtime ViewModel schema. The `.riv` file is inspected for
runtime definitions, property types, instances and identity. Required
operations are:

- enumerate ViewModel definitions, instance names, property names, and runtime
  property types;
- create the default instance, a named source instance, or a blank instance;
- bind one instance to both artboard and selected state machine;
- resolve absolute and screen-relative slash-delimited paths;
- set/read string, number, boolean, enum, color, image, trigger, nested
  ViewModel, and list values;
- insert, remove, swap, move, replace, and clear list items while preserving
  item-instance identity;
- maintain authored `list_index` number properties after list mutations;
- resolve dynamic image values by source asset key, Rive `uniqueName`, or
  manifest path;
- listen recursively for string, number/list-index, boolean, enum, and trigger
  changes on the bound instance;
- identify runtime-originated changes as source `"rive"` today (renamed to a
  runtime-neutral source in the migration), including trigger identity; and
- suppress listener output while applying host-originated snapshots/mutations.

The reserved `safeArea` and `nuxieTextInputs` subtrees are host-written and do
not emit renderer-origin changes. Older flows may lack `safeArea`; that is a
tolerated unsupported capability, not a load error.

Swift's `FlowJourneyRunner` and `FlowViewModelStateCoordinator` remain the
canonical owner of journey values, persisted responses, and cross-screen
state during the `.riv` plus current JSON-contract phase. Per-screen Rust ViewModels are
typed replicas. Runtime changes travel to Swift with source/screen/instance
metadata; accepted canonical deltas are fanned back out without echo loops.

### Assets and fonts

The current artifact manifest declares images and fonts only.

- Runtime lookup uses stable Rive `uniqueName`; Swift has already resolved and
  verified the corresponding bytes.
- Required missing/corrupt/unsupported assets abort loading before import.
  Optional assets are absent from the supplied table and produce a diagnostic.
- Rust must decode images and upload them to its renderer. It must not fetch
  URLs or inspect Nuxie's cache layout.
- Rust must decode and shape supplied fonts. The same font bytes are registered
  through CoreText in Swift, and their PostScript name is used by UIKit text
  controls. Rendered and native text therefore must agree on identity, metrics,
  fallback, non-Latin text, and user-entered glyphs.
- Audio, Rive CDN loading, and a runtime-owned network cache are not part of
  the current contract.

### Luau and trust

- On-device Luau is required for unchanged scripted artifacts.
- The current bridge exposes `require("nuxie")` with `trigger(name, payload?)`
  and dotted `response.set(field, value)`. Both return `nil` and enqueue
  one-way commands.
- Script values crossing the current bridge are nil, boolean, number, string,
  arrays, and dictionaries. The replacement should define a typed recursive
  value envelope with explicit depth/size limits rather than pass Foundation
  `Any` across FFI.
- Host calls can occur while modules/protocol scripts are registered during
  import. They must be queued and returned after the operation; Rust must not
  call Swift reentrantly.
- The authorization unit is the detached artifact-level signature over
  `nuxie-manifest.json`, not the unsigned outer `BuildManifest`. Valid evidence
  allows all embedded scripts to register. Missing/invalid evidence allows the
  visual artifact but registers/executes no scripts and leaves no partial VM.
- A generic `allowsUnverifiedScripts` flag is not an acceptable production
  interface. The Rust import operation accepts explicit artifact authorization
  evidence and returns an authorization result/diagnostic.
- The VM must use restricted globals and an internal allowlist of Nuxie-owned
  native modules/functions/types. There is no public app extension registry in
  v1.
- Each cycle has a deterministic script-work/instruction ceiling and each VM a
  memory ceiling. Exceeding either terminates only the affected flow session.

### Named text runs and geometry

- Look up and mutate a named `TextValueRun`; the next zero-delta cycle must
  reshape and redraw it.
- Supply current runtime geometry for each published native input: x, y,
  width, height, rotation, scale X, and scale Y. Today these are read from the
  bound `nuxieTextInputs/...` ViewModel subtree.
- Supply artboard bounds and the exact `.contain`/center transform or the data
  needed for Swift to compute it once. Rendering, pointer inversion, safe-area
  mapping, and native overlay placement must use the same transform.
- Current migration parity does not require the richer caret/hit/selection API
  already present in Rust, but retaining it behind the internal runtime is
  useful for future native-input improvements.

## Required Apple-host behavior

### Surface and scheduling

- A main-actor UIKit view owns the `CAMetalLayer`, bounds, contents scale,
  window attachment, visibility, gestures/touches, and deterministic teardown.
- A window/screen-bound `CADisplayLink` supplies timestamps. The first delta is
  zero; later deltas are clamped nonnegative.
- Swift acquires at most one `CAMetalDrawable` on `MainActor` and enqueues it
  with one coarse `advanceAndRender` operation to the serial Rust worker. It
  does not use Swift callbacks to issue runtime draw primitives.
- A one-shot command-buffer completion releases the bounded drawable permit.
  Metal execution failure is recorded asynchronously and returned by the next
  render operation rather than blocking the current frame on GPU completion.
- Detach and layer unconfiguration stay behind every in-flight completion, and
  an ownership token prevents deferred teardown from clearing a replacement
  surface that has already configured the same layer.
- Work is bounded and coalesced. If a frame is already in flight, skip or
  replace stale work rather than block the main actor or queue unbounded frames.
- Backgrounding pauses all sessions without catch-up. The first foreground
  operation uses delta zero.
- A cached but offscreen logical session continues processing scripts,
  state-machine work, and host mutations while GPU drawing is suppressed. It
  sleeps once settled and wakes on input/data/runtime demand.

### One presentation transform

Only `.contain` plus centered alignment is a product feature today. Given view
size `(Vw, Vh)` and artboard size `(Aw, Ah)`:

```text
scale = min(Vw / Aw, Vh / Ah)
origin = ((Vw - Aw * scale) / 2, (Vh - Ah * scale) / 2)
viewPoint = origin + artboardPoint * scale
artboardPoint = (viewPoint - origin) / scale
```

Native input scale/rotation composes on top of this transform. Device safe-area
insets are mapped back into artboard units with the same letterbox correction.
No other fit or alignment modes need a public or internal generalized API in
this migration.

### Native text editing

UIKit remains responsible for:

- single-line `UITextField` and multiline `UITextView` selection;
- keyboard types, Return behavior, autocorrection, spell checking, autofill,
  secure entry, cursor/tint, and accessibility;
- max-length validation;
- placeholder, text alignment, font weight/style, line height, letter spacing,
  and CoreText-registered font selection;
- keyboard avoidance by translating the complete render surface and overlays;
- simultaneous gesture recognition so tap-outside dismissal does not steal
  Rive pressable input; and
- committing changed text on blur/Return as `$response_set` when the publisher
  supplied a response-field binding.

For non-secure fields UIKit text is visually clear while the runtime text run
renders the glyphs. Secure fields show UIKit's secure glyphs and set the
runtime text run to an empty string.

### Native transitions and screen topology

- The entry screen is the root of a navigation controller.
- Controllers are lazily created and cached by screen ID for the life of one
  presentation.
- Navigation supports immediate replacement, push/pop, page-sheet modal, and
  live cross-fade. Unknown/custom transitions currently become immediate
  replacement.
- Reduce Motion or an explicitly nonanimated spec turns push/modal/fade into
  immediate replacement.
- Push, modal, and fade can leave the old and new render surfaces alive at the
  same time. The runtime context must therefore support multiple independent
  sessions/surfaces.
- New screens receive the latest canonical snapshot before display and are
  flushed at delta zero after mounting/transition completion.

### Platform effects and policy

Swift, not the runtime, owns purchases/restores, notifications, camera,
location, microphone, photos, tracking authorization, URL validation and
opening, dismissal, navigation, analytics, and asynchronous result routing.
Rust emits typed commands only. An asynchronous result re-enters as a later
host event or canonical state mutation.

## Observable operation ordering

Ordering is part of parity. In the exact pinned `RiveView.advance(delta:)`
path, one cycle currently performs:

1. fire Rive's previously queued/delayed events;
2. deliver state-machine reported events already queued before this advance;
3. advance the selected state machine (or linear animation);
4. deliver state-change callbacks;
5. update the bound runtime ViewModel listeners;
6. notify `RivePlayerDelegate.didAdvance`;
7. in Nuxie's delegate, update bridge listeners, lay out text overlays, drain
   queued Luau host calls in FIFO order, and notify the parent controller; and
8. request rendering, which occurs after mutation/output delivery.

Reported events produced by step 3 are not delivered recursively inside that
same advance; they remain in the state-machine queue for the next reported-
event drain. The replacement must preserve this cycle boundary as well as the
within-cycle order.

Pointer began/ended/cancelled invokes a separate immediate state-machine
`advance(0)` with the same pre-advance reported-event behavior, state-change
callbacks and ViewModel listener update, but without the full display-advance
`didAdvance` callback. End and cancel send exit before that immediate advance.

The asynchronous Rust worker must not flatten this into an unordered event
array. Every coarse operation returns one phase-tagged, sequence-numbered
result batch. Swift delivers the completed batch on `MainActor` without a
reentrant callback from Rust or a background-thread delegate invocation.

## Lifetime and isolation contract

Target lifetime is more explicit than the current Rive object graph:

```text
Flow presentation
└── FlowRuntimeContext (shared immutable/rebuildable resources)
    ├── FlowRenderSession (screen A mutable state)
    │   └── Apple surface A (replaceable)
    └── FlowRenderSession (screen B mutable state)
        └── Apple surface B (replaceable)
```

- One `FlowRuntimeContext` owns parsed file data, verified asset identity,
  decoded immutable assets, shared GPU resources, and the serial worker.
- One `FlowRenderSession` owns one independent artboard, player/state machine,
  bound ViewModel, Luau state, input state, event queue, and dirty/settled state.
- A surface may detach/reconfigure/recreate without destroying logical session
  state.
- Every presentation starts with fresh mutable sessions. No ViewModel,
  response, Luau, input, navigation, or event state may leak from a previous
  presentation. Only immutable or explicitly rebuildable caches survive.
- Destroying Swift wrappers submits child-before-parent teardown on the owning
  worker. Invalid lifetime/thread use should be unrepresentable in Swift, not
  documented as caller-managed undefined behavior.

## Failure behavior

| Failure | Current observable behavior | Target requirement |
| --- | --- | --- |
| Unsafe/missing/downloaded artifact file, `.riv` hash/size mismatch | Flow load fails; error UI offers retry/close; telemetry records failure. | Preserve. |
| Required image/font unavailable, invalid, wrong hash/type/size | Flow load fails before rendering. | Preserve. |
| Optional image/font failure | Asset omitted with diagnostic; ordinary missing-asset rendering applies. | Preserve. |
| Missing/invalid artifact-level signature | Visual artifact can load; scripts do not register or execute. | Preserve explicitly. |
| `.riv` import, artboard, session, or binding bootstrap failure | Mount fails into the existing flow error path. | Preserve with structured engine codes/context. |
| A noncritical path/value/list operation cannot resolve | Operation returns false and usually logs; flow remains alive. | Preserve best-effort mutation semantics and diagnostics. |
| Script init/runtime/resource-limit failure | Current behavior is under-specified. | Fail the affected flow session closed; never leave partial script state. |
| Surface loss or resize | Rive view internally recovers/redraws where possible. | Preserve logical state and rebuild presentation resources; fail only if recovery is unrecoverable. |
| Rust panic | Not applicable to C++ runtime. | Catch inside every exported C entry using an unwind-capable Apple build; return a structured fatal-session error and never unwind into Swift. |

Failures are isolated to the affected flow/presentation. The runtime never
terminates the host app, invokes UIKit from Rust, or initiates an engine
fallback.

## Existing evidence and its limits

Useful current tests include:

- artifact cache/path/hash/required-vs-optional asset tests;
- Ed25519 valid/tampered/unknown-key/unsupported-shape tests;
- published font and moving text-input fixture import/mount tests;
- safe-area mapping and device UI matrices;
- ViewModel schema, scalar, nested, list, trigger, image, listener, and echo
  suppression tests;
- direct embedded-script import and scripted-pressable invocation tests with
  scripts both authorized and disabled;
- text overlay geometry, styling, keyboard, max-length, secure text, and commit
  tests;
- native transition spec/coordinator and UI smoke tests; and
- renderer-neutral event/navigation/binding trace encoding.

This is not yet a sufficient migration corpus. The checked-in host fixtures are
small and the trace schema does not encode frame pixels, pointer phases,
reported-event phases, surface lifecycle, or all typed ViewModel operations.
Acceptance therefore needs both exhaustive shallow import/bootstrap checks over
every currently deliverable artifact and a curated, versioned, feature-complete
golden corpus for deep pixel/interaction/order/lifecycle comparison.

## Source index

- Public APIs and platform minimums: `Sources/Nuxie/NuxieSDK.swift:656`,
  `Package.swift:6`
- Artifact acquisition/trust inputs: `Sources/Nuxie/Flows/FlowArtifactStore.swift:40`,
  `Sources/Nuxie/Flows/FlowManifestSignature.swift:5`,
  `Sources/Nuxie/Flows/RuntimeAssetStore.swift:40`
- Screen import/session/events: `Sources/Nuxie/Flows/FlowScreenViewController.swift:27`
- Typed data binding: `Sources/Nuxie/Flows/FlowViewModelBridge.swift:47`
- Native input overlay: `Sources/Nuxie/Flows/FlowTextInputOverlayBridge.swift:7`
- Luau host bridge: `Sources/Nuxie/Flows/NuxieRiveScriptBridge.swift:5`
- Flow host/platform effects: `Sources/Nuxie/Flows/FlowViewController.swift:319`
- Screen topology/transitions: `Sources/Nuxie/Flows/FlowScreenTransitionCoordinator.swift:5`
- Exact legacy scheduling/input order: pinned `rive-ios`
  `Source/RiveView.swift:373` and `Source/RiveView.swift:532`

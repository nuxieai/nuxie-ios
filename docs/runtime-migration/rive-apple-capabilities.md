# Rive Apple Capability Decomposition

Status: research baseline for the Nuxie Rust-runtime migration
Evidence date: 2026-07-18

## Conclusion

`rive-ios` is not just a Swift view around C++. It adds file and object
ownership, Apple GPU presentation, display timing, lifecycle policy,
coordinate conversion, UIKit input, native asset decoding and font fallback,
typed data-binding wrappers, event conversion, packaging, and a broad public
animation-player product.

Nuxie needs the first group, but it should not recreate the public Rive product.
The replacement is an internal flow host with a narrow split:

- Rust owns trusted `.riv` import, runtime objects, data binding, state
  machines, scripting, decoded runtime assets, the complete renderer, and
  `wgpu` surface presentation through Metal.
- Swift owns artifact acquisition and verification inputs, UIKit containment,
  `CAMetalLayer` lifetime, display timing, app/scene lifecycle, `.contain` /
  center coordinate mapping, native text controls, platform-effect policy,
  Nuxie journey orchestration, and thin lifetime-safe C-ABI wrappers.
- General animation SDK features that no Nuxie flow consumes are omitted.

## Exact provenance

These are three different revisions and must not be conflated:

| Item | Exact value | Why it matters |
| --- | --- | --- |
| `nuxie-ios` baseline | `5116b9bb713b12d561a51de86d8096e71479ee84` | Source consumer audited here. |
| Swift package pin | `nuxieai/rive-ios` `aa9be09f3cd995fcf826573e1ded605e545b5c44` | The revision in `Package.resolved`; it is a binary-only Swift package. |
| Binary artifact | `nuxieio/rive-ios` `26dc9047f39d488222e7e1a0de4d4092abc7e61f`, SwiftPM checksum `4998620385656b74529d9e8a6bb484becfea11c97846cf5cc35ad4413268ea0e` | The actual downloaded XCFramework. |
| Binary source | `nuxieai/rive-ios` `205bba2d47b9a8778316118815f4c3f99893d369` | Recorded by the artifact's `SOURCE_COMMIT.txt`; this is the source to use for behavior archaeology. |
| Rive C++ submodule in that source line | `.rive_head` = `fcbebb25e41ff16477bb48325bd5cd66d7f28038` | The underlying C++ runtime snapshot wrapped by the Apple layer. |
| Marketing/package version | `6.20.6` | Useful for release identification, but insufficient to identify fork behavior. |

The Nuxie fork adds 730 insertions and 12 deletions over its upstream Apple
base `84de24da`. The product-relevant commits are:

- `12c60d2c`: generic script host modules and functions;
- `80326ddc`: dotted names such as `response.set` installed as nested Luau
  tables;
- `205bba2d`: host opt-in to register otherwise-unverified embedded scripts.

The last item is the workaround the Rust migration must replace with a
trust-bearing import API.

## Capability matrix

| Area | What `rive-ios` adds above C++ | What Nuxie consumes today | Migration disposition |
| --- | --- | --- | --- |
| Import and ownership | Converts `Data` into a runtime span, owns the render factory, asset loader and scripting VM, maps import errors, and wraps file/artboard/runtime lifetimes. | Imports verified local `.riv` data with CDN loading disabled; looks up one named artboard per artifact screen. | Required. Implement trusted byte import and structured diagnostics in Rust; expose opaque, ownership-safe Swift handles. Omit bundle-name and remote-URL convenience loaders. |
| Player selection | Resolves named/default artboard, then default state machine, state-machine index zero, then first linear animation. It also exposes a generalized animation/state-machine player API. | Supplies artboard name and relies implicitly on the fallback chain; supplies no animation name. | Preserve the fallback chain unless the exhaustive artifact corpus proves a branch unreachable. Omit public animation controls. |
| Metal rendering | Supplies `MTKView`, renderer/context setup, drawable acquisition, command-buffer creation, presentation, resize handling and scale changes. | Every flow screen is a live Rive view. Native transitions may keep two screen views visible concurrently. | Required behavior, different implementation: Swift owns/configures `CAMetalLayer` and performs bounded drawable acquisition; Rust validates and temporarily wraps each drawable, then owns `wgpu` encode/submit/present. No per-draw Swift callback renderer. |
| Frame scheduling | Owns window/screen-bound `CADisplayLink`, timestamp/delta calculation, pause/autoplay/settled state, dirty redraw, visibility decisions and first-frame behavior. | Nuxie relies on automatic playback and explicit `advance(0)` flushes after setup, input and text mutations. | Required in Swift. Reuse window-bound display links, first delta zero, nonnegative delta, settled pausing, resize redraw and work coalescing. Pause on app background and do not catch up elapsed wall time. |
| Modern concurrency | Newer Rive APIs keep controller/display link on `MainActor`, run runtime/render commands on a background command server, use nonblocking bounded drawables, and layer teardown. | Not directly consumed; current Nuxie uses the legacy API. The new API also lacks the complete legacy runtime-event surface. | Architectural reference only. Copy the nonblocking shape and teardown discipline, not Rive's general command/listener/service hierarchy. |
| Fit, alignment and coordinates | Implements Rive fit/alignment matrices and inverse view-to-artboard conversion. | Hard-coded `.contain` plus `.center`; the same mapping drives rendering, pointer input, safe-area values and native text overlays. | Implement exactly this one transform and inverse. Do not port a public fit/alignment API. |
| Pointer input | Assigns stable touch IDs, converts UIKit coordinates, sends down/move/up/cancel/exit, advances by zero for rapid began/end/cancel, and allows recognizer coexistence. | Indirectly required by every pressable and gesture. Up/cancel followed by exit and same-frame down/up are observable. | Required. Expose pointer ID and explicit down/move/up/exit/cancel in the session ABI, with phase-order trace tests based on `RapidPointerEventTests`. |
| State machines | Selects and owns instances, exposes inputs, drives advance, and forwards state changes and reported events. | Uses authored state machines, runtime listeners and reported custom/OpenURL events; does not expose direct player inputs publicly. | Required internally. Omit generalized public SMI input/delegate façade. |
| Runtime events | Converts C++ events into Objective-C/Swift name, delay, number/string/bool properties and specialized OpenURL URL/target. | Converts them to `FlowRendererEvent` or a Swift-owned open-link request. | Required as typed, ordered output. Rust emits data/intents only; Swift retains URL/platform policy. |
| Data binding | Wraps ViewModel definitions, default/named/blank instances, typed nested paths, enums, colors, triggers, images, artboards, lists and change listeners. | Discovers schema from `.riv`; creates identity-preserving instances; binds artboard and state machine; applies snapshots and list operations; observes string/number/bool/enum/trigger changes. | Required, but through a product-shaped batch ABI rather than one Swift wrapper for every Rive class. Swift remains canonical for journey/cross-screen state during the current JSON-contract phase. |
| Images and other file assets | Adapts embedded/out-of-band assets, supplies native image/font/audio decoders, and includes a generic URLSession CDN loader. | Swift verifies image/font files and resolves them by stable Rive `uniqueName`; dynamic image ViewModel properties resolve source key, unique name or path. | Images/fonts and stable identity required. Keep Swift network/cache/hash policy and Rust decoding/GPU upload. Omit Rive CDN loading and audio. |
| Fonts and fallback | Decodes runtime fonts and supplies CoreText-backed system/fallback font behavior. | The same bytes feed rendered text and are registered through CoreText for UIKit input overlays. | Required. Preserve runtime shaping/fallback plus native PostScript identity so UIKit and Rust typography agree, including non-Latin/user-entered text. |
| Text runs | Exposes artboard bounds and named/nested `TextValueRun` lookup/set; a paused text write can force a zero-delta advance. | Text overlays read runtime geometry and write display text to named Rive runs; secure inputs hide the rendered run. | Required. Add named text-run lookup/mutation, errors and wake/redraw semantics to the Rust session ABI. |
| Native text editing | Rive supplies no native editor; this is Nuxie-owned UIKit code. | `UITextField`/`UITextView` own keyboard, selection, autofill, secure entry, multiline/max length, styling, keyboard avoidance and accessibility. | Keep in Swift. Rust supplies geometry, transform and text state only. |
| Audio | Creates an audio engine/listener and reacts to app activation for audio. | No audio exists in the current manifest model or checked-in Nuxie flow fixtures. | Omit from v1. |
| Scripting | Fork-only Swift/Objective-C bridge registers modules/functions, converts nil/bool/number/string/arrays/dictionaries with a depth limit, creates dotted nested tables, and exposes `allowsUnverifiedScripts`. | Requires on-device Luau plus `Nuxie.trigger` and `Nuxie.response.set`; host effects are queued and return `nil`. Current artifact-manifest verification is mapped to the Rive bypass. | Required in Rust. Replace the bypass with artifact-level evidence verification against the Nuxie keyring, an allowlisted Nuxie module registry, import-time command queuing, sandboxing, and work/memory limits. No public host-app module registration. |
| UIKit/SwiftUI/AppKit product layers | Supplies `RiveView`, `RiveViewModel`, UIKit/SwiftUI wrappers, AppKit/Catalyst/visionOS/tvOS support, fit/playback configuration and public delegates. | Public Nuxie rendering is only `showFlow(...)` and `getFlowViewController(...)`; macOS has no renderer. | Keep the two Nuxie APIs. Omit standalone SwiftUI/AppKit/player APIs and non-iOS rendering. |
| Lifecycle and teardown | Responds to window changes, scale/size/traits, maintains display links, and tears down view/controller/worker/runtime layers. Legacy background handling is audio-centric. | Flow presentation, screen caching/transitions, visibility and UIKit lifecycle depend on it. | Required, with stronger explicit scene background pause, zero-delta resume, surface/session lifetime separation, and child-first teardown encoded by wrappers. |
| Diagnostics | Maps import/selection/render errors, offers opt-in Rive logging and FPS diagnostics. | Nuxie has its own logging, artifact telemetry and flow failure/dismissal path. | Preserve structured engine diagnostics and Nuxie telemetry mapping. Omit public Rive logger/FPS APIs. |
| Accessibility | Provides a render surface but no authored semantic accessibility tree. | Native input controls are accessible; rendered UI has existing surface-level behavior. | Preserve current parity. Defer semantic remote-UI accessibility until `.nux` has an authoring contract. |
| Privacy resources | Packages `PrivacyInfo.xcprivacy`, including system boot-time reason `35F9.1` used by timing APIs. | Removing the binary framework also removes its bundled declaration. | Replacement package must carry correct declarations and validate the assembled SDK artifact. |
| Packaging | Ships a multi-platform dynamic XCFramework through a SwiftPM binary target. | `nuxie-ios` conditionally links it on iOS; customers need no C++ build. | `nuxie-runtime` must release an immutable device/simulator XCFramework; `nuxie-ios` exact-pins a checksum. Customers must not run Cargo. Track linked app/IPA impact, not raw archive size, as the product gate. |

## What Swift must bring over

The Swift port is deliberately small but not trivial:

1. A main-actor `FlowRenderSurfaceView` that owns the view/layer, window-bound
   display link, scale/size/visibility/background state, input capture and
   deterministic attach/detach teardown.
2. Thin ownership wrappers around `FlowRuntimeContext` and
   `FlowRenderSession`, all access serialized onto the owning Rust worker.
3. Exact `.contain`/center render and inverse-input mapping, including safe-area
   conversion and text-overlay geometry.
4. UIKit pointer identity/cancel/exit semantics and native text editing.
5. Phase-ordered result delivery on `MainActor`, translated to existing Nuxie
   flow events, ViewModel changes and platform-effect intents.
6. Artifact download/cache/path/hash/content-type work and preparation of
   signed import evidence plus stable asset identity tables.
7. Scene lifecycle, presentation/screen transitions, error telemetry and the
   two existing Nuxie public presentation APIs.

## What belongs in Rust, not Swift

- `.riv` import and compatibility diagnostics;
- verification of artifact-level authorization evidence before script registration;
- artboard/player selection, runtime state, state machines and linear fallback;
- complete typed ViewModel schema/instance/list machinery;
- reported events, pointer listener processing and named text-run mutation;
- Luau VM, allowlisted Nuxie modules, resource limits and queued host commands;
- external asset decode/runtime font shaping/GPU upload;
- retained renderer, `wgpu` Metal surface, command submission and presentation;
- session settled/dirty/wake information returned to the Swift scheduler.

## Explicit omissions

Do not port these merely because Rive exposes them:

- generalized animation, mixing, autoplay and direct SMI-input public APIs;
- public Rive-compatible Swift types or source compatibility;
- standalone SwiftUI/AppKit/Catalyst/visionOS/tvOS rendering products;
- remote CDN loading, networking, generic URL constructors or cache policy;
- audio;
- authoring/recorder APIs;
- public host-app Luau extension registration;
- public logger/FPS controls;
- every Rive fit/alignment mode;
- Rive's broad new concurrency object model.

## Reference behavior and tests worth porting

Port behavior rather than copying the whole Rive test suite:

- import/version/default selection: `RiveFileLoadTest`, `RiveModelTests`;
- out-of-band image/font loading and loader lifetime: `OutOfBandAssetTest`,
  `CDNFileAssetLoaderTest`, `RiveFontTests`;
- typed/nested/list ViewModels and listener clearing: `DataBindingTests` and
  concurrency `ViewModelInstanceTests`;
- coordinate transforms and rapid pointer sequences: `InputHandlerTests`,
  `RapidPointerEventTests`;
- first frame, settled/offscreen/resize behavior and drawable bounding:
  legacy `ViewTests`, `RiveControllerTests`, `DrawableTokenTests`;
- Nuxie fork behavior: the checked-in published fixture, script import,
  scripted pressable, ViewModel bridge, native text-overlay and runtime trace
  tests in `nuxie-ios`. The fork itself has no adequate custom-script bridge
  suite, so Nuxie's fixtures are authoritative.

## Primary source index

- Pinned package: [`Package.swift`](https://github.com/nuxieai/rive-ios/blob/aa9be09f3cd995fcf826573e1ded605e545b5c44/Package.swift)
- Binary source record: [`SOURCE_COMMIT.txt`](https://raw.githubusercontent.com/nuxieio/rive-ios/26dc9047f39d488222e7e1a0de4d4092abc7e61f/SOURCE_COMMIT.txt)
- Import/ownership: [`RiveFile.mm`](https://github.com/nuxieai/rive-ios/blob/205bba2d47b9a8778316118815f4c3f99893d369/Source/Renderer/RiveFile.mm)
- Player/view façade: [`RiveViewModel.swift`](https://github.com/nuxieai/rive-ios/blob/205bba2d47b9a8778316118815f4c3f99893d369/Source/RiveViewModel.swift)
- Legacy scheduling/input/events: [`RiveView.swift`](https://github.com/nuxieai/rive-ios/blob/205bba2d47b9a8778316118815f4c3f99893d369/Source/RiveView.swift)
- Asset adapter: [`FileAssetLoaderAdapter.mm`](https://github.com/nuxieai/rive-ios/blob/205bba2d47b9a8778316118815f4c3f99893d369/Source/Renderer/FileAssetLoaderAdapter.mm)
- Typed property surface: [`RiveDataBindingViewModelInstanceProperty.h`](https://github.com/nuxieai/rive-ios/blob/205bba2d47b9a8778316118815f4c3f99893d369/Source/DataBinding/RiveDataBindingViewModelInstanceProperty.h)
- Event conversion: [`RiveEvent.mm`](https://github.com/nuxieai/rive-ios/blob/205bba2d47b9a8778316118815f4c3f99893d369/Source/Renderer/RiveEvent.mm)
- Fork scripting: [`RiveScriptRuntime.mm`](https://github.com/nuxieai/rive-ios/blob/205bba2d47b9a8778316118815f4c3f99893d369/Source/Renderer/RiveScriptRuntime.mm)
- New display link/controller: [`DisplayLink.swift`](https://github.com/nuxieai/rive-ios/blob/205bba2d47b9a8778316118815f4c3f99893d369/Source/Concurrency/Utilities/DisplayLink.swift), [`RiveController.swift`](https://github.com/nuxieai/rive-ios/blob/205bba2d47b9a8778316118815f4c3f99893d369/Source/Concurrency/View/RiveController.swift)
- Privacy declaration: [`PrivacyInfo.xcprivacy`](https://github.com/nuxieai/rive-ios/blob/205bba2d47b9a8778316118815f4c3f99893d369/Resources/PrivacyInfo.xcprivacy)

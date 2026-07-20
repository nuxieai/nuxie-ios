# Slice 5 checkpoint — multi-screen lifecycle and recovery

Date: 2026-07-20

Slice 5 makes the Rust host the lifecycle owner for a complete flow
presentation. One verified artifact import creates one shared runtime context;
each live flow screen creates an independent session and Apple surface from
that context. There is no Rive runtime fallback or rollback path.

## Delivered

`nuxie-runtime` now:

- gives shared-context sibling sessions independent mutable state, output
  queues, surface ownership, failure state, and deterministic teardown;
- advances sessions without an attached drawable, reports settled state and
  bounded wake deadlines, and recreates a lost Apple surface without
  reimporting the artifact;
- contains Rust panics at every Apple ABI entry point and keeps a terminal
  session from corrupting its context or sibling sessions; and
- packages ABI 1.5 for iOS device and universal simulator with reproducible
  provenance, symbol, architecture, header, link, and archive checks.

`nuxie-ios` now:

- imports one fresh `FlowRuntimeContext` for every presentation and gives the
  transition coordinator one independently owned runtime session and
  `CAMetalLayer` surface for each lazily mounted screen;
- serializes navigation, native state, pointer, text, event, and host-command
  work so commands targeting a destination screen wait for its mount and
  activation;
- keeps cached and mounting controller ownership exact, suppresses stale
  callbacks, and does not report the flow ready until pre-ready navigation and
  command work has drained;
- makes artifact acquisition, native preparation, presentation cleanup, screen
  shutdown, and coordinator teardown cancellation-aware, joinable, and
  idempotent;
- orders cleanup as window dismissal, runtime shutdown, then window
  destruction, while preventing a cached controller or stale close callback
  from crossing presentation generations;
- pauses display-link work when a session is settled, resumes at authored wake
  deadlines, advances logical work while a screen is hidden without acquiring
  a drawable, and renders once when that screen becomes visible again;
- resets frame time across background and visibility gaps so foregrounding
  cannot inject a large animation delta; and
- performs one serialized detach, fresh-device reattach, and zero-delta redraw
  after device loss. A second consecutive device loss, out-of-memory outcome,
  fatal native result, or impossible ABI state follows the terminal flow
  failure path. Visible memory pressure cycles the surface immediately; hidden
  recovery remains drawable-free until presentation resumes.

## Failure boundary

Native containment is session-scoped: a failed screen cannot mutate or dispose
another session that shares its imported context, and it cannot affect a
different flow presentation. The product owner then deliberately treats an
unrecoverable screen failure as an unrecoverable failure of its owning flow,
tears down that flow's coordinator, and reports the existing flow error. Slice
5 does not promise that sibling screens in the same failed flow remain
interactive.

## Qualification status

The focused runtime-host, display-host, and text-overlay suite passed 87 tests.
The full iOS SDK suite passed 744 tests while linked directly against the
packaged simulator slice rather than only compiling the fake adapter. The
standalone onscreen reference app passed both UI smoke tests and its binary
audit confirmed that the Rust runtime was linked while Rive was absent. The
macOS SDK build succeeded and all 601 macOS unit tests passed. No qualification
suite reported a failure or skip.

The verified ABI 1.5 artifact was built from clean runtime revision
`c1ee86b7efebc616918a185bf32ce0688ccf0427` with Swift Package checksum
`02f1083cfe7490c5d2d06f2fbd5aeb7e589ece42ce33ccc99ecd84166447f717`.
Its declared runtime version is `0.1.0`, minimum deployment target is iOS 15,
and its provenance records Rust 1.94.1, Xcode 26.6, and the iOS 26.5 SDK.

## Remaining gates

- Run the signed publisher-to-SDK corpus once the publisher signing key and
  matching SDK trust root are provisioned.
- Capture the authorized physical-device performance, memory, background,
  recovery, soak, and app/IPA-size evidence.
- Enable immutable GitHub releases for `nuxie-runtime`, publish the qualified
  archive from the protected release tag, and anonymously verify the exact
  URL and checksum before merging the package cutover.

## Next checkpoint

Slice 6 removes `rive-ios`, every production `RiveRuntime` import, the fork-pin
workflow, and obsolete Rive-only bridges and fixtures. It exact-pins the
qualified `NuxieRuntime` binary, retains a local staged-artifact path for
development and CI qualification, adds Nuxie's own privacy manifest, and
audits the clean package/application link for Rive and C++ artifacts. The
future `.nux` container remains a separate phase after this migration.

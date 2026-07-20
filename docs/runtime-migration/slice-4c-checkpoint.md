# Slice 4C checkpoint — native text input on the Rust runtime

Date: 2026-07-19

Slice 4C removes the last Rive-specific live text-input operations from the
screen host. UIKit still owns editing, selection, keyboard, autofill,
secure-entry, and accessibility; `nuxie-runtime` now supplies authored geometry
and applies named text-run mutations.

## Delivered

`nuxie-runtime` now:

- exposes one atomic ABI 1.5 text-run batch operation with exact root-level run
  names, bounded UTF-8 input, all-or-nothing validation, clean unchanged
  results, and immediate redraw scheduling after a mutation;
- imports both publisher-era ViewModel instances serialized before Backboard
  and the newer post-Backboard ID form;
- resolves typed property paths through active imported as well as generated
  nested ViewModel selections; and
- proves the compatibility behavior with the actual published text-input
  fixture plus a synthetic three-level nested-value regression.

`nuxie-ios` now:

- makes `FlowScreenViewController` a Rust-session screen host with a
  `CAMetalLayer` surface, bounded display scheduling, UIKit pointer routing,
  canonical state reconciliation, ordered events/host commands, and
  deterministic teardown;
- binds the existing UIKit text fields to the runtime bootstrap catalog and
  value arena, then consumes ordered state/ViewModel changes without exposing
  reserved native-control geometry to journey state;
- projects authored position, size, rotation, and scale through the shared
  contain-center transform and preserves provisional zero geometry until the
  first usable layout arrives;
- sends user edits through the serialized display-host lane as named text-run
  batches and keeps missing run names or invalid local requests recoverable;
- retains the existing CoreText font identity, placeholder, selection,
  autocorrection, content-type, secure-entry, keyboard, submit, response, and
  accessibility behavior; and
- classifies malformed native results, impossible ABI statuses, startup
  failures, and surface failures as terminal while keeping bounded host input,
  missing authored names, and Swift-owned request validation operation-local.

The screen-level implementation intentionally lands before the transition
coordinator creates and mounts independent sessions. On this stacked branch a
production-created screen has no runtime session yet; Slice 5 closes that
integration immediately rather than preserving a dual Rive/Rust or rollback
path.

## Qualification status

The packaged ABI is exercised from Swift, not a test double. The published
`text-input-motion` artifact imports with its authored 390×844 artboard and its
nested input geometry is present in the creation bootstrap at exactly 294×24.
After the required zero-delta first advance, a named edit succeeds, a missing
run returns the operation-local `notFound` status, and a subsequent valid edit
succeeds on the same session.

Focused adapter, native-result, display-host, frame-clock, state-bridge,
text-overlay, journey-runner, and fixture-trace suites are green. Startup and
terminal-drain regressions verify that every accepted completion resolves once
and terminal callbacks cannot recursively admit more work.

The verified ABI 1.5 artifact was built from clean runtime revision
`51fb11f75227d31e780ff2dd46c8d6fd2763a2eb` with Swift Package checksum
`f043e8038516b31afbaba695e470555239258e13e6e7c07d589a56c9d5b2da35`.

## Next checkpoint

Slice 5 gives the transition coordinator one shared imported runtime context
and one independent Rust session/surface per live screen. It finalizes
background/resume, resize, detach/reattach recovery, memory pressure, settled
wake behavior, deterministic shutdown, and isolated terminal failure handling.

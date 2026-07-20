# Slice 4B checkpoint — bounded Luau host work and listener actions

Date: 2026-07-19

Slice 4B replaces the Rive-specific native-module workaround with a private,
bounded Nuxie Luau extension and carries its effects through the typed Apple
session protocol. Native text mutation remains the next Slice 4 checkpoint.

## Delivered

`nuxie-runtime` now:

- exposes a readonly, allowlisted `require("nuxie")` module only inside an
  authenticated per-session VM, with `trigger` and `response.set` as the first
  one-way host APIs;
- normalizes Luau values into a closed Boolean/finite-number/string/array/object
  vocabulary, emits typed FIFO `HostWork`, and includes commands produced
  during module registration and listener initialization in creation cycle
  zero;
- retains authored scripted-listener inputs and hydrates scalar, trigger,
  artboard, root-context, and ViewModel bindings before `init`; a detached
  last-applied source epoch is then flushed exactly once at the start of each
  advancing player cycle, so callback writes stay pending until the next
  Rive-compatible boundary and never rehydrate inside an authored action FIFO;
- applies the product-needed stateless built-in converter subset to scripted
  inputs, including cross-type and authored converter-group evaluation, while
  explicit broken references and scripted or occurrence-stateful converters
  fail closed instead of silently becoming pass-through bindings;
- applies fixed per-VM memory and per-runtime-cycle safepoint, command-count,
  command-content, identifier, string, depth, node, edge, and aggregate-value
  limits; protected Luau calls cannot swallow resource exhaustion;
- treats resource exhaustion as terminal only for the affected session, rolls
  back every partial host effect and state mutation, and gives the Apple host a
  stable `nux_runtime.script_resource_exceeded` diagnostic;
- validates surface attachment and presentation readiness before advancing the
  core, while terminalizing every fallible post-commit draw, present, transform,
  or result-projection failure so committed HostWork can never be silently
  drained and followed by a live session;
- projects every bootstrap and operation result through the exact shared Apple
  value-arena limits before crossing FFI, with
  `nux_runtime.result_limit_exceeded` for an aggregate overflow; and
- advances each pointer event as its own bounded subcycle while preserving
  FIFO output order and atomic rollback for the enclosing operation; and
- projects each pointer callback's actual event timestamp and the prior
  delivered position for that listener group and pointer ID, including
  reset-on-enter/re-entry plus Up-to-Exit ordering and release, rather than the
  old constant-time/current-position placeholders.

The Apple product ABI is now 1.4. Host commands use the result-owned value
arena and require one canonical schema-less object root; malformed, aliased,
cyclic, oversized, non-finite, runtime-identity, or noncanonical values are
rejected before Swift sees them.

`nuxie-ios` now:

- copies typed host values before freeing native results and preserves the
  ABI's full finite `f64` result domain while keeping outbound property writes
  within the runtime's `f32` domain;
- keeps object identity and ordering byte-exact for canonically equivalent but
  differently encoded Unicode keys;
- retains the complete creation result, including cycle-zero HostWork, and
  rejects a session creation result that omits its bootstrap; and
- forwards `UITouch.timestamp` and a monotonic hover timestamp through the
  ABI's validated finite, nonnegative `f32` event-time domain; and
- provides a renderer-neutral FIFO host-command router that preserves output
  sequence/cycle/phase metadata and the existing screen, component, element,
  and instance metadata aliases without invoking application code from Rust.

## Locked limits

- VM memory: 16 MiB per session
- Script safepoints: 100,000 per runtime cycle
- Host commands: 256 per runtime cycle
- Host-command content: 4 MiB per runtime cycle
- Host-value depth: 32
- Host-value nodes: 4,096 per value and in aggregate per runtime cycle
- Host-value edges: 16,384 per value and in aggregate per runtime cycle
- Host identifier: 4 KiB
- Host string: 1 MiB
- Host value: 4 MiB aggregate

The result seam additionally enforces the ABI-wide shared value arena and
operation-payload limits; individually valid output trees cannot evade those
aggregate bounds.

## Qualification status

The cold Rust qualification is green: 65 `nuxie-scripting` tests, 134
`nuxie-runtime` tests, 104 facade/integration tests, and 73 Apple-runtime tests,
plus no-script and scripting feature checks, the C header smoke, and the
release-profile panic-firewall smoke. The strict workspace-wide Clippy command
remains blocked by the repository's existing runtime lint backlog; the changed
`nuxie-scripting` package passes its strict no-dependency Clippy gate.

Swift qualification is also green: 56 focused adapter, fixture-trace,
native-result, and state-bridge tests; all 651 iOS unit tests; all 587 macOS
unit tests; and the universal macOS framework build. The focused suite links
the packaged native library rather than a test double.

The verified ABI 1.4 artifact was built from clean runtime revision
`b0edb68e7e525910ddb2b863add9b9e739034fc0` with Swift Package checksum
`beb61ffafe2f70830c4a0d895ad43c04374d23bb7cf2957d551d0515486df182`.

## Next checkpoint

Slice 4C exposes named text-run mutation and native-control geometry through
the product session ABI, then replaces the Rive-specific calls inside the
existing UIKit text-input overlay while retaining keyboard, selection,
autocorrection, autofill, secure-entry, accessibility, CoreText identity, and
response semantics.

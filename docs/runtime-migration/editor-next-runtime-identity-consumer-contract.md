# Editor Next exact-runtime consumer contract

Date: 2026-07-26

This checkpoint defines the iOS consumer side of Editor Next's native runtime
cutover. It is a source contract, not an artifact release record. The SDK
source may be reviewed and tested with a locally staged candidate, but it must
not replace the published runtime pin until an immutable Apple release has
been independently verified.

The reviewed consumer binds exactly to runtime version `0.2.0` at source
revision `b1f58004332a73564ffdd9f8585838209604c4d1`. It calls
`nux_runtime_bind` with both complete UTF-8 identities and passes the returned
opaque proof to `nux_flow_runtime_context_create_bound`. A mismatch is a
terminal typed consumer error. Swift does not query, compare, retain, display,
or negotiate a separate ABI major/minor version.

## Breaking internal contract

The screen-session selector is now one typed value:

| Previous internal shape | Current exact-runtime shape |
| --- | --- |
| optional `stateMachineName` | `.default` |
| nonempty `stateMachineName` | `.stateMachine(named:)` |
| no linear-animation selector | `.linearAnimation(named:)` |

There is no legacy descriptor fallback or dual encoding. The Swift adapter
keeps the selector typed until the C boundary, owns the selected UTF-8 bytes
for the duration of the call, and encodes only the current selector constants.
An empty explicit player name is rejected rather than being interpreted as the
authored default.

Configured-session descriptors and session operations use the current header
layouts without compatibility fields. Exact runtime binding happens before
context creation. Result decoding still requires the exact player kind,
selection, and index relationship, including the explicit linear-animation
result. Unknown or contradictory values fail closed.

This does not add an application-facing SDK selector. Production screens use
the authored default player. Exact selectors are carried by the internal
screen-presentation value and by the native qualification fixture host.

## Live and fixed presentation

Every screen presentation has two independent choices:

- a typed player selector; and
- either the production `.live` timeline or a deterministic
  `.fixed(elapsedSeconds:)` timeline.

Fixed presentation is a native capture contract, not a timer approximation.
The host advances to the requested timestamp, requires both runtime render
outcome and surface disposition to report `presented`, waits for the submitted
Metal drawable to complete, and only then publishes fixed-frame readiness.
The production display link, runtime wake deadlines, and offscreen tick loop
cannot advance a fixed presentation.

Any change that can invalidate the pixels creates a newer fixed-frame
generation. This includes geometry, visibility, text, state, pointer input,
application or matching-scene lifecycle transitions, memory pressure, and
recoverable device loss. A stale in-flight generation cannot publish
readiness. Foreground reactivation requires an exact zero-delta redraw at the
same fixed timestamp, and readiness remains false while the screen is not
presentable.

The fixture launch contract is fail closed:

- `--nuxie-player-kind` is exactly `default`, `state-machine`, or
  `linear-animation`;
- named selectors require `--nuxie-player-name`, while `default` forbids it;
- `--nuxie-fixed-timestamp` must be finite and nonnegative; and
- all fixed arguments require one exact `--nuxie-initial-screen`.

The staging script validates the player and timestamp against the visual
corpus before replacing any destination fixture. UI capture waits on the
`fixed-frame-ready` accessibility state; it does not sleep for wall time.

## Qualification boundary

The source consumer is qualified with focused adapter, result-decoder,
fixed-frame lifecycle, native artifact, fixture staging, and UI-host build
tests. The exact P17 production corpus remains the cross-repository behavioral
oracle.

For LOC-015, LOC-016, and LOC-017, one locally staged, hash-addressed
`NuxieRuntime.xcframework` built from the exact reviewed source revision is the
artifact under test. The LOC targets validate that identity and use the staged
framework instead of downloading over it. They do not require a separate ABI
version, release tag, public URL, or publication step.

Distribution remains a downstream packaging concern outside this consumer
contract. The staged framework must not be committed, and an unrelated
published SwiftPM URL or checksum must not be presented as evidence for the
exact runtime tested here.

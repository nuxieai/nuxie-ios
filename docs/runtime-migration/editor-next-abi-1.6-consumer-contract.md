# Editor Next ABI 1.6 consumer contract

Date: 2026-07-25

This checkpoint defines the iOS consumer side of Editor Next's native runtime
cutover. It is a source contract, not an artifact release record. The SDK
source may be reviewed and tested with a locally staged candidate, but it must
not replace the published runtime pin until an immutable ABI 1.6 Apple release
has been built from the final repaired runtime revision and independently
verified.

## Breaking internal contract

The screen-session selector is now one typed value:

| Previous internal shape | ABI 1.6 shape |
| --- | --- |
| optional `stateMachineName` | `.default` |
| nonempty `stateMachineName` | `.stateMachine(named:)` |
| no linear-animation selector | `.linearAnimation(named:)` |

There is no legacy descriptor fallback or dual encoding. The Swift adapter
keeps the selector typed until the C boundary, owns the selected UTF-8 bytes
for the duration of the call, and encodes only the ABI 1.6 selector constants.
An empty explicit player name is rejected rather than being interpreted as the
authored default.

The configured-session floor moves from ABI 1.5 to ABI 1.6. A linked artifact
whose major version differs or whose minor version is below 6 is rejected
before session creation. Result decoding likewise requires the exact player
kind, selection, and index relationship, including the new explicit linear
animation result. Unknown or contradictory values fail closed.

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

## Qualification and release boundary

The source consumer is qualified with focused adapter, result-decoder,
fixed-frame lifecycle, native artifact, fixture staging, and UI-host build
tests. The exact P17 production corpus remains the cross-repository behavioral
oracle.

P18 is a separate, mandatory distribution step. Before this source can land:

1. publish an immutable Apple XCFramework whose header and implementation
   expose ABI 1.6 from the final repaired runtime source SHA;
2. record the release tag, source SHA, public URL, archive checksum, slices,
   deployment target, and ABI probe results;
3. update `Package.swift` and the Makefile artifact metadata together to that
   immutable release;
4. rerun the unchanged ABI 1.6 adapter and native corpus gates against the
   downloaded archive; and
5. preserve the release evidence in a subsequent checkpoint.

Until that release exists, local `.artifacts/NuxieRuntime.xcframework` staging
is qualification-only. It must not be committed, and the existing ABI 1.5
SwiftPM URL and checksum must not be presented as satisfying this contract.

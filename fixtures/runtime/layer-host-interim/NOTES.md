# Interim layer host

This is an interim stand-in for [UNIV-5113](https://universe.basis.dev/issue/UNIV-5113)'s publisher output. Replace it with
published output when that work lands. It is not a signed release.

The source is `fixtures/journeys/rendered-custom-transition`. Both Screen
artboards, assets, interaction listeners, transition timelines and forward and
reverse completion events are preserved. The lossless post-processor splits
Runtime into distinct Screen root types, disables Screen clipping, preserves
each Screen's default interaction machine, and appends LayerList with a fill
LayoutComponent above its screens ArtboardComponentList. Its style selects a
stack (layoutTypeValue 2), fills both axes and uses alignment 0. The list's
ArtboardComponentListOverride selects every artboard (artboardId -1), sets both
scale types to fill and both sizes to -1. The root has an explicit stack style
as well. Root schema LayerHost has an empty screens list.

Readback properties rowWidth and rowHeight measure the mounted Screen size.
rowX and rowY read its computed root origin.
markerX reads a two-second 0 to 1000 timeline on each default machine, so a
remount can be distinguished from a retained machine. keptValue is unbound data
for retention assertions. These probes do not replace the published motion.

Regenerate with the script recorded in provenance.json. It uses the read-only
runtime definitions recorded there by its source and embeds the source's exact
font and image bytes. Tests build an AuthenticatedRuntimePayload directly.
The native suite list in scripts/bazel/sdk.py and fixtures/README.md register
this fixture; this checkout has no fixtures/MANIFEST.json.

The original control event has nuxieTrigger and componentId but no actionId.
The attribution test preserves that payload. It must reach row B's router,
which still rejects the incomplete generated control envelope, as on the old
Screen path. This does not qualify the publisher's current action generation.

format-cases.json pins the provisional release grammar across SDKs. Published
magic-move requires a transitionId. push, fade and none keep it optional.

Stage 1b applies the proposed Rive-native sizing recipe. On the staged
apple-runtime-v0.10.16 it still fails: both rows read 0 by 0 under a 510 by 710
root, A is at (0, 0) and B is at (0, 710). Adding an explicit root style did not
resolve it. testMountedRowsFillResizedRoot keeps strict expected failures for
size and overlap. The top-row control test and resized-frame pixel comparison
also expose the changed geometry as plain failures. This is not qualified
publisher output, and no SDK sizing workaround is applied. A publisher must
verify measured row sizes, overlapping origins, input and draw order against
the shipping runtime, not only the presence of these serialized fields.

The separate lifetime tests remain plain failures. A successful list remove
followed immediately by a positive-time step produces nux_capi.limit_exceeded
when the removed row's default-machine marker writes through its binding.
A zero-time detach followed by a timed step passes, but is not used as an SDK
workaround. The native-only removal-probe-*.riv scenes isolate this from the
layer actor, Journey, assets and published transition motion. Each has two
distinct row types and a host list. quiet has no output bindings, readback
binds computed width only, marker binds the animated node's x only, and active
binds both to separate number properties. A calibration test proves these
bindings run. Their sizes and hashes are in provenance.json.

The handoff ios-stage1b-report.md and runtime-row-removal-defect.md record the
minimal sequences, source analysis, runner results and stage 2 blockers.

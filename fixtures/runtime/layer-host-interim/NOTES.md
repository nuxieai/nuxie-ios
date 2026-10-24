# Interim layer host

This is an interim stand-in for [UNIV-5113](https://universe.basis.dev/issue/UNIV-5113)'s publisher output. Replace it with
published output when that work lands. It is not a signed release.

The historical source was the now-retired custom-transition corpus. Both Screen
artboards, assets, interaction listeners, transition timelines and forward and
reverse completion events are preserved. The lossless post-processor splits
Runtime into distinct Screen root types, disables Screen clipping, preserves
each Screen's default interaction machine, and appends LayerList with a plain
Node above its screens ArtboardComponentList. Rows retain their authored sizes
and overlap at the origin. Root schema LayerHost has an empty screens list.

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
The interim render.transitions[].defaultPair marker is an optional boolean.
Only true identifies a compiler default pair for a skipping Back; absent or
false declarations remain route-specific. Null and other types are refused.
UNIV-5113 will supply the final field name.

Stage 2 restores the stage 1 plain-Node layout. Filling the root is UNIV-5113's
publisher-layout responsibility. testMountedRowsFillResizedRoot is a strict
expected failure until published layouts fill the resized root. The rejected
stack/fill-override experiment is recorded in the handoff row-sizing-attempt.md.

The native-only removal-probe-*.riv scenes isolate UNIV-5186. Each has two
distinct row types and a host list. quiet has no output bindings, readback
binds computed width only, marker binds animated node x only, and active binds
both to separate number properties. Raw remove followed by a timed advance
remains a strict expected failure for the marker and active variants. The
layer's removal settles at zero time in the same gated operation and returns
that step for normal routing. Their sizes and hashes are in provenance.json.

Stage C row-collapse coverage: this scene has a non-virtual ArtboardComponentList
named screens, but no live-move records (native types 62000 through 62002).
Runtime 51ee009249 requires a hosted scene created from those records even for
set_row_collapsed(..., false). It returns INVALID_ARGUMENT before looking up the
row. Three ordering/reconciliation tests now use the real records in
page-host-live-moves instead. The default-machine retention/removal/revisit test
remains skipped: its markerX and keptValue probes are absent from the new A/B
fixture, and its repeated insert expands an already mounted row. Stage C must
supply both records and those probes to restore that particular assertion set.
The production call still executes and propagates errors. Other insertion,
removal, retention, lifecycle and attribution tests continue using this fixture.

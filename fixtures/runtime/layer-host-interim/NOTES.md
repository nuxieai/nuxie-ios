# Interim layer host

This is an interim stand-in for UNIV-5113's publisher output. Replace it with
published output when that work lands. It is not a signed release.

The source is `fixtures/journeys/rendered-custom-transition`. Both Screen
artboards, assets, interaction listeners, transition timelines and forward and
reverse completion events are preserved. The lossless post-processor splits
Runtime into distinct Screen root types, disables Screen clipping, preserves
each Screen's default interaction machine, and appends LayerList with a plain
Node above its screens ArtboardComponentList. The list has no layout parent or
layout participation. Root schema LayerHost has an empty screens list.

Readback properties rowWidth and rowHeight measure the mounted Screen size.
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

UNIV-5113 sizing question: list rows retain their authored Screen size when the
root player is resized. testMountedRowsFillResizedRoot retains the desired fill
assertions as an expected failure. No SDK sizing workaround is applied.

The final size probe reads Paywall at 390 by 844 and Upsell at 430 by 932 under
a 510 by 710 root. The separate lifetime test remains a real failing test:
the runtime reports nux_capi.limit_exceeded with a journal-bound or occurrence-
graph diagnostic during the two-row insertion/removal/revisit sequence. Its
exact failing primitive still needs isolation. No SDK workaround is applied.
The handoff stage-1 report records the runner results and concurrency gate block.

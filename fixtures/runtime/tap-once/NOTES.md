# Tap once

One tap on a repeated row, on a copy, or on a Buy button that is itself a copy reports its event once ([UNIV-3942](https://universe.basis.dev/issue/UNIV-3942)). `ExperienceTapOnceTests` plays this scene through the SDK's own player selection, event-source check and effect routing.

The source is the parent repository's `tools/sdk-fixtures/tap-once`, copied in `source/`: two plan cards repeated over `state.plans` and a Lifetime card copy, each reporting `picked` through its `select` action and writing `state.chosen`; a Subscribe copy with no props of its own, reporting `purchase` through its `press` action; and a plain Restore button reporting `restore`. The screen is 390 by 640 with fixed box sizes, so the test's tap points come from the CSS: Monthly (195, 84), Annual (195, 168), Lifetime (195, 256), Subscribe (195, 336), Restore (195, 404).

`screen.riv` is the parent's full publisher output, through its `publish_folder` example, at the commit `provenance.json` names. Its System fonts and reported event names are copied from the publisher's report.

Why Subscribe has no props: an event whose source view model is outside the screen's graph is dropped by the SDK, and a copy with props of its own is outside it. A copy with none is not, so before the publisher reserved a component's own action and tap events (`$nuxie.action.*`, `$nuxie.tap.*`), its `press` reached the journey beside `purchase`. A scene published before that change fails this test with `["press", "purchase"]` for Subscribe.

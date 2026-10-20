# Emit values

Each emit's values reach the Journey under their own names, the same way the editor and Preview send them ([UNIV-5180](https://universe.basis.dev/issue/UNIV-5180), the data plan's phone events step D2.54). `ExperienceSharedValuesPresentationTests.testPublishedEmitsReachTheJourneyWithTheirValues` plays this scene through the real Journey, and Android's `SharedValuesJourneyDeviceTest.publishedEmitsReachTheJourneyWithTheirValues` does the same on a device.

The source is the parent repository's `tools/sdk-fixtures/emit-values`, copied in `source/`. One screen, 390 points wide, with every box 48 points tall and 326 wide from x 32, 24 points of top padding and 8 between boxes and rows, so the tap points come from the CSS (the parent's `EMIT_VALUES_POINTS`):

| Tap | Point | What reaches the Journey |
| --- | --- | --- |
| Send plan | (195, 104) | `picked` with `plan: "monthly"` and `screenId: "author-screen"` |
| Choose annual | (195, 48) | nothing; `state.plan` becomes `annual` |
| Send plan | (195, 104) | `picked` with `plan: "annual"` and `screenId: "author-screen"` |
| Yearly plan, a row of `state.plans` | (195, 216) | `picked` with `plan: "yearly"`, the row's item |
| Add one, a copy that writes its `count` output, then calls `changed` | (195, 272) | `counted` with `count: 1` |
| Rate four, a copy that calls `rated(4)` | (195, 328) | `rated` with `stars: 4` |
| Set, then send | (195, 384) | `noted` with `note: "before"`: a listener reads values from before the tap |
| Send, then clear | (195, 440) | `noted` with `note: "after"` |
| Walk, a row of `experience.goals` that removes its own item | (195, 552) | `goal_removed` with `title: "Walk"` |

The Walk row's removal crashes the phones' player step one step later ([UNIV-5205](https://universe.basis.dev/issue/UNIV-5205)), so the SDK tests stop at Send, then clear until that is fixed; the parent's bridge plays the whole table.

A value read from a path travels as a text property named `$<field>`, naming the hidden value the emit's listener copied it into just before the event fired (`state/emit:...`). The SDK reads that value from the screen's root view model when the event is reported and sends it as `<field>`; no `$` property reaches the Journey. The field named `screenId` is the author's value: the event's source is the screen the runtime reported it from. After Walk, the Experience's `goals` list holds Read and Swim.

`screen.riv` is the parent's full publisher output, through its `publish_folder` example, at the commit `provenance.json` names. Its System fonts and reported event names are copied from the publisher's report.

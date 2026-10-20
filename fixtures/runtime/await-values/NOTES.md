# Await values

What follows an `await save(...)` keeps its own call's `$event` values, though another call came before its save was confirmed (spec decision 120, [UNIV-5209](https://universe.basis.dev/issue/UNIV-5209)). `ExperienceSharedValuesPresentationTests.testTwoQuickCallsEachGoOnWithTheirOwnValuesAfterTheirSaves` plays this scene through the real Journey, and Android's `SharedValuesJourneyDeviceTest.twoQuickCallsEachGoOnWithTheirOwnValuesAfterTheirSaves` does the same on a device.

The source is the parent repository's `tools/sdk-fixtures/await-values`, copied in `source/`. One screen, 390 points wide, with 24 points of top padding and a copy of `rate-pair` whose two 48-point buttons, 326 wide from x 32, sit 8 points apart (the parent's `AWAIT_VALUES_POINTS`):

| Tap | Point | The call |
| --- | --- | --- |
| Rate four | (195, 48) | `rated(stars: 4, mood: 'glad', word: 'four', liked: true)` |
| Rate two | (195, 104) | `rated(stars: 2, mood: 'calm', word: 'two', liked: false)` |

The tag's handler is `set(responses.feedback.stars, $event.stars); await save(responses.feedback); emit('rated', stars: $event.stars, mood: $event.mood, word: $event.word, liked: $event.liked)`. Tapping Rate four, then Rate two, requests two saves, with `stars` 4 and then 2. Confirming them in order sends `rated` with 4, `glad`, `four` and yes, then with 2, `calm`, `two` and no.

The save event names each value it keeps in a `keep:<value>` text property: the path, from the screen's root view model, of a hidden value in `state` (`state/await:...`) that the handler filled with the call's value just before the save. The SDK reads those values with the save, keeps them with it, and writes them back just before it fires the save's `awaitTrigger`, in the same step. Without that, both confirmations go on with the second call's values. A choice keeps its option and a colour its colour.

`screen.riv` is the parent's full publisher output, through its `publish_folder` example, at the commit `provenance.json` names. Its value policy (the `feedback` form) and reported event names are copied from the publisher's report.

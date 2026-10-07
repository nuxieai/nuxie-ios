# F4 values, first cut

Published from `97d23aae674d8035ffda773cefdf936f85a1ea46`, with runtime `32a31b01ba45afa6fb6b3b5cf19fc6a2b32779be`. The round-two brief supplied a 41-character hash with an extra zero; the unique local prefix resolved to this visibility-fix commit. No tracked source or runtime changes were made.

This is a first cut. The commit includes the main line's text-input milestone, which still has a review round open. Republish this fixture at the coordinator's final tip. Later parts start only when the coordinator names their commits.

## Source and independent expectations

The same source and handwritten oracle that failed at c46df21843 were republished byte for byte. Oracle SHA-256: `cccc1749bf5852e7b8b3339a18da0cec3face0b2f0f96f6db497318bd525ece5`.

Experience state: trip_days is a number starting at 23; level is a number starting at 1. The tap screen shows trip_days and Continue runs `set(experience.trip_days, 30); emit('continue')`. The Journey routes continue to level. The level screen also shows trip_days and connects experience.level to answer-card's numeric picked input. That input defaults to 0 and shows Tick only when picked == 1. Days is the fallback binding text. These source and expectation names were approved before publication.

## Qualification and native event boundary

C9 passes: a real pointer tap writes 30; a second screen instance linked to the same Experience values shows 30. C8 passes its values and semantic-text check: Tick appears on the first advanced frame for 1, and is absent for 0. The C library also checks the Experience model, each screen's experience property, defaults and shared-instance identity. The check reads the authored oracle, not expected values derived from the publisher.

At this commit the publisher writes no action id for emit. The button fires the native event `continue`. This fixture proves the values, the shared second screen and exactly one native continue event locally. It does not prove that a platform SDK admits the tap in a released Experience. That proof belongs to the platform SDK thread and the coordinator's merge gate. F1's signing instructions do not apply.

The publish harness follows F1's buildPublishSource, preflight and real publisher-WASM path. Its synthetic compile leg has empty screenBehaviors and Journey routes. It does not produce a signed release definition. The authored source retains its route on continue.

## Drawn box and fonts

C8 remains values-only platform qualification. The unsized answer-card source is 393 by 852. Its visible Tick/content box, measured by the native host with the editor System stand-in font, is `(0, 18.828125)-(120, 19.888865)`: about 120 by 1.06074. No source size workaround was added. Platform first-drawn-frame pixel proof waits for the republish after [UNIV-3966](https://universe.basis.dev/issue/UNIV-3966). Use actual platform bounds and font metrics rather than copying this check's coordinates.

System font is external. Carry the exact provenance fonts array and require system-fonts on a presentation path that retains non-embedded fonts. The entry is System, weight 400, normal, authoredAssetId 0, assetUniqueName font-system-400-normal-6cda3de3-0, required true. The native check loads tools/nuxie-editor/crates/editor/assets/nuxie-editor-ui-400.ttf as the stand-in face.

## Object comparison

The new file is 5353 bytes with 249 decoded objects; the failing file was 5309 bytes with 243. Format version 7.3 and file id 1 are unchanged. Zero-based decoded object indices below refer to the corresponding file.

Visibility: old objects 122-129 (two listener groups) are removed. Boolean value, binding and ListenerViewModelChange records now sit under Shown (new 143-145) and Hidden (154-156), with action flags 4. This is the compiler repair for [UNIV-3990](https://universe.basis.dev/issue/UNIV-3990).

Finding: bytes also changed outside visibility. New object 209 is FocusData (type 653), named scr_screens_stap::v3 focus, parent 12, properties 956=0 and 1033=7. New objects 238-244 add a button listener with listener type 16, ListenerInputTypeSemantic (669), SemanticInput (670, value 0), and the set-to-30/continue actions. Seventeen existing tap objects have only local-reference number changes. Header field entries add 956, 980, 1010 and 1033, and remove 399. The remaining decoded objects match exactly in sequence. This is not a visibility-only republish. Focus and semantic activation are not qualified by this fixture's pointer/value tests; this difference is reported for coordinator review, not dismissed as harmless.

Complete decoded comparison: `/private/tmp/fixture-publisher-round2-objects.log`; object diff: `/private/tmp/fixture-publisher-round2-object-diff.log`. The harness regenerates the decoded comparison from the retained original evidence.

## Commands and results

All commands use the fixture worktree, both target variables set to its tools/nuxie-editor/target, CARGO_BUILD_JOBS=2, CARGO_PROFILE_DEV_DEBUG=0, CARGO_PROFILE_TEST_DEBUG=0 and CARGO_INCREMENTAL=0. Test inputs: FIXTURE_FOLDER=run-values, FIXTURE_SCREENS=tap,level. Disk was checked before each build/test. No SDK, server, full bridge suite or broad typecheck was run; the task changes no tracked source and specifies focused fixture checks.

- `node apps/nuxie-publish/scripts/prepare-editor-publisher-wasm.mjs`: passed, 825.4s. Log /private/tmp/fixture-publisher-publisher-round2-build.log.
- `node apps/nuxie-experience-authority/scripts/prepare-experience-authority-wasm.mjs`: passed, 1163.4s. Log /private/tmp/fixture-publisher-authority-round2-build.log.
- From apps/nuxie-publish, `node ../../scripts/run-vitest.mjs run --config vitest.config.mts tests/unit/fixture-publisher-local.test.ts`: 1 passed, 5.2s wall time. Log /private/tmp/fixture-publisher-publish-round2.log.
- `bash tools/nuxie-editor/scripts/cargo.sh test -p editor-publisher-wasm --test fixture_publisher_local -- --nocapture`: first compile failed on a new harness event-field accessor after 328.2s; corrected to name(), then 1 passed in 15.8s. Passing log /private/tmp/fixture-publisher-self-check-round2-fixed.log.
- `python3 /Users/levi/dev/nuxie-codex/codex-fixture-publisher-notes/negative.py`: 12 intentional assertion failures, each inspected for the intended reason. Restored oracle passed again in /private/tmp/fixture-publisher-runtime-restored.log. Last passing summary: test result: ok. 1 passed; 0 failed.

Negative logs:
- `/private/tmp/fixture-publisher-negative-level-inputDefault.log`
- `/private/tmp/fixture-publisher-negative-level-noTickValue.log`
- `/private/tmp/fixture-publisher-negative-level-tickText.log`
- `/private/tmp/fixture-publisher-negative-level-tickValue.log`
- `/private/tmp/fixture-publisher-negative-model.log`
- `/private/tmp/fixture-publisher-negative-property.log`
- `/private/tmp/fixture-publisher-negative-screens.log`
- `/private/tmp/fixture-publisher-negative-startingValues-level.log`
- `/private/tmp/fixture-publisher-negative-startingValues-trip_days.log`
- `/private/tmp/fixture-publisher-negative-tap-after.log`
- `/private/tmp/fixture-publisher-negative-tap-before.log`
- `/private/tmp/fixture-publisher-negative-tap-buttonLabel.log`

## Not yet included

Device screen and device values schema (C5); empty screen and tips_seen (C6/C7); release.json (C10); Journey branches. Device/schema wait for their assigned part, empty/tips_seen for the empty-value milestone, and release metadata/branches for later qualification. No text-input or focus behavior is released by this fixture, even though the compiler commit includes that milestone.

## Earlier cuts

Undelivered failing attempt: c46df2184306d540c6d3f80814be67428fdd9877, screen.riv SHA-256 97f04db4a5fb2e470d8eb8d41cfa8d08389b2272276a077affe1663a73c9af22, 5309 bytes. C9 passed but C8's visibility failed. Exact original retained under /Users/levi/dev/nuxie-handoff/fixtures/evidence-shown-in-copy/run-values/. The cause was compiler listener ordering, not a runtime fault. No runtime workaround was made.

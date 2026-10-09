F5 published: /Users/levi/dev/nuxie-handoff/fixtures/phones-values-saves/forms-saves/release.json; artifact commit df325c84e96cbe388643e4a47fab8ccbfd951d98; source commit 6281edf876e1d523295cb444b8c9cd374cc0aaea.

# F5 forms, typing, saves and a form-answer Journey condition

This local signed release v3 fixture retains the partial forms/saves cut and adds C11. Departure's Continue still writes responses.onboarding.trip_days, saves onboarding, and emits continue. Its Journey route now branches on responses.onboarding.trip_days > 14. The long branch sends long_trip with the answer; the default branch sends short_trip with the answer. Both then take the original push navigation to Italian level, in the same Journey leg.

The wire selector is {"type":"Response.Field","form":"onboarding","key":"trip_days"}. The optional form distinguishes this from {"type":"Response.Field","key":"trip_days"}, which continues to read Experience state. There is no reserved form name or new state variant. A reader without form answers reads the form selector as unknown, never as same-named state. Server legs receive no form answers.

Handwritten platform cases in expectations.json: 7 and 14 send short_trip with their numeric answer; 23 sends long_trip with 23. The platform then navigates to scr_screens_sitalian-level. These cases and the literal wire graph expectations were written before publishing. Thread 4 owns running the two branches on the platforms.

## Retained partial cut and exclusions

Adapted from Parla onboarding. Onboarding and feedback have no authored answer defaults. Feedback retains typed comment, email and number stars fields, awaited Send, validity, errors, save status, interests chips and callback-free script save. Goals are displayed.

Rating component payload declaration remains excluded until milestone 10; rating payload delivery and $event.stars, including across awaited saves, and remove(goal) remain excluded until milestone 11. Stars is entered in a number field. Script save completion callbacks remain excluded under the approved M9 cut: nuxie.responses.save("feedback") has no callback. This job adds only the Journey form read and condition; it changes none of those exclusions.

## Identity and checks

Source commit 6281edf876e1d523295cb444b8c9cd374cc0aaea; compiler/readers tip 761943f976dc896b47b41dd356ac2a9a4dc3d0bd, stacked on C5 bd9c349856993b356f214fc280a1ae3be933598d. The compiler arm is 37831a1fa824586a7bf65779b2991b7290b83282. C5 includes the native ViewModel.viewModelType registry fix d9c4e168a49fd029e6aa9aaebb670f37feaecaa8. Runtime remains 32a31b01ba45afa6fb6b3b5cf19fc6a2b32779be. Branch codex/c11-form-answer-condition, worktree /Users/levi/dev/nuxie-codex/codex-f4-device-screen. Schema spelling follows this base; the landing batch performs its planned nuxie.com to nuxie.ai sweep.

release.json is the exact signed descriptor; profile-entry.json holds the test-key signature and locator. Signing uses the repository's TEST_ONLY_DEV_KEYPAIR; platforms explicitly trust its public test key. This is local fixture publication, not a remote release. screen.riv equals its single content-addressed render object. Provenance records every delivered file except itself, each font declaration and all three build artifacts used by publication.

The new native harness first failed on the old release at C11 published form condition. Both WASM preparations and the focused publication passed. The native test then passed: retained form catalog, empty-answer markers, scalar starting values and status, plus the signed route's exact condition selector, both event payloads and their shared navigation. A deliberately wrong form (feedback instead of onboarding) failed at C11 published form condition; expectations were restored byte for byte in finally and the positive check passed again. The Rust harness checks the published graph; it does not execute an SDK Journey interpreter. Device typing, save transport, rule installation, actual branch execution and pixel/font qualification remain Thread 4's checks.

Commands, from the worktree unless noted, with both Cargo target variables set to /Users/levi/dev/nuxie-codex/codex-preview-tool/tools/nuxie-editor/target:

- node apps/nuxie-publish/scripts/prepare-editor-publisher-wasm.mjs
- node apps/nuxie-experience-authority/scripts/prepare-experience-authority-wasm.mjs
- From apps/nuxie-publish: FIXTURE_FOLDER=forms-saves FIXTURE_SCREENS=welcome,departure,italian-level,daily-plan,daily-reminder,start-lesson,feedback,goals node ../../scripts/run-vitest.mjs run --config tests/fixtures/c10/vitest.config.mts
- bash tools/nuxie-editor/scripts/cargo.sh test --locked -p editor-publisher-wasm --test c10_fixture --no-run (test opt-level=1/debug=0, incremental off)
- C10_FIXTURE_ROOT=<this folder> /Users/levi/dev/nuxie-codex/codex-c11-form-answer-condition-notes/c10-fixture-check --ignored --nocapture c10_forms_saves_published_values_match_source

The independent shasum/stat verification and build/test/negative logs are in /Users/levi/dev/nuxie-codex/codex-c11-form-answer-condition-notes. No whole suite or ProductHost build; those are left for the batch. The previous signed F5 cut is retained at ../earlier-cuts/forms-saves-9ff6ee3e21/.

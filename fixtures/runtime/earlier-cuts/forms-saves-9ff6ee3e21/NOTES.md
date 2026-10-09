F5 published: /Users/levi/dev/nuxie-handoff/fixtures/phones-values-saves/forms-saves/release.json; artifact commit 9ff6ee3e21; source/oracle commit 513bba44a2; planner carry 5ced80ba74.

# F5 forms, typing and saves: partial cut

Real local release version 3 publication, signed with the repository's public test-key pair. Adapted from Parla onboarding. The onboarding and feedback answers have no authored defaults. Continue saves onboarding before emitting. Feedback has typed comment, email and number stars fields, awaited Send, validity, errors and save status, interests chips, and callback-free script save. Goals are displayed.

## Excluded features

Approved by the coordinator at 10:20: rating component payload declaration waits for milestone 10; rating payload delivery and `$event.stars` (including across awaited saves) wait for milestone 11; `remove(goal)` waits for milestone 11. There are no expected outputs or dormant event declarations for these excluded features. Stars is entered directly in a number field in this cut. Script save completion callbacks remain excluded under the milestone 9 cut and 09:32 ruling; the script uses `nuxie.responses.save("feedback")` without a callback.

## Evidence and identity

`release.json` is the exact signed descriptor; `profile-entry.json` holds its test-key signature. `screen.riv` is also delivered under the release's content-addressed render key. `provenance.json` records source/compiler/runtime identity and SHA-256 plus size for every published file, source file and expectation.

The handwritten release oracle predates publication and comes from the independent release-contract proposal. It checks every form field, rule and group, state, screen set and authored entry event. The native C API test checks the final file's empty-answer markers, scalar starting values and form status. Wrong-star-marker and wrong-stars-maximum oracles both fail at the intended assertions. The marker table is in `expectations.json`; hosts discover these same-model `isset:` properties from the native catalog. No extra marker table is inserted in the signed descriptor.

The fixture harness uses the real resource planner and Luau compiler, then the publisher backend and production signing path with test credentials. Planner carry: `5ced80ba74`, exactly the 17-line hunk from `2d8dc9959c`. Its pre-carry publication failed on the missing listener script; publication passes after the carry and supplying the fixture harness's missing script-compilation stage. The test also asserts that the planner requests the save script.

Own worktree: /Users/levi/dev/nuxie-codex/codex-data-plan. Own target: tools/nuxie-editor/target. Logs: /private/tmp/codex-data-plan-baseline/c10-f5-*.log. Publisher package typecheck, changed-TypeScript lint and diff check passed. Whole suites and ProductHost builds are left for the batch.

## Qualification still owned by platforms

This proves publication and initial native values, not device typing, save transport or rule installation. Thread 4 owns those runs. The signed-default instance-name contract raised on F4 is awaiting the coordinator's ruling; this cut does not change it, and its native test constructs the file's canonical first instance rather than qualifying name-based default application. Fonts use the real manifest with the local editor font supplied for compilation.

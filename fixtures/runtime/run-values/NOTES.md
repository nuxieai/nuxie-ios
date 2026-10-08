F4 published: /Users/levi/dev/nuxie-handoff/fixtures/phones-values-saves/run-values/release.json; artifact commit 9674a53703; source commit 944535ae67.

# F4 run-values release v3 source

The existing tap and level content is retained. The entry explicitly declares the $app_opened trigger and every_match frequency so the real release compiler can publish the Journey; the old scene-only cut supplied a synthetic leg. Trip days starts at 23; Continue sets it to 30 and emits continue. Level starts at 1 and connects to the answer card, whose local default is 0. The shared value wins. There are no declared forms, so responses and ruleGroups must be empty.

The expectations were written before publishing. The marker table is an oracle for the native catalog, not an extra release field.

Uses /Users/levi/dev/nuxie-codex/codex-data-plan on codex/data-plan-4 and its own tools/nuxie-editor/target. The current 16 GiB pause/resume rule replaces the old recipe's timed disk wait and suite lock. Local release signing uses the repository's public test key only. No remote publication is performed.

The device and empty screens and conditional Journey branches are not part of this existing-source cut.

## Published contract

Source commit: 944535ae67 (on compiler base 2480f23d85). Runtime: 32a31b01ba45afa6fb6b3b5cf19fc6a2b32779be.

release.json is the exact signed v3 descriptor bytes from prepareJourneyRelease, not a manually assembled metadata fragment. profile-entry.json contains its Ed25519 envelope and locator, using TEST_ONLY_DEV_KEYPAIR. Platforms must trust that test key explicitly for this fixture. The referenced renders/sha256 object is supplied alongside screen.riv, which has the same bytes. This is local fixture publication, not a hosted release.

State declares trip_days and level as numbers. There are no forms, so responses is {} and ruleGroups is []. Markers are discovered from the native catalog: same-model boolean isset:<property> for each nullable scalar. Both starting numbers have true markers. There is no separate marker field in the descriptor; expectations.json carries the independently written marker oracle.

The release retains the authored continue route to level and the native continue event. The old scene-only recipe's synthetic empty Journey is not used. The System font remains external; provenance.json lists the exact font declaration. Native checks use the repository's nuxie-editor-ui-400.ttf as the System stand-in. Platform font metrics and first-drawn-frame pixels still need platform qualification.

## Checks

Only the fixture tests ran. Both WASM artifacts were built from this worktree. The publication test verifies the signature with the repository test public key, exact signed descriptor bytes, state/forms/groups, screen identities and signed starting values. The native check imports the actual file and checks the shared Experience model, defaults, presence markers, pointer Continue from 23 to 30, second-screen sharing, and Tick on the first advanced frame at level 1, absent at 0.

Commands run from this worktree (publisher test runs in apps/nuxie-publish):

- node apps/nuxie-publish/scripts/prepare-editor-publisher-wasm.mjs
- node apps/nuxie-experience-authority/scripts/prepare-experience-authority-wasm.mjs
- FIXTURE_FOLDER=run-values FIXTURE_SCREENS=tap,level node ../../scripts/run-vitest.mjs run --config tests/fixtures/c10/vitest.config.mts
- bash tools/nuxie-editor/scripts/cargo.sh test -p editor-publisher-wasm --test c10_fixture --no-run
- C10_FIXTURE_ROOT=<this folder> tools/nuxie-editor/target/debug/deps/c10_fixture-bcd588ecb28308e0 --ignored --nocapture

The Rust test is explicitly ignored in general suites because it requires these separately published bytes. The custom Vitest config selects the fixture publisher; general suites do not regenerate deliveries. The publisher workspace typecheck and changed-file lint passed. Whole suites and platform checks are left for the batch and platform threads.

Negative oracle checks mutate only expectations and restore them in finally: model, property, screen names, both starting values, tap label/before/after, component default, Tick values/text and both presence booleans. A separate wrong state kind is rejected by the signed-release assertion. Logs and runners: /private/tmp/codex-data-plan-baseline/c10-*. Early probes with missing dependencies and missing publisher WASM are setup failures, not behavioral red evidence. One harness probe omitted the project root and therefore its state declarations; corrected to getDocumentNodes before qualification. The freshly prepared authority superseded the earlier generated authority; only the final bytes are delivered.

## Earlier cut

The previous delivered scene-only cut was from 97d23aae674d8035ffda773cefdf936f85a1ea46. It had no signed release. Its source content is preserved here, apart from the explicit entry trigger needed by the real release path. Its previous NOTES and provenance are retained in the handoff archive before this delivery replaces it.

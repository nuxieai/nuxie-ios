F4 published: /Users/levi/dev/nuxie-handoff/fixtures/phones-values-saves/run-values/release.json; artifact commit d8aa6566bac9a51690956eb7b230cd26e0719f19; source commit 1b558a2cb6b4bd4b5fd493f3f8c9752bf06d1bdc.

# F4: tap, level and device

This local signed release v3 fixture keeps the tap and level behavior: trip_days starts at 23 and Continue changes it to 30; level starts at 1 and the answer-card's Tick is shown, absent at 0. Level now has Next, which emits continue and navigates to device in the same Journey leg. State remains trip_days and level, with responses {} and ruleGroups [].

The device screen reads env.reduceMotion and env.safeArea.top. Its motion-note copy declares no inputs and independently reads env.reduceMotion. Before writes, 0 is shown and Still/Calm are absent. With reduceMotion true and safeArea/top 59, 59, Still and Calm are shown. Device moves down 39 points: max(59,20) minus max(0,20). These expectations were written before publication, not derived from the published file.

The file's env global holds only reduceMotion and safeArea (top, bottom, left, right). env-schema.json is copied byte for byte from packages/models/src/env-schema.json and lists all eight device values. The other six (width, height, fontScale, colorScheme, platform, locale) come with every device value [D2.51] after the merge, per Levi's M7. Empty screen/tips_seen and conditional Journey branches remain outside this cut.

Each platform hands each screen the one env instance by name using nux_player_set_global_view_model from release 0.10.13 and 0.4.11. This fixture's own check uses the host data-context slot at runtime 32a31b01ba45afa6fb6b3b5cf19fc6a2b32779be, whose C API has no global-install call. Catalog shape is checked through the read-only C catalog; behavior is checked through the host layer.

## Publication and provenance

Source commit: 1b558a2cb6b4bd4b5fd493f3f8c9752bf06d1bdc. Compiler base: 020ffb241c3664a8afdcc5453991dea9381c64ce, including the host's env-global style-source fix, plus compiler registry fix d9c4e168a49fd029e6aa9aaebb670f37feaecaa8 for native ViewModel.viewModelType (981, uint). Runtime unchanged at 32a31b01ba45afa6fb6b3b5cf19fc6a2b32779be. Worktree /Users/levi/dev/nuxie-codex/codex-f4-device-screen, branch codex/f4-device-screen. The authored nuxie.com schema spelling matches this base; the landing batch sweeps it to nuxie.ai along with F4's other source.

release.json contains the exact signed descriptor bytes produced by prepareJourneyRelease; profile-entry.json retains its Ed25519 envelope and locator. Signing uses only TEST_ONLY_DEV_KEYPAIR. Platforms must explicitly trust the repository test public key. This is local fixture publication, not a remote or production release. The single renders/sha256 object matches screen.riv byte for byte. The System font remains external; native checks use nuxie-editor-ui-400.ttf as its stand-in. Platform font metrics and first-frame pixel proof remain the platforms' work.

## Checks

The old published bytes failed the new native check with no device artboard. Both WASM preparations and the focused publication test passed. The native check passed for tap, level and device. Six independently corrupted device expectations each failed at the intended assertion: 58 instead of 59, Still absent, Calm absent, 40-point displacement, an extra width property, and initial reduceMotion true. Expectations were restored byte for byte in finally and the positive check passed again. Whole suites are left for the batch check.

Commands (root unless noted), with both Cargo target variables pointing to this task's idle Preview target /Users/levi/dev/nuxie-codex/codex-preview-tool/tools/nuxie-editor/target:

- node apps/nuxie-publish/scripts/prepare-editor-publisher-wasm.mjs
- node apps/nuxie-experience-authority/scripts/prepare-experience-authority-wasm.mjs
- From apps/nuxie-publish: FIXTURE_FOLDER=run-values FIXTURE_SCREENS=tap,level,device node ../../scripts/run-vitest.mjs run --config tests/fixtures/c10/vitest.config.mts
- bash tools/nuxie-editor/scripts/cargo.sh test --locked -p editor-publisher-wasm --test c10_fixture --no-run (CARGO_PROFILE_TEST_OPT_LEVEL=1, CARGO_PROFILE_TEST_DEBUG=0, CARGO_INCREMENTAL=0)
- C10_FIXTURE_ROOT=<fixture folder> <Cargo-reported c10_fixture executable> --ignored --nocapture c10_run_values_published_bytes_match_source
- python3 /Users/levi/dev/nuxie-codex/codex-f4-device-screen-notes/negative-device.py <same executable>

Logs, exact executable and timings are in /Users/levi/dev/nuxie-codex/codex-f4-device-screen-notes/. The guard pauses only its own build process group under 16 GiB. No whole suite, ProductHost build, SDK build or runtime source change. Provenance hashes include every delivered file other than provenance.json itself, whose own hash cannot be embedded in itself.

## Earlier cuts

The replaced signed tap/level cut remains at ../earlier-cuts/run-values-9674a53703/. The earlier scene-only cut remains at ../earlier-cuts/run-values-97d23aae67/.

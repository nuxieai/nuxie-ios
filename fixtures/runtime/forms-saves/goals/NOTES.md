# Forms and saves, goals cut

Releases C19, the published goals-list prerequisite for entry 7's list checkpoint
recovery. Each F5 cut is a complete independent subfolder. This first one is
`forms-saves/goals/`; it does not replace or extend F3 or F4.
Tracking: [UNIV-3593](https://universe.basis.dev/issue/UNIV-3593).

## Source tip

Published from `81fa73c87f0638d151d0a4082fbcab1cd61ec73c` on the approved `codex/data-lists` pick through
81fa73c87f, before the excluded golden commit. This is the earliest clean
approved lists tip with the declaration, native row isolation and repeat carry
contracts needed here. At source selection, the later `codex/data-lists-host` candidate at
77f91b212c had an unresolved admission correction and uncommitted work, so it
was not used. It later advanced to 4c35c66f8c with a clean worktree, but its
HANDOFF still had no new clean qualification. This cut already passes at 81fa73c87f. Its live editor reconciliation work is outside this native
snapshot check. The publisher checkout has no tracked changes and was detached
at the selected immutable commit throughout publication and checks.

Runtime stays `32a31b01ba45afa6fb6b3b5cf19fc6a2b32779be`. No runtime source or pointer changed.
`screen.riv`: `a62578818e941eb3366fae0cde4348ac60af3a0294dc6a97a4e054292f03f1cb`,
3173 bytes.

## Source and handwritten oracle

Experience state declares goals as a list of objects with a string title,
starting with Read then Walk. The goals screen repeats a goal-card bound to
each title. The quiet screen reads no list but still shares the Journey's Experience
model. The card fallback text is Title and the quiet screen says Quiet. These
words were recommended and built under the F5 brief's choice rule, recorded
in QUESTIONS. The fixture contains no event handler.

The handwritten oracle was frozen before publication. Snapshot and recovery
expectations are Walk, Sleep, Read in that order. The native test's literal
inputs move Walk first and insert Sleep at index 1. Sleep and Discard are test
inputs; Discard is inserted into the fresh recovery Journey and must be removed.
No oracle field comes from the publisher; there is no locator exception here.

## Native qualification

The check imports the actual screen.riv through the pinned runtime C API. It
reads values using nux_view_model_instance_snapshot and the ordered
nux_view_model_snapshot_list_item table, then joins child ids to their title
values. It verifies exactly two distinct authored rows, list order and values,
then native insert and move while retaining the original row identities.
Every screen links to the same Journey, including quiet; snapshots from both screen
roots see the changed list.

The snapshot values are serialized, then the original C API screen, Journey
and file handles are dropped. The checkpoint is decoded and a fresh file imported. Recovery mutates the new Journey in
place using native insert, remove and move, keeping its root identity and
existing Read/Walk row identities. Both linked screen roots observe the
recovered order. Empty recovery removes every row; recovering again from empty
recreates the saved list. A separate new Journey still has the authored defaults.
The saved snapshot stays unchanged when the original live list changes.

This is a fixture-level recovery exercise with distinct titles used to match
surviving rows. It is not a general SDK identity algorithm or implementation of
durable checkpoint storage. The platform SDK thread owns the actual Journey
timed-wait/restart proof. This cut supplies its real published list and oracle.
Native values, list membership and order are qualified; platform pixels and
component layout are not. There is no authored row remove or continuation event
in this cut, so it does not release C16.

## Publish boundary and omitted contracts

The recipe uses the real local publish-source/preflight/Rive compiler path,
with its synthetic compile Journey and empty release routes. No signed release
or full Journey execution is claimed. C19 needs no published release table.
This cut has no responses, form fields, rules, groups, save events, script-save
command, rating event payloads, await continuation triggers or row-remove event.
Those are the following cuts, listed in expectations.notYetIncluded.

The main line advanced from `codex/data-plan-2` at 45a59336d1 to the carry
branch `codex/data-plan-3` at 8a9b4b7b6d during this build. The carry is still
under verification and has no lists pick or later response/save/rules/groups/
full-await contracts. No clean tip supplies cuts 2 through 5 yet. The coordinator handoff names each missing cut independently; no
stand-ins are built and no unavailable cut is waited on.

## Font

The recipe supplies `tools/nuxie-editor/crates/editor/assets/nuxie-editor-ui-400.ttf`
as System. Actual publisher font entries:

```json
[
  {
    "location": "system",
    "family": "System",
    "weight": "400",
    "style": "normal",
    "authoredAssetId": 0,
    "assetUniqueName": "font-system-400-normal-6cda3de3-0",
    "required": true
  }
]
```

## Validation

All builds use the own publisher target, two Cargo jobs, debug information off
and incremental compilation off. Disk was checked before each step using the
15 GiB floor, 25 GiB for cold builds, with automatic waits when required. No
whole suite was needed for untracked fixture harness changes. The native target
checks this fixture only; its F3-only probe returns without execution.

F5 goals command `pnpm install --frozen-lockfile` in `/Users/levi/dev/nuxie-codex/codex-fixture-f1`: exit 0; 0.5s; free before 75.0 GiB, after 75.0 GiB; target 111M	/Users/levi/dev/nuxie-codex/codex-fixture-f1/tools/nuxie-editor/target. Log `/private/tmp/fixture-publisher-f5-install.log`.
F5 goals command `node apps/nuxie-publish/scripts/prepare-editor-publisher-wasm.mjs` in `/Users/levi/dev/nuxie-codex/codex-fixture-f1`: exit 0; 1202.2s; free before 75.0 GiB, after 57.0 GiB; target 1.6G	/Users/levi/dev/nuxie-codex/codex-fixture-f1/tools/nuxie-editor/target. Log `/private/tmp/fixture-publisher-f5-publisher.log`.
F5 goals command `node apps/nuxie-experience-authority/scripts/prepare-experience-authority-wasm.mjs` in `/Users/levi/dev/nuxie-codex/codex-fixture-f1`: exit 0; 431.2s; free before 57.0 GiB, after 52.7 GiB; target 2.2G	/Users/levi/dev/nuxie-codex/codex-fixture-f1/tools/nuxie-editor/target. Log `/private/tmp/fixture-publisher-f5-authority.log`.
F5 goals command `node ../../scripts/run-vitest.mjs run --config vitest.config.mts tests/unit/fixture-publisher-local.test.ts` in `/Users/levi/dev/nuxie-codex/codex-fixture-f1/apps/nuxie-publish`: exit 0; 1.6s; free before 52.7 GiB, after 52.7 GiB; target 2.2G	/Users/levi/dev/nuxie-codex/codex-fixture-f1/tools/nuxie-editor/target. Log `/private/tmp/fixture-publisher-f5-publish.log`.
F5 goals command `bash tools/nuxie-editor/scripts/cargo.sh test -p editor-publisher-wasm --test fixture_publisher_local -- --nocapture` in `/Users/levi/dev/nuxie-codex/codex-fixture-f1`: exit 101; 151.2s; free before 52.2 GiB, after 48.2 GiB; target 3.8G	/Users/levi/dev/nuxie-codex/codex-fixture-f1/tools/nuxie-editor/target. Log `/Users/levi/dev/nuxie-codex/codex-fixture-publisher-notes/f5-native-compile-red.log`.
F5 goals command `bash tools/nuxie-editor/scripts/cargo.sh test -p editor-publisher-wasm --test fixture_publisher_local -- --nocapture` in `/Users/levi/dev/nuxie-codex/codex-fixture-f1`: exit 101; 10.0s; free before 46.8 GiB, after 46.6 GiB; target 3.9G	/Users/levi/dev/nuxie-codex/codex-fixture-f1/tools/nuxie-editor/target. Log `/Users/levi/dev/nuxie-codex/codex-fixture-publisher-notes/f5-native-artboard-red.log`.
F5 goals command `bash tools/nuxie-editor/scripts/cargo.sh test -p editor-publisher-wasm --test fixture_publisher_local -- --nocapture` in `/Users/levi/dev/nuxie-codex/codex-fixture-f1`: exit 0; 18.7s; free before 46.0 GiB, after 45.8 GiB; target 3.9G	/Users/levi/dev/nuxie-codex/codex-fixture-f1/tools/nuxie-editor/target. Log `/private/tmp/fixture-publisher-f5-native.log`.
F5 goals command `pnpm --config.verifyDepsBeforeRun=false --dir apps/nuxie-publish run lint` in `/Users/levi/dev/nuxie-codex/codex-fixture-f1`: exit 0; 2.0s; free before 45.8 GiB, after 45.9 GiB; target 3.9G	/Users/levi/dev/nuxie-codex/codex-fixture-f1/tools/nuxie-editor/target. Log `/private/tmp/fixture-publisher-f5-lint.log`.
F5 goals command `pnpm --config.verifyDepsBeforeRun=false --dir apps/nuxie-publish run typecheck` in `/Users/levi/dev/nuxie-codex/codex-fixture-f1`: exit 0; 43.8s; free before 45.9 GiB, after 45.3 GiB; target 3.9G	/Users/levi/dev/nuxie-codex/codex-fixture-f1/tools/nuxie-editor/target. Log `/private/tmp/fixture-publisher-f5-types.log`.

The first native compilation failed at the new quiet-label probe because the
local harness passed the import helper's (file, factory) tuple where a file
handle was required. Destructuring and retaining both corrected the harness;
`f5-native-compile-red.log` preserves the failure. No source, oracle, published
bytes or runtime changed. A second harness error used a source screen id as an
artboard name. F5 now uses the authored plain names goals and quiet, matching
the existing F3/F4 callers. f5-native-artboard-red.log retains that failure.
The subsequent native result is recorded above.

`python3 /Users/levi/dev/nuxie-codex/codex-fixture-publisher-notes/negative-f5.py`: all 21 wrong cases fail at their intended
assertions, covering every asserted oracle field plus reversed order and
missing rows. Original bytes are restored in finally; the restored positive
run passes. Logs: `/private/tmp/fixture-publisher-f5-negatives.log`, individual
`fixture-publisher-f5-negative-00.log` through `-20.log`, and
`fixture-publisher-f5-restored.log`. Durable copies are in the notes folder's
f5-evidence directory. The omission list and sourceText.cardFallback are scope/source metadata, not
runtime assertions. The visible quiet-screen label is checked natively. Source and oracle hashes match the pre-publication record.

No TypeScript source was edited for this cut. The existing publisher harness
was executed against this tip. Package checks, when listed above, cover package
source rather than typechecking the excluded local test harness. No full
repository suite, SDK build, ProductHost build or deployment was required.

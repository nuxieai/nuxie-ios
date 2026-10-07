# Published input, first cut

Qualified for native-field typing and focus, row C3.
Tracking: [UNIV-3593](https://universe.basis.dev/issue/UNIV-3593).

Published from `09081fd6591bb5f24c33693d0b06a7c3a207ea65`, runtime `32a31b01ba45afa6fb6b3b5cf19fc6a2b32779be`.
`screen.riv`: `508bf2622f18c6ed2c20814a169cb829d64d6139b3149c11caac3e77c0f8fdc9`,
4540 bytes.

## Source and behavior oracle

The input screen starts with Experience name Ada and screen values focused,
blurred and typed at 0. Focus, blur and input handlers each set their value to 1.
The input's authored id is name and its accessible label is Name. The second
screen displays Hello, followed by the same Experience name. End followed by
native text input ` Lovelace` produces `Ada Lovelace`, in the field, shared model
and greeting screen. All source files and every behavior expectation remain
exactly as written before publication.

## Published locator metadata

`expectations.json.textInputName` is explicitly a published locator, not a
behavior expectation. Its `source` names the unmodified published table,
`text-inputs.json`. Its authoredId and frame identify the source element; its
viewNodeId and value are generated publication metadata. The user approved
this narrow exception after the original guess `name editable value` failed
against the imported engine field. Original oracle SHA-256 was
`192ac43bef98ed63df955b5f6bed101d7a7dc76c2e7af4bf745e70699a1bc952`.
The native check was not weakened: wrong locator metadata and a corrupt table
both fail, independently of behavior assertions.

The release table does not itself carry HTML ids. During publication the
unchanged authoring core's locate API maps its viewNodeId to `#name` in
`screens/input/index.html`. That verified mapping is recorded in the locator.
The native check selects that row in the table and compares the table's native
name with the engine's imported TextInput, then checks the recorded locator.
It never treats the table's static value as the expected live model value.

The name is `scr_screens_sinput::v2 editable value`. The bridge allocates view
rows as `<artboard>::v<n>`, incrementing n for each inserted view row. Here the
main element is v1 and the input is v2. v2 is neither a version nor a universal
input ordinal. The text-input export adds the ` editable value` suffix. The
HTML id remains the authoring address `#name`, not the native component name.
See `experience-editor-bridge/src/bridge.rs` (row allocation), `locate.rs`
(reverse authored address), and `editor/src/build.rs` (text input hints).

Two inputs on one screen get different rows and names. An in-memory probe added
an input with id second without changing any fixture source file. Publication
mapped #name to v2 and #second to v3. The native engine imported two distinct
fields with those names; both release-table names resolved correctly. Evidence
is in `/Users/levi/dev/nuxie-codex/codex-fixture-publisher-notes/f3-two-input-probe.json` and `.riv`, and the native log below. The
probe is not part of the delivered F3 source or screen.riv. No naming collision
was found.

## Native input boundary

The platform host must send focus, keys and text through the native state
machine. The field owns Rive FocusData flags 7. Focus and blur use native focus
listeners. The field's authored input handler watches the two-way bound value
through a native ViewModel listener, including changes made by other writers.
It is not one callback per physical key and carries no key metadata. Moving the
cursor alone does not change the value. After typing, the first advance updates
the model and the next advance delivers the queued input reaction. Continue
advancing the state machine.

There is no authored keydown or keyup handler on a text field, by decision.
F3's handlers only set values: this fixture contains no authored emit and no
action-id control. The focus branch's separate regression verifies exactly one
native event for a changed bound value. F3 does not claim event-count proof.
Local publication uses the recipe's synthetic compile Journey and empty release
routes. This is not a complete signed release or signed-release admission proof.
Platform input delivery remains the platform SDK project's work.

The focus branch must not land independently. The main line carries it at
milestone 12 after all input delivery surfaces are ready. Button key engine
proof is deferred until the runtime pointer includes 0ac7a8c774; F3 has no button
key handler and all its text-field checks pass at the unchanged pin.

## Font

The publisher and native host use
`tools/nuxie-editor/crates/editor/assets/nuxie-editor-ui-400.ttf` as System.
Actual published system-font entries, also recorded in provenance:

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

This is native semantic-text and state qualification, not platform pixel proof.

## Checks and logs

All commands ran in `/Users/levi/dev/nuxie-codex/codex-fixture-f1` (publication runs in apps/nuxie-publish), with the
recipe's own target, two Cargo jobs, debug info off and incremental compilation
off. No runtime, SDK or tracked repository file was edited.

- `pnpm install --frozen-lockfile`: passed, 45.3s.
- `node apps/nuxie-publish/scripts/prepare-editor-publisher-wasm.mjs`: passed,
  1285.0s; `/private/tmp/fixture-publisher-f3-publisher.log`.
- `node apps/nuxie-experience-authority/scripts/prepare-experience-authority-wasm.mjs`:
  passed, 1145.6s; `/private/tmp/fixture-publisher-f3-authority.log`.
- `node ../../scripts/run-vitest.mjs run --config vitest.config.mts tests/unit/fixture-publisher-local.test.ts`:
  passed, 2 tests, 5.5s including launcher; `/private/tmp/fixture-publisher-f3-publish.log`.
  Initial single-test publication also passed (8.8s). Re-publication after
  locator checks preserved screen.riv byte for byte.
- `bash tools/nuxie-editor/scripts/cargo.sh test -p editor-publisher-wasm --test fixture_publisher_local -- --nocapture`:
  passed, 2 tests, 20.8s including rebuild; `/private/tmp/fixture-publisher-f3-native.log`.
  Initial cold run took 237.0s and failed only at the guessed native name;
  retained as `/Users/levi/dev/nuxie-codex/codex-fixture-publisher-notes/f3-name-mismatch-red.log`.
- `python3 /Users/levi/dev/nuxie-codex/codex-fixture-publisher-notes/negative-f3.py`: all 22 wrong cases failed at their intended
  assertions. These cover 17 behavior expectations, 2 locator fields, and
  3 corrupt table fields. Summary `/private/tmp/fixture-publisher-f3-negatives.log`;
  each failure `/private/tmp/fixture-publisher-f3-negative-*.log`.
- Restored oracle and table passed: `/private/tmp/fixture-publisher-f3-restored.log`,
  `test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out`.
- Publisher package lint and typecheck passed after the harness changes.
  Typecheck covers package source; the local harness is executed by publication.

The focus tip also passed the full locked bridge suite (570 passed, 3 ignored),
163 compiler tests and 62 reader tests. Its native input group passed 16 tests.
No E0463 compiler retry was required for these prepares. The updated disk rule
checks before each step and waits automatically if needed.

## Scope

This first cut releases C3 only. It contains the input and greeting screens,
the actual release text-input table, the source, handwritten behavior oracle,
locator metadata and provenance. No other fixture is extended. F1 and F4 remain
unchanged. Full release signing, platform SDK integration and platform pixels
are separate qualification work. There are no open questions for this cut.

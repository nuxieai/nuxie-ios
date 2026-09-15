# Unit test fixtures

## `data_binding_test.riv`

Editor-exported fixture used by `NuxieRuntimeFixtureTraceTests` to exercise
the native runtime's ViewModel data-binding trace.

## `nuxie_runtime_two_artboards.riv.base64`

Base64-encoded copy of `nuxie-runtime/fixtures/minimal/two_artboards.riv`, used
by `NuxieRuntimeAdapterTests` as a known-renderable Slice 1 fixture. The test
selects artboard `Two`, which contains a dark background and a lighter
rectangle; it intentionally has no scripts, assets, or ViewModel dependency.
Keep the decoded bytes identical to the runtime fixture (SHA-256
`480472d9942711492ce37cdba9aea6266f254633f5a2ac4a9e30f9d0eca70e8c`).

## `scripted-generic-commands/`

Signed release profile and content-addressed RIV fixture derived from the
UNIV-1845 production-publisher generic-command proof. Its journey uses the
canonical publisher `[hostId: [ScreenScriptRef]]` shape. It contains one real
scripted screen whose press
listener emits response, Journey, custom, and deliberately malformed product
commands in a fixed authored order. Its declared purchase event has a real
navigation handler used by the Journey presentation runtime.

## Apple platform seams

`in_band_asset.riv.base64` is the upstream Rive `in_band_asset.riv` fixture
(SHA-256 `465135b6b6ce5c720fc693b7334105af111c048d031b67a200d367eb753c7248`)
used to prove configured import calls Swift image decoding. The compact
`text_run_apple_seam.riv.base64` fixture is generated from the runtime's pinned
schema exactly like `text_run_apple_seam_artifact()` (SHA-256
`a106d6f53c77d68ffdf81c8e515f4ab09dbf8ee43ad0223fb7d5833843594e53`)
and proves atomic text-run mutation without committing a bundled font.

`sound_audio.riv.base64` is the upstream Rive
`tests/unit_tests/assets/sound.riv` fixture pinned at
`rive-app/rive-runtime@4ac7b32798da0482e441ef09304dc3b480ed3ee5` (decoded
SHA-256 `c913d05bbbf0da3621186de4090d45766d5f843defd881f7b9220bdfe2a42fb8`).
It proves that audio embedded in signed scene bytes remains valid across
render, detach, reattach, renderer-domain reset and teardown. It does not add a
product audio playback or external-audio delivery contract.

## Semantic bridge fixtures

`semantic_text.riv` is the schema-generated runtime semantic text fixture,
shared byte-for-byte with Android's device test asset (SHA-256
`4e5cbeb29d08c54311b631d6fae83b3d132246670a3e574e24980b9570505f5f`).
It exercises Unicode labels and exact text-run association, not glyph rendering.

`semantic_dropdown.riv` copies upstream
`tests/unit_tests/assets/semantic/data_binding_lists.riv` at
`rive-app/rive-runtime@9ed5b5168d95aab07e873db341fb65613d317cfc`
(SHA-256 `4c534c4b8033dba6fff83ccb4c1b2a935637a77094d2f6f7dcd91b7c8e641232`).
The runtime C ABI conformance suite uses the same authored dropdown. The Swift
bridge test checks that its semantic tap closes the initially expanded control
after ordinary stepping and presentation.

`make test-experience-input` runs the editor contract tests inside the runtime
host app, with UIKit's application dispatcher. It is included in `make test`.
The hosted test uses `semantic_text.riv` to prove captured native writes,
stale-capture retry after a new presentation, and response ordering against
the public runtime. The ordinary unhosted unit target invokes the registered
editing callback directly because it has no application dispatcher. Neither
suite substitutes for signed-scene, keyboard/IME or screen-reader qualification.

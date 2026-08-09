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

## `scripted_generic_commands.nux.base64`

Base64-encoded fixture derived from the UNIV-1845 production-publisher
generic-command proof. Its journey member was normalized to the SDK's current
signed `ScreenScriptRef` shape and the resulting manifest was signed by
`TEST_ONLY_DEV_KEYPAIR`. It contains one real scripted screen whose press
listener emits response, declared journey, custom, and deliberately malformed
product commands in a fixed authored order. Its declared purchase event has a
real navigation handler used by the JourneyRunner tracer. Keep the decoded
package SHA-256 at
`eedc072a069d22ec450935c01edc4eec3b85ccd7dab607c0bf8d55d8ac0939f3`.

## Apple platform seams

`in_band_asset.riv.base64` is the upstream Rive `in_band_asset.riv` fixture
(SHA-256 `465135b6b6ce5c720fc693b7334105af111c048d031b67a200d367eb753c7248`)
used to prove configured import calls Swift image decoding. The compact
`text_run_apple_seam.riv.base64` fixture is generated from the runtime's pinned
schema exactly like `text_run_apple_seam_artifact()` (SHA-256
`a106d6f53c77d68ffdf81c8e515f4ab09dbf8ee43ad0223fb7d5833843594e53`)
and proves atomic text-run mutation without committing a bundled font.

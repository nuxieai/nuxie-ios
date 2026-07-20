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

# Unit test fixtures

## `scripted_response_set.riv`

A minimal Rive file (Backboard + one Artboard) carrying one in-band Luau
script module named `nuxie_fixture_script`:

```lua
local Nuxie = require("nuxie")
Nuxie.response.set("plan", "pro")
return {}
```

The script bytecode is **unsigned** (SignedContentHeader flags byte `0x00`),
so the Rive runtime only registers it when the host opts in via
`RiveScriptRuntime.allowsUnverifiedScripts`. Used by
`NuxieRiveScriptBridgeScriptExecutionTests` to prove `Nuxie.response.set`
resolves through nested script-module tables on the real runtime.

Regenerate from the nuxie monorepo (`tools/rive-compiler`):

1. Compile the script with the same Luau revision the Rive runtime embeds
   (`luigi-rosso/luau` branch `rive_0_32` for runtime v0.1.135):
   `luau-compile --binary script.lua > script.luauc`
2. `./scripts/emit-scripted-riv.sh script.luauc scripted_response_set.riv nuxie_fixture_script`

## `data_binding_test.riv`

Editor-exported fixture used by `FlowViewModelBridgeTests` for ViewModel
data-binding coverage.

## `nuxie_runtime_two_artboards.riv.base64`

Base64-encoded copy of `nuxie-runtime/fixtures/minimal/two_artboards.riv`, used
by `NuxieRuntimeAdapterTests` as a known-renderable Slice 1 fixture. The test
selects artboard `Two`, which contains a dark background and a lighter
rectangle; it intentionally has no scripts, assets, or ViewModel dependency.
Keep the decoded bytes identical to the runtime fixture (SHA-256
`480472d9942711492ce37cdba9aea6266f254633f5a2ac4a9e30f9d0eca70e8c`).

## `publish_scripted_pressable.riv` (+ `_manifest.json`)

Emitted by the REAL publish pipeline from the monorepo's
`scripted-response-set` publish-path fixture (oracle-verified through native
rive-runtime import before export):

    ./scripts/verify-publish-path-oracle.sh --fixture scripted-response-set \
        --emit-artifacts-dir <dir>

Contains a `Paywall` artboard with a Pressable CTA (x:24 y:700 342x56), the
generated pressable visual state machine whose press-release listener holds a
riv-native `ScriptedListenerAction`, and the embedded `listenerAction` script
(unsigned bytecode) that calls `Nuxie.response.set("plan", "pro")` and
`Nuxie.trigger("purchase_tapped", {})`. Used by
`NuxieScriptedPressableInvocationTests` to prove the locked device-script
attachment model end to end.

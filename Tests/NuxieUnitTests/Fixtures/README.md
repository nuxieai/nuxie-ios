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

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

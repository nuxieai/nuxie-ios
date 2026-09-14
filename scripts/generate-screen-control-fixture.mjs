#!/usr/bin/env bun
// Run with Bun and the parent monorepo checkout as the only argument.
// Compiles real listener-action bytecode and the publisher's generated machine.
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const root=resolve(process.argv[2] ?? '../../');
const {buildEditorRiveViaWasm}=await import(pathToFileURL(resolve(root,'packages/view-compiler/src/compiler-backends/editor-publisher-wasm.ts')).href);
const compiler=await import(pathToFileURL(resolve(root,'apps/nuxie-publish/src/generated/editor_scripted_resource_compiler.js')).href);
compiler.initSync({module:readFileSync(resolve(root,'apps/nuxie-publish/src/generated/editor_scripted_resource_compiler_bg.wasm'))});
const source = `local Nuxie = require("nuxie")
return function(context)
  return { actions = { submit = function(invocation)
    Nuxie.response.set("selection", "pro")
    Nuxie.emit("script_control_activated", { source = "compiled" })
  end } }
end`;
const compiled = JSON.parse(compiler.compileScriptedResource(JSON.stringify({type:'compileScreenActionBytecode',source,actionId:'submit'})));
if (!compiled.ok) throw new Error(JSON.stringify(compiled));
const snapshotPath='tools/rive-compiler/fixtures/publish-path/scripted-response-set.json';
const snapshot=JSON.parse(readFileSync(resolve(root,snapshotPath),'utf8')).snapshotArtifact.snapshot;
const output=await buildEditorRiveViaWasm({snapshot,screenScripts:[{hostId:'screen_1',scriptId:'script_response_set',assetId:'asset_script_response_set',protocol:'listenerAction',bytecode:Buffer.from(compiled.bytecodeBase64,'base64')}]});
if (output.externalAssetFiles.length !== 0) throw new Error('Fixture must be self-contained');
const directory=new URL('../fixtures/runtime/screen-control/',import.meta.url);
mkdirSync(directory,{recursive:true});
writeFileSync(new URL('screen.riv',directory),output.rivBytes);
writeFileSync(new URL('action.luau',directory),source);
writeFileSync(new URL('provenance.json',directory),JSON.stringify({
  publisherSourceCommit:execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),
  snapshotPath, sha256:createHash('sha256').update(output.rivBytes).digest('hex'),
  sizeBytes:output.rivBytes.length,
  qualification:'Publisher-generated native control fixture; full signed SDK admission and durable routing require separate qualification.',
},null,2)+'\n');
console.log('Generated native screen-control fixture',output.rivBytes.length);

#!/usr/bin/env bun
// Run with Bun and the parent monorepo checkout as the only argument.
// Compiles real listener-action bytecode and the publisher's generated machine.
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs';
import {resolve} from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash,createPrivateKey,createPublicKey,sign} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const root=resolve(process.argv[2] ?? '../../');
const failing=process.argv.includes('--failure');
const fixtureName=failing?'screen-control-error':'screen-control';
const releaseName=failing?'compiled-screen-control-error':'compiled-screen-control';
const {buildEditorRiveViaWasm}=await import(pathToFileURL(resolve(root,'packages/view-compiler/src/compiler-backends/editor-publisher-wasm.ts')).href);
const compiler=await import(pathToFileURL(resolve(root,'apps/nuxie-publish/src/generated/editor_scripted_resource_compiler.js')).href);
compiler.initSync({module:readFileSync(resolve(root,'apps/nuxie-publish/src/generated/editor_scripted_resource_compiler_bg.wasm'))});
const source = `local Nuxie = require("nuxie")
return function(context)
  return { actions = { submit = function(invocation)
    Nuxie.response.set("selection", "pro")
    ${failing ? 'error("script_failure_probe")' : 'Nuxie.emit("script_control_activated", { source = "compiled" })'}
  end } }
end`;
const compiled = JSON.parse(compiler.compileScriptedResource(JSON.stringify({type:'compileScreenActionBytecode',source,actionId:'submit'})));
if (!compiled.ok) throw new Error(JSON.stringify(compiled));
const snapshotPath='tools/rive-compiler/fixtures/publish-path/scripted-response-set.json';
const snapshot=JSON.parse(readFileSync(resolve(root,snapshotPath),'utf8')).snapshotArtifact.snapshot;
const output=await buildEditorRiveViaWasm({snapshot,screenScripts:[{hostId:'screen_1',scriptId:'script_response_set',assetId:'asset_script_response_set',protocol:'listenerAction',bytecode:Buffer.from(compiled.bytecodeBase64,'base64')}]});
if (output.externalAssetFiles.length !== 0) throw new Error('Fixture must be self-contained');
const directory=new URL(`../fixtures/runtime/${fixtureName}/`,import.meta.url);
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

// A test-authored signed Journey around the real publisher render and action bytes.
const releaseDirectory=new URL(`../fixtures/journeys/rendered-${fixtureName}/`,import.meta.url);
mkdirSync(releaseDirectory,{recursive:true});
const sha256=bytes=>createHash('sha256').update(bytes).digest('hex');
function artifact(bytes,prefix,contentType) {
  const sha=sha256(bytes), key=`${prefix}/sha256/${sha}.${prefix==='renders'?'riv':'bin'}`;
  const path=new URL(key,releaseDirectory);
  mkdirSync(new URL('./',path),{recursive:true});writeFileSync(path,bytes);
  return {key,sha256:sha,sizeBytes:bytes.length,contentType};
}
const base=JSON.parse(readFileSync(new URL('../fixtures/journeys/rendered-text-input/release-entry.json',import.meta.url),'utf8'));
const descriptor=JSON.parse(Buffer.from(base.envelope.descriptorBytesBase64,'base64'));
descriptor.identity={...descriptor.identity,appId:`app-${releaseName}`,buildId:`${releaseName}-build`,experienceId:releaseName,experienceVersionId:`${releaseName}-v1`};
descriptor.metadata={...descriptor.metadata,name:'compiled-screen-control',description:'Test-authored signed Journey over publisher-generated native action bytecode'};
descriptor.leg={...descriptor.leg,id:sha256(`${releaseName}-leg`),entryStepId:'show',outputs:[{key:'selection',required:true,type:'text'}],screens:[{id:'screen_1',responseCaptures:['selection']}],steps:[
  {kind:'action',id:'show',action:{type:'navigate',screenId:'screen_1'},outlets:{}},
  {kind:'action',id:'refresh',action:{type:'navigate',screenId:'screen_1'},outlets:{}},
],routes:[{host:{kind:'screen',screenId:'screen_1'},eventName:'script_control_activated',entryStepId:'refresh'}]};
const scriptBytes=Buffer.from(JSON.stringify({protocol:'screen-actions',actions:[{actionId:'submit',bytecodeBase64:compiled.bytecodeBase64}]}));
descriptor.screenBehaviors=[{screenId:'screen_1',controls:[{actionId:'submit',behavior:{kind:'script'}}],script:{protocol:'screen-actions',exportedActionIds:['submit'],artifact:artifact(scriptBytes,'screen-behavior','application/octet-stream')}}];
descriptor.render={renderer:'rive',riv:artifact(output.rivBytes,'renders','application/vnd.rive'),assets:[],screens:[{id:'screen_1',artboardId:'screen_1',artboardName:'Paywall',width:390,height:844}],textInputs:[],transitions:[]};
descriptor.viewModelValues=[];
function canonical(value) {
  if(value===null||typeof value!=='object') return JSON.stringify(value);
  if(Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.keys(value).sort().map(k=>`${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
}
const key=createPrivateKey({key:Buffer.concat([Buffer.from('302e020100300506032b657004220420','hex'),Buffer.alloc(32,0x42)]),format:'der',type:'pkcs8'});
const descriptorBytes=Buffer.from(canonical(descriptor));
const entry={locator:{...descriptor.identity,legId:descriptor.leg.id},envelope:{mediaType:'application/vnd.nuxie.journey+json',encoding:'base64',descriptorSha256:sha256(descriptorBytes),descriptorSizeBytes:descriptorBytes.length,descriptorBytesBase64:descriptorBytes.toString('base64'),signature:{version:1,algorithm:'ed25519',keyId:'TEST_ONLY_DEV_KEYPAIR',signatureBase64:sign(null,Buffer.concat([Buffer.from('nuxie.journey-release.v1\0'),descriptorBytes]),key).toString('base64')}}};
writeFileSync(new URL('release-entry.json',releaseDirectory),JSON.stringify(entry,null,2)+'\n');
writeFileSync(new URL('provenance.json',releaseDirectory),JSON.stringify({
  publisherSourceCommit:execFileSync('git',['-C',root,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),
  descriptorSha256:entry.envelope.descriptorSha256,
  publicKeyBase64:createPublicKey(key).export({format:'der',type:'spki'}).subarray(-32).toString('base64'),
  qualification:'Test-authored signed Journey and screen-actions artifact around actual publisher-generated render bytes; not a full production publisher release qualification.',
},null,2)+'\n');

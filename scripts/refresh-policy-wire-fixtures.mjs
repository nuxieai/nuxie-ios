// Re-sign retained test fixtures for the current policy wire contract.
// This only uses the public, deterministic test key; never use production artifacts.
import { createPrivateKey, createPublicKey, createHash, sign, verify } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, dirname } from 'node:path';
const root = resolve(process.argv[2] ?? fileURLToPath(new URL('..', import.meta.url)));
const dryRun = process.argv.includes('--dry-run');
const paths = process.argv.slice(3).filter(value => value !== '--dry-run');
const files = execFileSync('git', ['ls-files', ...(paths.length ? paths : ['fixtures', 'Tests'])], { cwd: root, encoding: 'utf8' })
  .trim().split('\n').filter((name) => name.endsWith('.json'));
const key = createPrivateKey({ key: Buffer.concat([
  Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.alloc(32, 0x42),
]), format: 'der', type: 'pkcs8' });
const publicKey = createPublicKey(key);
const canonical = (value) => Array.isArray(value) ? `[${value.map(canonical).join(',')}]`
  : value && typeof value === 'object'
    ? `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`
    : JSON.stringify(value);
const replacements = new Map();
const documents = [];
const nativeInput = JSON.parse(readFileSync(resolve(root, 'fixtures/runtime/published-input/text-inputs.json'), 'utf8'))[0];
const nativeProvenance = JSON.parse(readFileSync(resolve(root, 'fixtures/runtime/published-input/provenance.json'), 'utf8'));
const nativeBytes = readFileSync(resolve(root, 'fixtures/runtime/published-input/screen.riv'));
if (createHash('sha256').update(nativeBytes).digest('hex') !== nativeProvenance.sha256) {
  throw new Error('F3 artifact does not match its published provenance');
}
const removedInputFields = ['textObjectKey', 'textRunObjectKey', 'textName', 'textRunName', 'editableValueName'];
const migratedInputs = [];
const artifactWrites = new Map();
function migrateInputTable(descriptor, fixturePath) {
  const render = descriptor.render;
  if (!render?.textInputs?.length) return;
  const previousScene = render.nux.sha256;
  const oldInputs = render.textInputs;
  if (fixturePath.includes('rendered-custom-transition/') || fixturePath.includes('rendered-semantic-roles/')) {
    // These scenes retain their transition/role oracles. Native editing is covered by F3
    // and the separately qualified secure TextInput fixture, not by their old text runs.
    render.textInputs = [];
    migratedInputs.push({ fixturePath, previousScene, replacement: 'remove retired input declarations; retain non-input scene' });
    return;
  }
  const synthetic = fixturePath === 'fixtures/journeys/planes/release.json'
    || fixturePath === 'fixtures/journeys/planes/text-input-navigation.json';
  if (synthetic) {
    for (const input of oldInputs) {
      input.textInputName = nativeInput.textInputName;
      for (const field of removedInputFields) delete input[field];
    }
    migratedInputs.push({ fixturePath, replacement: 'admission-only table uses published F3 locator' });
    return;
  }
  const key = `renders/sha256/${nativeProvenance.sha256}.nux`;
  render.nux = { contentType: 'application/vnd.nuxie.scene', key,
    sha256: nativeProvenance.sha256, sizeBytes: nativeBytes.length };
  render.assets = nativeProvenance.fonts.map(font => ({ kind: 'font', ...font }));
  descriptor.requirements.requiredCapabilities = [...new Set([
    ...(descriptor.requirements.requiredCapabilities ?? []), 'system-fonts',
  ])].sort();
  for (const screen of render.screens) {
    const input = oldInputs.find(input => input.screenId === screen.id);
    const nativeScreen = input ? 'input' : 'greeting';
    screen.artboardId = `scr_screens_s${nativeScreen}`;
    screen.artboardName = nativeScreen;
    screen.width = 393;
    screen.height = 852;
    const legScreen = descriptor.leg.screens.find(item => item.id === screen.id);
    legScreen.defaultViewModelName = `Runtime ${nativeScreen} scr_screens_s${nativeScreen}`;
  }
  render.textInputs = oldInputs.map(input => ({
    ...nativeInput, id: input.id, screenId: input.screenId,
    ...Object.fromEntries(['responseFieldKey', 'responseCapture', 'actionEvent', 'declarativeActionId',
      'placeholder', 'keyboardType', 'maxLength'].filter(key => key in input).map(key => [key, input[key]])),
  }));
  const fixtureDirectory = fixturePath.startsWith('fixtures/journeys/planes/')
    ? resolve(root, 'fixtures/journeys/rendered-text-input') : dirname(resolve(root, fixturePath));
  const destination = resolve(fixtureDirectory, key);
  artifactWrites.set(destination, nativeBytes);
  migratedInputs.push({ fixturePath, previousScene, replacement: nativeProvenance.sha256,
    sourceCommit: nativeProvenance.publisherSourceCommit });
}

let envelopes = 0;
const refresh = (value, fixturePath) => {
  if (!value || typeof value !== 'object') return;
  if (value.descriptorBytesBase64 && value.signature) {
    const previousBytes = Buffer.from(value.descriptorBytesBase64, 'base64');
    const descriptor = JSON.parse(previousBytes.toString('utf8'));
    if (value.signature.keyId !== 'TEST_ONLY_DEV_KEYPAIR' || !verify(null,
      Buffer.concat([Buffer.from(`${descriptor.schemaVersion}\0`), previousBytes]),
      publicKey, Buffer.from(value.signature.signatureBase64, 'base64'))) {
      throw new Error('Refusing to refresh an unverified fixture envelope');
    }
    if (descriptor.schemaVersion !== 'nuxie.journey-release.v3') migrateInputTable(descriptor, fixturePath);
    descriptor.schemaVersion = 'nuxie.journey-release.v3';
    // Retained fixtures declare no native forms; compiled state remains catalog-owned.
    descriptor.state ??= {};
    descriptor.responses ??= {};
    descriptor.ruleGroups ??= [];
    const bytes = Buffer.from(canonical(descriptor));
    const digest = createHash('sha256').update(bytes).digest('hex');
    replacements.set(value.descriptorSha256, digest);
    value.descriptorBytesBase64 = bytes.toString('base64');
    value.descriptorSizeBytes = bytes.length;
    value.descriptorSha256 = digest;
    value.signature.signatureBase64 = sign(null,
      Buffer.concat([Buffer.from('nuxie.journey-release.v3\0'), bytes]), key).toString('base64');
    envelopes++;
  }
  for (const [key, child] of Object.entries(value)) {
    if (child === 'nuxie.journey-plane-profile.v1') value[key] = 'nuxie.journey-plane-profile.v2';
    else if (child === 'nuxie.journey-release.v1' || child === 'nuxie.journey-release.v2') value[key] = 'nuxie.journey-release.v3';
    else refresh(child, fixturePath);
  }
};
for (const name of files) {
  const path = resolve(root, name);
  const source = readFileSync(path, 'utf8');
  const value = JSON.parse(source);
  refresh(value, name);
  if (name === 'fixtures/journeys/rendered-text-input/provenance.json') {
    value.historicalQualification ??= value.qualification;
    value.qualification = 'F3 native read and admission qualified; migrated signed editing, navigation and response qualification pending native write contract';
    if (value.descriptorRefresh) value.descriptorRefresh.reason = 'Historical policy and offer refresh preserved the former render; nativeInputMigration replaces that render with F3';
    value.nativeInputMigration = {
      source: 'fixtures/runtime/published-input/screen.riv',
      sourceCommit: nativeProvenance.publisherSourceCommit, sha256: nativeProvenance.sha256,
      reason: 'Release v3 native TextInput hard cut; original Journey routes and response declarations retained',
    };
  }
  documents.push({ path, source, value });
}
// Validate every old envelope before writing any refreshed fixture or artifact.
if (!dryRun) {
  for (const [destination, bytes] of artifactWrites) {
    mkdirSync(dirname(destination), { recursive: true });
    writeFileSync(destination, bytes);
  }
}
// References can cross files (for example, provenance and cached profile arms).
for (const { path, source, value } of documents) {
  let encoded = JSON.stringify(value);
  for (const [previous, current] of replacements) encoded = encoded.replaceAll(previous, current);
  if (!dryRun && encoded !== JSON.stringify(JSON.parse(source))) {
    writeFileSync(path, `${JSON.stringify(JSON.parse(encoded), null, 2)}\n`);
  }
}
// Published fixture manifests cover the re-signed envelopes as well as scene bytes.
if (!dryRun) for (const { path, value } of documents) {
  if (!path.endsWith('/provenance.json') || !value.files || Array.isArray(value.files)) continue;
  const current = JSON.parse(readFileSync(path, 'utf8'));
  for (const [name, record] of Object.entries(current.files)) {
    const bytes = readFileSync(resolve(dirname(path), name));
    record.sha256 = createHash('sha256').update(bytes).digest('hex');
    record.sizeBytes = bytes.length;
  }
  writeFileSync(path, `${JSON.stringify(current, null, 2)}\n`);
}
if (!dryRun && migratedInputs.some(item => item.previousScene || item.fixturePath === 'fixtures/journeys/planes/release.json')) writeFileSync(resolve(root, 'fixtures/journeys/planes/release-v3-migration.json'), `${JSON.stringify(migratedInputs, null, 2)}\n`);
console.log(JSON.stringify({ dryRun, verifiedEnvelopes: envelopes, migratedInputs }, null, 2));

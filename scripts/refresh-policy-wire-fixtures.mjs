// Re-sign retained test fixtures for the current policy wire contract.
// This only uses the public, deterministic test key; never use production artifacts.
import { createPrivateKey, createPublicKey, createHash, sign, verify } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';
const root = fileURLToPath(new URL('..', import.meta.url));
const files = execFileSync('git', ['ls-files', 'fixtures', 'Tests'], { cwd: root, encoding: 'utf8' })
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
let envelopes = 0;
const refresh = (value) => {
  if (!value || typeof value !== 'object') return;
  if (value.descriptorBytesBase64 && value.signature) {
    const previousBytes = Buffer.from(value.descriptorBytesBase64, 'base64');
    const descriptor = JSON.parse(previousBytes.toString('utf8'));
    if (value.signature.keyId !== 'TEST_ONLY_DEV_KEYPAIR' || !verify(null,
      Buffer.concat([Buffer.from(`${descriptor.schemaVersion}\0`), previousBytes]),
      publicKey, Buffer.from(value.signature.signatureBase64, 'base64'))) {
      throw new Error('Refusing to refresh an unverified fixture envelope');
    }
    descriptor.schemaVersion = 'nuxie.journey-release.v2';
    const bytes = Buffer.from(canonical(descriptor));
    const digest = createHash('sha256').update(bytes).digest('hex');
    replacements.set(value.descriptorSha256, digest);
    value.descriptorBytesBase64 = bytes.toString('base64');
    value.descriptorSizeBytes = bytes.length;
    value.descriptorSha256 = digest;
    value.signature.signatureBase64 = sign(null,
      Buffer.concat([Buffer.from('nuxie.journey-release.v2\0'), bytes]), key).toString('base64');
    envelopes++;
  }
  for (const [key, child] of Object.entries(value)) {
    if (child === 'nuxie.journey-plane-profile.v1') value[key] = 'nuxie.journey-plane-profile.v2';
    else if (child === 'nuxie.journey-release.v1') value[key] = 'nuxie.journey-release.v2';
    else refresh(child);
  }
};
for (const name of files) {
  const path = resolve(root, name);
  const source = readFileSync(path, 'utf8');
  const value = JSON.parse(source);
  refresh(value);
  documents.push({ path, source, value });
}
// References can cross files (for example, provenance and cached profile arms).
for (const { path, source, value } of documents) {
  let encoded = JSON.stringify(value);
  for (const [previous, current] of replacements) encoded = encoded.replaceAll(previous, current);
  if (encoded !== JSON.stringify(JSON.parse(source))) {
    writeFileSync(path, `${JSON.stringify(JSON.parse(encoded), null, 2)}\n`);
  }
}
console.log(`Verified and refreshed ${envelopes} signed fixture envelopes.`);

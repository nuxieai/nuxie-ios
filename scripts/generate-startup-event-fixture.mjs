#!/usr/bin/env node
// Reuse the qualified publisher bytes; change and sign only the test Journey entry condition.
import { readFileSync, writeFileSync, mkdirSync, copyFileSync } from 'node:fs';
import { createHash, createPrivateKey, sign } from 'node:crypto';

const source = new URL('../fixtures/journeys/rendered-screen-control/', import.meta.url);
const target = new URL('../fixtures/journeys/rendered-startup-event/', import.meta.url);
const original = JSON.parse(readFileSync(new URL('release-entry.json', source), 'utf8'));
const provenance = JSON.parse(readFileSync(new URL('provenance.json', source), 'utf8'));
const descriptor = JSON.parse(Buffer.from(original.envelope.descriptorBytesBase64, 'base64'));
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const name = 'compiled-startup-event';
descriptor.identity = { ...descriptor.identity, appId: `app-${name}`, buildId: `${name}-build`,
  experienceId: name, experienceVersionId: `${name}-v1` };
descriptor.leg.id = sha256(`${name}-leg`);
descriptor.leg.entryCondition = { type: 'event', eventName: 'startup_probe' };
descriptor.metadata = { ...descriptor.metadata, name,
  description: 'Test-authored event-entry Journey reusing publisher-generated native control bytes' };
function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
}
// Publicly documented test-only development seed; never a production signing key.
const key = createPrivateKey({ key: Buffer.concat([
  Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.alloc(32, 0x42),
]), format: 'der', type: 'pkcs8' });
const bytes = Buffer.from(canonical(descriptor));
const entry = { locator: { ...descriptor.identity, legId: descriptor.leg.id }, envelope: {
  ...original.envelope, descriptorSha256: sha256(bytes), descriptorSizeBytes: bytes.length,
  descriptorBytesBase64: bytes.toString('base64'), signature: {
    ...original.envelope.signature,
    signatureBase64: sign(null, Buffer.concat([Buffer.from('nuxie.journey-release.v1\0'), bytes]), key).toString('base64'),
  },
} };
mkdirSync(target, { recursive: true });
for (const artifact of [descriptor.render.riv, ...descriptor.render.assets,
  ...descriptor.screenBehaviors.map(behavior => behavior.script.artifact)]) {
  const path = new URL(artifact.key, target);
  mkdirSync(new URL('./', path), { recursive: true });
  const input = new URL(artifact.key, source);
  if (sha256(readFileSync(input)) !== artifact.sha256) throw new Error('Source artifact digest mismatch');
  copyFileSync(input, path);
}
writeFileSync(new URL('release-entry.json', target), JSON.stringify(entry, null, 2) + '\n');
writeFileSync(new URL('provenance.json', target), JSON.stringify({
  ...provenance, descriptorSha256: entry.envelope.descriptorSha256,
  sourceFixture: 'journeys/rendered-screen-control', sourceDescriptorSha256: original.envelope.descriptorSha256,
  qualification: 'Test-authored event-entry signed Journey; reuses unchanged publisher-generated render and screen-action artifacts. Not a live publisher release qualification.',
}, null, 2) + '\n');

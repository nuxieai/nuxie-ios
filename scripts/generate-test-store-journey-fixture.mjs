#!/usr/bin/env node
import { createHash, createPrivateKey, createPublicKey, sign } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';

// Public test-only seed. Render bytes remain the publisher-produced text-input corpus.
const key = createPrivateKey({ key: Buffer.concat([
  Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.alloc(32, 0x42),
]), format: 'der', type: 'pkcs8' });
const base = new URL('../fixtures/journeys/rendered-text-input/release-entry.json', import.meta.url);
const source = JSON.parse(readFileSync(base, 'utf8'));
const original = JSON.parse(Buffer.from(source.envelope.descriptorBytesBase64, 'base64'));
const products = JSON.parse(readFileSync(new URL('../fixtures/journeys/planes/release.json', import.meta.url), 'utf8'));
const catalog = JSON.parse(Buffer.from(products.renderedEntry.envelope.descriptorBytesBase64, 'base64'));
function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.keys(value).sort().map(k => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
}
const entries = {};
for (const action of ['purchase', 'restore']) {
  const d = structuredClone(original);
  d.identity = { ...d.identity, appId: `app-test-store-${action}`, experienceId: `test-store-${action}`,
    experienceVersionId: `test-store-${action}-v1`, buildId: `test-store-${action}-build` };
  const product = structuredClone(catalog.products[0]);
  product.store = { platform: 'google_play', productId: 'test-store-monthly', productType: 'subs', basePlanId: 'monthly' };
  d.products = [product];
  d.placements = [{ id: 'test-store:monthly', productId: product.id }];
  d.leg.id = `test-store-${action}-leg`;
  d.leg.outputs = [];
  d.leg.reentry = { type: 'one_time' };
  d.leg.steps = [d.leg.steps[0], {
    kind: 'action', id: action, action: { type: action, ...(action === 'purchase' ? { placementId: 'test-store:monthly' } : {}) },
    outlets: action === 'purchase' ? { completed: 'done', cancelled: 'done', failed: 'done' } : { restored: 'done', noPurchases: 'done', failed: 'done' },
  }, { kind: 'complete', id: 'done', outcome: 'continue' }];
  d.leg.routes = [{ host: { kind: 'screen', screenId: 'screen_1' }, eventName: '$screen_shown', entryStepId: action }];
  const bytes = Buffer.from(canonical(d));
  entries[action] = { locator: { ...d.identity, legId: d.leg.id }, envelope: {
    mediaType: 'application/vnd.nuxie.journey+json', encoding: 'base64',
    descriptorSha256: createHash('sha256').update(bytes).digest('hex'), descriptorSizeBytes: bytes.length,
    descriptorBytesBase64: bytes.toString('base64'), signature: { version: 1, algorithm: 'ed25519',
      keyId: 'TEST_ONLY_DEV_KEYPAIR', signatureBase64: sign(null, Buffer.concat([Buffer.from('nuxie.journey-release.v1\0'), bytes]), key).toString('base64') },
  } };
}
const directory = new URL('../fixtures/journeys/planes/', import.meta.url);
mkdirSync(directory, { recursive: true });
writeFileSync(new URL('test-store-orchestration.json', directory), `${JSON.stringify({
  description: 'Test-authored, signed purchase/restore routes over unchanged publisher text-input render bytes; not a publisher commerce qualification.',
  artifactFixture: 'journeys/rendered-text-input',
  publicKeyBase64: createPublicKey(key).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64'),
  entries,
}, null, 2)}\n`);

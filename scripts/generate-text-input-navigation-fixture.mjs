#!/usr/bin/env node
import { createHash, createPrivateKey, createPublicKey, sign } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';

// Public test-only signing seed, shared with the SDK runtime-host fixtures.
const privateKey = createPrivateKey({
  key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), Buffer.alloc(32, 0x42)]),
  format: 'der', type: 'pkcs8',
});
const fixtureRoot = new URL('../fixtures/journeys/planes/', import.meta.url);
const original = JSON.parse(readFileSync(new URL('release.json', fixtureRoot), 'utf8'));
const descriptor = JSON.parse(Buffer.from(original.renderedEntry.envelope.descriptorBytesBase64, 'base64'));
const secondScreen = structuredClone(descriptor.leg.screens[0]);
secondScreen.id = 'screen_details';
secondScreen.defaultInstanceId = 'details';
secondScreen.defaultViewModelName = 'DetailsModel';
descriptor.leg.screens.push(secondScreen);
descriptor.screenBehaviors.push({ screenId: secondScreen.id, controls: [] });
descriptor.screenBehaviors.sort((a, b) => a.screenId < b.screenId ? -1 : 1);
const secondArtboard = structuredClone(descriptor.render.screens[0]);
secondArtboard.id = 'screen_details';
secondArtboard.artboardId = 'artboard_details';
secondArtboard.artboardName = 'Details';
descriptor.render.screens.push(secondArtboard);
const secondInput = structuredClone(descriptor.render.textInputs[0]);
// Deliberately reuse the input ID: draft ownership must include the screen.
secondInput.screenId = 'screen_details';
secondInput.artboardId = 'artboard_details';
secondInput.value = 'Details default';
descriptor.render.textInputs.push(secondInput);

function canonical(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonical(value[key])}`).join(',')}}`;
}
function entry(value) {
  const bytes = Buffer.from(canonical(value));
  return {
    locator: { ...value.identity, legId: value.leg.id },
    envelope: {
      mediaType: 'application/vnd.nuxie.journey+json', encoding: 'base64',
      descriptorSha256: createHash('sha256').update(bytes).digest('hex'),
      descriptorSizeBytes: bytes.length, descriptorBytesBase64: bytes.toString('base64'),
      signature: {
        version: 1, algorithm: 'ed25519', keyId: 'TEST_ONLY_DEV_KEYPAIR',
        signatureBase64: sign(null, Buffer.concat([Buffer.from('nuxie.journey-release.v1\0'), bytes]), privateKey).toString('base64'),
      },
    },
  };
}
const nextBuild = structuredClone(descriptor);
nextBuild.identity.buildId += '-next';
nextBuild.identity.publishedAtSeq += 1;
const fixture = {
  description: 'Signed two-screen text draft fixture. The same input ID belongs to independent screens; a new build must start fresh.',
  publicKeyBase64: createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64'),
  renderedEntry: entry(descriptor), nextBuildEntry: entry(nextBuild),
};
writeFileSync(new URL('text-input-navigation.json', fixtureRoot), `${JSON.stringify(fixture, null, 2)}\n`);

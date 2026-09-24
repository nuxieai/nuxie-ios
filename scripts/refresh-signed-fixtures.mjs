#!/usr/bin/env node

import {
  createHash,
  createPrivateKey,
  sign as signBytes,
} from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const profilePaths = [
  "Tests/ExperienceRuntimeHostApp/Fixtures/animation-event/profile.json",
  "Tests/ExperienceRuntimeHostApp/Fixtures/external-image/profile.json",
  "Tests/ExperienceRuntimeHostApp/Fixtures/font-converter/profile.json",
  "Tests/ExperienceRuntimeHostApp/Fixtures/rendered-text-input/profile.json",
  "Tests/ExperienceRuntimeHostApp/Fixtures/multi-screen/profile.json",
  "Tests/ExperienceRuntimeHostApp/Fixtures/scripted-resources/profile.json",
  "Tests/ExperienceRuntimeHostApp/PresentationStates/drawer-bottom/profile.json",
  "Tests/ExperienceRuntimeHostApp/PresentationStates/drawer-trailing/profile.json",
  "Tests/ExperienceRuntimeHostApp/PresentationStates/full-screen-dark/profile.json",
  "Tests/ExperienceRuntimeHostApp/PresentationStates/full-screen-light/profile.json",
  "Tests/ExperienceRuntimeHostApp/PresentationStates/full-screen-midtone/profile.json",
  "Tests/ExperienceRuntimeHostApp/PresentationStates/sheet-large/profile.json",
  "Tests/ExperienceRuntimeHostApp/PresentationStates/sheet-medium/profile.json",
  "Tests/ExperienceRuntimeHostApp/PresentationStates/sheet-non-dismissible/profile.json",
];
const entryPaths = [
  "fixtures/journeys/rendered-text-input/release-entry.json",
  "fixtures/journeys/rendered-custom-transition/release-entry.json",
  "fixtures/journeys/rendered-semantic-roles/release-entry.json",
];
const privateKey = createPrivateKey({
  key: Buffer.concat([
    Buffer.from("302e020100300506032b657004220420", "hex"),
    Buffer.alloc(32, 0x42),
  ]),
  format: "der",
  type: "pkcs8",
});
const signatureDomain = Buffer.from("nuxie.journey-release.v2\0", "utf8");

const canonicalJson = (value) => {
  if (value === null || typeof value !== "object") {
    const encoded = JSON.stringify(value);
    if (encoded === undefined) throw new Error("canonical-json.invalid-value");
    return encoded;
  }
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  return `{${Object.keys(value)
    .sort()
    .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
    .join(",")}}`;
};

const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

for (const relativePath of [...profilePaths, ...entryPaths]) {
  const path = resolve(relativePath);
  const profile = JSON.parse(await readFile(path, "utf8"));
  const isProfile = profilePaths.includes(relativePath);
  if (isProfile && profile.schemaVersion !== "nuxie.journey-plane-profile.v2") {
    throw new Error(`${relativePath}: expected a canonical Journey profile`);
  }

  const digestReplacements = new Map();
  for (const release of isProfile ? profile.releases : [profile]) {
    const previousDigest = release.envelope.descriptorSha256;
    const descriptor = JSON.parse(
      Buffer.from(release.envelope.descriptorBytesBase64, "base64").toString("utf8"),
    );
    if (descriptor.schemaVersion !== "nuxie.journey-release.v2") {
      throw new Error(`${relativePath}: expected a canonical Journey release`);
    }
    // These retained host fixtures predate explicit font source declarations.
    // Refresh their signed wire data; production consumers remain strict.
    for (const asset of descriptor.render.assets) {
      if (asset.kind === "font" && asset.location === undefined) {
        if (typeof asset.key !== "string" || typeof asset.sha256 !== "string") {
          throw new Error(`${relativePath}: external font fixture lacks artifact identity`);
        }
        asset.location = "cdn";
      }
    }
    const descriptorBytes = Buffer.from(canonicalJson(descriptor), "utf8");
    const descriptorSha256 = sha256(descriptorBytes);
    release.locator.legId = descriptor.leg.id;
    release.envelope = {
      mediaType: "application/vnd.nuxie.journey+json",
      encoding: "base64",
      descriptorSha256,
      descriptorSizeBytes: descriptorBytes.length,
      descriptorBytesBase64: descriptorBytes.toString("base64"),
      signature: {
        version: 1,
        algorithm: "ed25519",
        keyId: "TEST_ONLY_DEV_KEYPAIR",
        signatureBase64: signBytes(
          null,
          Buffer.concat([signatureDomain, descriptorBytes]),
          privateKey,
        ).toString("base64"),
      },
    };
    digestReplacements.set(previousDigest, {
      descriptorSha256,
      legId: descriptor.leg.id,
    });
  }

  for (const arm of isProfile ? profile.armedLegs : []) {
    const replacement = digestReplacements.get(arm.reference.descriptorSha256);
    if (!replacement) {
      throw new Error(`${relativePath}: arm does not reference a release`);
    }
    arm.reference.descriptorSha256 = replacement.descriptorSha256;
    arm.reference.legId = replacement.legId;
  }
  if (!isProfile) {
    const provenancePath = resolve(dirname(path), "provenance.json");
    const provenance = JSON.parse(await readFile(provenancePath, "utf8"));
    const replacement = digestReplacements.get(provenance.descriptorSha256);
    if (!replacement) throw new Error(`${relativePath}: provenance digest does not match release`);
    if (replacement.descriptorSha256 !== provenance.descriptorSha256) {
      provenance.descriptorRefresh = {
        script: "scripts/refresh-signed-fixtures.mjs",
        reason: "Explicit CDN font source declarations; published render and asset bytes unchanged",
        previousDescriptorSha256: provenance.descriptorSha256,
      };
      provenance.descriptorSha256 = replacement.descriptorSha256;
      await writeFile(provenancePath, `${JSON.stringify(provenance, null, 2)}\n`);
    }
  }
  await writeFile(path, `${JSON.stringify(profile, null, 2)}\n`);
}

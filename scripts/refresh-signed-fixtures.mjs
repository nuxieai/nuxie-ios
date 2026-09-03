#!/usr/bin/env node

import {
  createHash,
  createPrivateKey,
  sign as signBytes,
} from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const profilePaths = [
  "Tests/ExperienceRuntimeHostApp/Fixtures/animation-event/profile.json",
  "Tests/ExperienceRuntimeHostApp/Fixtures/external-image/profile.json",
  "Tests/ExperienceRuntimeHostApp/Fixtures/font-converter/profile.json",
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
const privateKey = createPrivateKey({
  key: Buffer.concat([
    Buffer.from("302e020100300506032b657004220420", "hex"),
    Buffer.alloc(32, 0x42),
  ]),
  format: "der",
  type: "pkcs8",
});
const signatureDomain = Buffer.from("nuxie.journey-release.v1\0", "utf8");

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

for (const relativePath of profilePaths) {
  const path = resolve(relativePath);
  const profile = JSON.parse(await readFile(path, "utf8"));
  if (profile.schemaVersion !== "nuxie.journey-plane-profile.v1") {
    throw new Error(`${relativePath}: expected a canonical Journey profile`);
  }

  const digestReplacements = new Map();
  for (const release of profile.releases) {
    const previousDigest = release.envelope.descriptorSha256;
    const descriptor = JSON.parse(
      Buffer.from(release.envelope.descriptorBytesBase64, "base64").toString("utf8"),
    );
    if (descriptor.schemaVersion !== "nuxie.journey-release.v1") {
      throw new Error(`${relativePath}: expected a canonical Journey release`);
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

  for (const arm of profile.armedLegs) {
    const replacement = digestReplacements.get(arm.reference.descriptorSha256);
    if (!replacement) {
      throw new Error(`${relativePath}: arm does not reference a release`);
    }
    arm.reference.descriptorSha256 = replacement.descriptorSha256;
    arm.reference.legId = replacement.legId;
  }
  await writeFile(path, `${JSON.stringify(profile, null, 2)}\n`);
}

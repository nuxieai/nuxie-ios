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
  "Tests/NuxieUnitTests/Fixtures/scripted-generic-commands/profile.json",
];
const envelopePaths = [
  "fixtures/experience-release-descriptor-v2/envelope.json",
];
const privateKey = createPrivateKey({
  key: Buffer.concat([
    Buffer.from("302e020100300506032b657004220420", "hex"),
    Buffer.alloc(32, 0x42),
  ]),
  format: "der",
  type: "pkcs8",
});
const signatureDomain = Buffer.from(
  "nuxie.experience-release-descriptor.v2\0",
  "utf8",
);

const upgradeEnvelope = (envelope) => {
  const descriptor = JSON.parse(
    Buffer.from(envelope.descriptorBytesBase64, "base64").toString("utf8"),
  );
  descriptor.schemaVersion = "nuxie.experience-release.v2";
  descriptor.products ??= [];
  descriptor.placements ??= [];
  // Current V2 presentation chrome is runtime-owned. Older committed
  // descriptors carried an authored loading treatment that the current strict
  // grammar intentionally rejects.
  delete descriptor.presentation?.loading;
  const descriptorBytes = Buffer.from(JSON.stringify(descriptor), "utf8");
  const descriptorSha256 = createHash("sha256")
    .update(descriptorBytes)
    .digest("hex");
  const signature = signBytes(
    null,
    Buffer.concat([signatureDomain, descriptorBytes]),
    privateKey,
  );
  return {
    ...envelope,
    mediaType: "application/vnd.nuxie.experience-release+json;version=2",
    descriptorSha256,
    descriptorSizeBytes: descriptorBytes.length,
    descriptorBytesBase64: descriptorBytes.toString("base64"),
    signature: {
      ...envelope.signature,
      signatureBase64: signature.toString("base64"),
    },
  };
};

const upgradeEntry = (entry) => {
  const envelope = JSON.parse(
    Buffer.from(entry.envelopeBytesBase64, "base64").toString("utf8"),
  );
  const upgradedEnvelope = upgradeEnvelope(envelope);
  entry.descriptorSha256 = upgradedEnvelope.descriptorSha256;
  entry.envelopeBytesBase64 = Buffer.from(
    JSON.stringify(upgradedEnvelope),
    "utf8",
  ).toString("base64");
};

for (const relativePath of profilePaths) {
  const path = resolve(relativePath);
  const profile = JSON.parse(await readFile(path, "utf8"));
  for (const collection of [profile.active ?? [], profile.pinned ?? []]) {
    for (const entry of collection) upgradeEntry(entry);
  }
  await writeFile(path, `${JSON.stringify(profile, null, 2)}\n`);
}

for (const relativePath of envelopePaths) {
  const path = resolve(relativePath);
  const envelope = JSON.parse(await readFile(path, "utf8"));
  await writeFile(
    path,
    `${JSON.stringify(upgradeEnvelope(envelope), null, 2)}\n`,
  );
}

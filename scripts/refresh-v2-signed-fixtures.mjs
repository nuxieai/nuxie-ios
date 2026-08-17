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

const upgradeEntry = (entry) => {
  const envelope = JSON.parse(
    Buffer.from(entry.envelopeBytesBase64, "base64").toString("utf8"),
  );
  const descriptor = JSON.parse(
    Buffer.from(envelope.descriptorBytesBase64, "base64").toString("utf8"),
  );
  descriptor.schemaVersion = "nuxie.experience-release.v2";
  descriptor.placements ??= [];
  const descriptorBytes = Buffer.from(JSON.stringify(descriptor), "utf8");
  const descriptorSha256 = createHash("sha256")
    .update(descriptorBytes)
    .digest("hex");
  const signature = signBytes(
    null,
    Buffer.concat([signatureDomain, descriptorBytes]),
    privateKey,
  );
  const upgradedEnvelope = {
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
  entry.descriptorSha256 = descriptorSha256;
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

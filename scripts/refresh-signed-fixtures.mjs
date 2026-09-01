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
const envelopePaths = [
  "fixtures/experience-release-descriptor/envelope.json",
];
const journeyPlanePaths = [
  "fixtures/journeys/planes/release.json",
];
const privateKey = createPrivateKey({
  key: Buffer.concat([
    Buffer.from("302e020100300506032b657004220420", "hex"),
    Buffer.alloc(32, 0x42),
  ]),
  format: "der",
  type: "pkcs8",
});
const experienceSignatureDomain = Buffer.from(
  "nuxie.experience-release-descriptor.v1\0",
  "utf8",
);
const deviceLegSignatureDomain = Buffer.from(
  "nuxie.device-leg-release.v1\0",
  "utf8",
);

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

const canonicalEnvelopeJson = canonicalJson;

const currentReleaseIdentity = (descriptor) => {
  const identity = descriptor.identity;
  if (
    !identity ||
    !("releaseCreatedAt" in identity) ||
    !("releaseSequence" in identity) ||
    "publishedAt" in identity ||
    "publishedAtSeq" in identity
  ) {
    throw new Error(
      "signed fixture must already use the current release identity",
    );
  }
  return identity;
};

const refreshEnvelope = (envelope) => {
  const descriptor = JSON.parse(
    Buffer.from(envelope.descriptorBytesBase64, "base64").toString("utf8"),
  );
  currentReleaseIdentity(descriptor);
  const isDeviceLeg =
    descriptor.schemaVersion === "nuxie.device-leg-release.v1";
  if (!isDeviceLeg) {
    descriptor.schemaVersion = "nuxie.experience-release.v1";
  }
  descriptor.products = (descriptor.products ?? []).map((product) => ({
    ...product,
    preview: product.preview ?? {
      name: product.id,
      description: "",
      price: "",
      period: "",
      periodCount: 0,
      periodLabel: "",
      hasTrial: false,
      trialLabel: "",
      introOfferLabel: "",
      renewalLabel: "",
    },
  }));
  for (const product of descriptor.products) {
    delete product.providerFeatureAccess;
  }
  descriptor.placements ??= [];
  if (descriptor.requirements?.timezoneData) {
    descriptor.requirements.timezoneData.sha256 =
      "d4ad5c12a6be491076f333c9b4f96f60cb8ab552495bbfae0d8cdc9730ecb198";
  }
  // Current presentation chrome is runtime-owned. Older committed
  // descriptors carried an authored loading treatment that the current strict
  // grammar intentionally rejects.
  delete descriptor.presentation?.loading;
  const descriptorBytes = Buffer.from(canonicalJson(descriptor), "utf8");
  const descriptorSha256 = createHash("sha256")
    .update(descriptorBytes)
    .digest("hex");
  const signature = signBytes(
    null,
    Buffer.concat([
      isDeviceLeg ? deviceLegSignatureDomain : experienceSignatureDomain,
      descriptorBytes,
    ]),
    privateKey,
  );
  return {
    ...envelope,
    mediaType: isDeviceLeg
      ? "application/vnd.nuxie.device-leg+json"
      : "application/vnd.nuxie.experience-release+json;version=1",
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
  const refreshedEnvelope = refreshEnvelope(envelope);
  const descriptor = JSON.parse(
    Buffer.from(refreshedEnvelope.descriptorBytesBase64, "base64").toString(
      "utf8",
    ),
  );
  entry.locator = currentReleaseIdentity(descriptor);
  entry.descriptorSha256 = refreshedEnvelope.descriptorSha256;
  entry.envelopeBytesBase64 = Buffer.from(
    canonicalEnvelopeJson(refreshedEnvelope),
    "utf8",
  ).toString("base64");
};

const upgradeJourneyPlaneEntry = (entry) => {
  entry.envelope = refreshEnvelope(entry.envelope);
  const descriptor = JSON.parse(
    Buffer.from(entry.envelope.descriptorBytesBase64, "base64").toString(
      "utf8",
    ),
  );
  entry.locator = {
    ...currentReleaseIdentity(descriptor),
    legId: descriptor.leg.id,
  };
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
  await writeFile(path, canonicalEnvelopeJson(refreshEnvelope(envelope)));
}

for (const relativePath of journeyPlanePaths) {
  const path = resolve(relativePath);
  const profile = JSON.parse(await readFile(path, "utf8"));
  for (const entry of [profile.entry, profile.renderedEntry]) {
    if (entry) upgradeJourneyPlaneEntry(entry);
  }
  await writeFile(path, `${JSON.stringify(profile, null, 2)}\n`);
}

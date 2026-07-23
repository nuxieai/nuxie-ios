#!/usr/bin/env node

import { createHash } from "node:crypto";
import {
  mkdir,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { join, resolve } from "node:path";

const expectedEntryIDs = [
  "animation-event",
  "external-image",
  "ordinary-assets",
  "font-converter",
  "projection",
  "multi-screen",
  "scripted-resources",
  "animation-operations",
];

const sourceRoot = process.argv[2];
const destinationRoot = resolve(
  process.argv[3] ?? "Tests/FlowRuntimeHostApp/GeneratedEditorNextFixtures",
);

if (!sourceRoot) {
  throw new Error(
    "usage: stage-editor-next-native-ui-fixtures.mjs <artifact-root> [destination]",
  );
}

const source = resolve(sourceRoot);
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const decodeJSON = async (path) => JSON.parse(await readFile(path, "utf8"));

const clearDestination = async () => {
  await mkdir(destinationRoot, { recursive: true });
  for (const name of await readdir(destinationRoot)) {
    if (name !== ".gitignore") {
      await rm(join(destinationRoot, name), {
        force: true,
        recursive: true,
      });
    }
  }
};

const stageEnvelope = async ({ id, directory, expectedScreens, signed }) => {
  const envelopePath = join(source, directory, "production-envelope.json");
  const envelopeBytes = await readFile(envelopePath);
  const envelope = JSON.parse(envelopeBytes.toString("utf8"));
  if (
    envelope.schemaVersion !==
    "nuxie-rive-production-artifact-envelope.v1"
  ) {
    throw new Error(`${id}: unsupported envelope schema`);
  }
  if (
    JSON.stringify(envelope.manifest.value.screens) !==
    JSON.stringify(expectedScreens)
  ) {
    throw new Error(`${id}: envelope screens differ from the corpus`);
  }

  const files = envelope.transport.files;
  if (
    envelope.transport.totalFiles !== files.length ||
    envelope.transport.totalSize !==
      files.reduce((total, file) => total + file.sizeBytes, 0)
  ) {
    throw new Error(`${id}: invalid transport totals`);
  }

  const expectedRolePaths = new Set([
    envelope.manifest.path,
    envelope.riv.path,
    ...envelope.manifest.value.assets.images.map((asset) => asset.path),
    ...envelope.manifest.value.assets.fonts.map((asset) => asset.assetUrl),
    ...(signed ? ["nuxie-manifest.sig.json"] : []),
  ]);
  if (
    files.length !== expectedRolePaths.size ||
    files.some((file) => !expectedRolePaths.has(file.path))
  ) {
    throw new Error(`${id}: unsupported or missing transport role`);
  }

  const destination = join(destinationRoot, id);
  await mkdir(destination, { recursive: true });
  for (const file of files) {
    const bytes = Buffer.from(file.bytesBase64, "base64");
    if (bytes.length !== file.sizeBytes || sha256(bytes) !== file.sha256) {
      throw new Error(`${id}: invalid producer role ${file.path}`);
    }

    const bundleBytes = await readFile(
      join(source, directory, "bundle", file.path),
    );
    if (!bytes.equals(bundleBytes)) {
      throw new Error(`${id}: envelope and bundle bytes differ for ${file.path}`);
    }

    const destinationPath = join(destination, file.path);
    await mkdir(resolve(destinationPath, ".."), { recursive: true });
    await writeFile(destinationPath, bytes);
  }

  return envelope;
};

await clearDestination();

const corpusPath = join(source, "native-corpus-manifest.json");
const corpusBytes = await readFile(corpusPath);
const corpus = JSON.parse(corpusBytes.toString("utf8"));
if (
  corpus.schemaVersion !== "nuxie-editor-next-native-corpus.v1" ||
  JSON.stringify(corpus.entries.map((entry) => entry.id)) !==
    JSON.stringify(expectedEntryIDs)
) {
  throw new Error("unsupported exact native corpus");
}
await writeFile(
  join(destinationRoot, "native-corpus-manifest.json"),
  corpusBytes,
);

for (const entry of corpus.entries) {
  await stageEnvelope({
    id: entry.id,
    directory: entry.directory,
    expectedScreens: entry.screens,
    signed: false,
  });
}

const gpuProofPath = join(source, "native-gpu-canvas-proof.json");
const gpuProofBytes = await readFile(gpuProofPath);
const gpuProof = JSON.parse(gpuProofBytes.toString("utf8"));
if (
  gpuProof.schemaVersion !==
    "nuxie-editor-next-native-gpu-canvas-proof.v1"
) {
  throw new Error("unsupported exact GPU canvas proof");
}
const gpuEnvelope = await stageEnvelope({
  id: "gpu-canvas",
  directory: gpuProof.directory,
  expectedScreens: [gpuProof.screen],
  signed: true,
});
const signatureRole = gpuEnvelope.transport.files.find(
  (file) => file.path === "nuxie-manifest.sig.json",
);
const signature = JSON.parse(
  Buffer.from(signatureRole.bytesBase64, "base64").toString("utf8"),
);
if (signature.keyId !== gpuProof.signing.keyId) {
  throw new Error("GPU canvas proof and detached signature key IDs differ");
}
await writeFile(
  join(destinationRoot, "native-gpu-canvas-proof.json"),
  gpuProofBytes,
);

process.stdout.write(
  `Staged ${corpus.entries.length + 1} exact Editor Next fixtures in ${destinationRoot}\n`,
);

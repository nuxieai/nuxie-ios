#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const [artifactRoot, filename, consumer] = process.argv.slice(2);
if (!artifactRoot || !filename || !consumer) {
  throw new Error(
    "usage: write-editor-next-artifact-sentinel.mjs "
      + "<artifact-root> <filename> <consumer>",
  );
}

const root = resolve(artifactRoot);
const run = JSON.parse(
  await readFile(join(root, "artifact-consumption-run.json"), "utf8"),
);
if (
  run.schemaVersion !== "nuxie-editor-next-ios-artifact-run.v1" ||
  run.sentinelSchemaVersion !==
    "nuxie-editor-next-ios-artifact-consumer.v1"
) {
  throw new Error("unsupported Editor Next artifact run manifest");
}
if (
  !run.consumers.some(
    (candidate) =>
      candidate.filename === filename && candidate.consumer === consumer,
  )
) {
  throw new Error(`artifact run does not declare ${filename}/${consumer}`);
}

await writeFile(
  join(root, filename),
  `${JSON.stringify(
    {
      schemaVersion: run.sentinelSchemaVersion,
      runId: run.runId,
      consumer,
    },
    null,
    2,
  )}\n`,
);

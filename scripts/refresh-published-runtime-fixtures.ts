#!/usr/bin/env tsx
import { createHash } from "node:crypto";
import { cpSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { NUXIE_RIVE_MANIFEST_ARTIFACT_PATHS, NuxieRiveManifestV1Schema, type NuxieRiveManifestFontAssetV1, type NuxieRiveManifestV1 } from "@nuxie/models/schemas/nuxie-rive-manifest";
import { PublishIRSchema } from "@nuxie/models/schemas/publish-ir";
import type { ProjectSnapshot } from "@nuxie/core/projectdo/snapshot";
import { riveCompilerBackend } from "@nuxie/view-compiler/compiler-backends/rive";
import type { CompilerBackendArtifactFile } from "@nuxie/view-compiler/compiler-backends/types";

const __filename = fileURLToPath(import.meta.url);
const sdkRoot = path.resolve(path.dirname(__filename), "..");
const repoRoot = path.resolve(sdkRoot, "../..");
const fixtureRoot = path.join(sdkRoot, "Tests/FlowRuntimeHostApp/Fixtures");
const publishFixtureRoot = path.join(repoRoot, "tools/rive-compiler/fixtures/publish-path");
const defaultFontBytes = readFileSync(
  path.join(
    repoRoot,
    "apps/nuxie-dashboard/tests/visual/style-parity/fonts/InterVariable.ttf",
  ),
);
const fixtureBaseURLToken = "__NUXIE_FIXTURE_BASE_URL__";

type PublishPathFixture = {
  flowId: string;
  buildId: string;
  publishIr: unknown;
  snapshotArtifact?: {
    headSeq?: number;
    snapshot: unknown;
  };
};

type FontUpload = {
  key: string;
  body: Buffer;
  contentType?: string;
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

const cloneJson = <T>(value: T): T =>
  JSON.parse(JSON.stringify(value)) as T;

const sha256Hex = (value: Buffer | string): string =>
  createHash("sha256").update(value).digest("hex");

const decodeArtifactFile = (
  artifact: string | CompilerBackendArtifactFile,
): Buffer => {
  if (typeof artifact === "string") {
    return Buffer.from(artifact, "utf8");
  }
  return Buffer.from(artifact.content, artifact.encoding ?? "utf8");
};

const safeFilePart = (value: string): string =>
  value
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 96) || "asset";

const localFontPath = (asset: NuxieRiveManifestFontAssetV1): string =>
  path.posix.join(
    "assets/fonts",
    `${safeFilePart(`${asset.family}-${asset.weight}-${asset.style}`)}.${asset.format}`,
  );

const loadPublishPathFixture = (fixtureId: string): PublishPathFixture => {
  const fixturePath = path.join(publishFixtureRoot, `${fixtureId}.json`);
  const raw = JSON.parse(readFileSync(fixturePath, "utf8")) as PublishPathFixture & {
    schemaVersion?: string;
  };
  if (raw.schemaVersion !== "publish-path-fixture.v1") {
    throw new Error(`Invalid publish fixture schema for ${fixtureId}`);
  }
  return raw;
};

const polishedTextInputFixture = (source: PublishPathFixture): PublishPathFixture => {
  const fixture = cloneJson(source);
  const snapshot = fixture.snapshotArtifact?.snapshot;
  const nodes =
    isRecord(snapshot) &&
    isRecord(snapshot.document) &&
    Array.isArray(snapshot.document.nodes)
      ? snapshot.document.nodes
      : null;
  if (!nodes) {
    throw new Error("Text input fixture source is missing document nodes");
  }

  const emailInput = nodes.find((node) => isRecord(node) && node.id === "email_input");
  if (!isRecord(emailInput)) {
    throw new Error("Text input fixture source is missing email_input node");
  }
  const data = isRecord(emailInput.data) ? emailInput.data : null;
  const view = isRecord(data?.view) ? data.view : null;
  const props = isRecord(view?.props) ? view.props : null;
  const style = isRecord(props?.style) ? props.style : null;
  if (!style) {
    throw new Error("Text input fixture source is missing email_input style");
  }

  style.paddingLeft = 16;
  style.paddingRight = 16;
  return fixture;
};

const textInputMotionFixture = (source: PublishPathFixture): PublishPathFixture => {
  const fixture = cloneJson(source);
  fixture.flowId = "flow_text_input_motion";
  fixture.buildId = "build_text_input_motion";

  if (isRecord(fixture.publishIr)) {
    fixture.publishIr.id = fixture.flowId;
    if (Array.isArray(fixture.publishIr.targets)) {
      for (const target of fixture.publishIr.targets) {
        if (isRecord(target)) {
          target.buildId = fixture.buildId;
        }
      }
    }
    if (isRecord(fixture.publishIr.flowArtifact)) {
      fixture.publishIr.flowArtifact.buildId = fixture.buildId;
    }
  }

  const snapshot = fixture.snapshotArtifact?.snapshot;
  const nodes =
    isRecord(snapshot) &&
    isRecord(snapshot.document) &&
    Array.isArray(snapshot.document.nodes)
      ? snapshot.document.nodes
      : null;
  if (!nodes) {
    throw new Error("Text input motion fixture source is missing document nodes");
  }

  nodes.push(
    {
      id: "animation.text_input_motion",
      projectId: "project_1",
      parentId: "screen_1::animation_tree",
      orderKey: "a",
      kind: "linear_animation",
      type: "linear_animation",
      data: {
        kind: "linear_animation",
        name: "Text Input Motion",
        fps: 60,
        duration: 120,
        speed: 1,
        loopValue: 1,
        keyedObjects: [
          {
            id: "keyed.email_input.field.x",
            objectKey: "view_shape/email_input",
            keyedProperties: [
              {
                id: "keyed.email_input.field.x.property",
                propertyKey: 13,
                valueType: "number",
                mixBehavior: "interpolate",
                keyFrames: [
                  {
                    id: "keyframe.email_input.field.x.0",
                    frame: 0,
                    valueType: "number",
                    value: 195,
                    interpolation: { type: "linear" },
                  },
                  {
                    id: "keyframe.email_input.field.x.120",
                    frame: 120,
                    valueType: "number",
                    value: 259,
                    interpolation: { type: "linear" },
                  },
                ],
              },
            ],
          },
          {
            id: "keyed.email_input.text.x",
            objectKey: "artboard/screen_1/email_input/text",
            keyedProperties: [
              {
                id: "keyed.email_input.text.x.property",
                propertyKey: 13,
                valueType: "number",
                mixBehavior: "interpolate",
                keyFrames: [
                  {
                    id: "keyframe.email_input.text.x.0",
                    frame: 0,
                    valueType: "number",
                    value: 48,
                    interpolation: { type: "linear" },
                  },
                  {
                    id: "keyframe.email_input.text.x.120",
                    frame: 120,
                    valueType: "number",
                    value: 112,
                    interpolation: { type: "linear" },
                  },
                ],
              },
            ],
          },
        ],
      },
    },
  );

  return fixture;
};

const copyRuntimeArtifacts = (params: {
  sourceFixtureId: string;
  destinationFixtureId: string;
}): void => {
  const sourceRoot = path.join(fixtureRoot, params.sourceFixtureId);
  const destinationRoot = path.join(fixtureRoot, params.destinationFixtureId);
  mkdirSync(destinationRoot, { recursive: true });

  for (const fileName of ["flow.riv", NUXIE_RIVE_MANIFEST_ARTIFACT_PATHS.manifest]) {
    cpSync(path.join(sourceRoot, fileName), path.join(destinationRoot, fileName));
  }

  rmSync(path.join(destinationRoot, "assets"), { recursive: true, force: true });
  cpSync(path.join(sourceRoot, "assets"), path.join(destinationRoot, "assets"), {
    recursive: true,
  });
  console.log(
    `copied static runtime artifacts ${params.sourceFixtureId} -> ${params.destinationFixtureId}`,
  );
};

const canonicalPublishIrInput = (source: PublishPathFixture): unknown => {
  if (!isRecord(source.publishIr)) return source.publishIr;
  if (isRecord(source.publishIr.flowArtifact)) return source.publishIr;
  const bundle = isRecord(source.publishIr.bundle) ? source.publishIr.bundle : {};
  return {
    ...source.publishIr,
    flowArtifact: {
      url: typeof bundle.url === "string" ? bundle.url : "/preview/fixture",
      buildId: source.buildId,
      manifest: isRecord(bundle.manifest)
        ? bundle.manifest
        : {
            manifestVersion: 1,
            totalFiles: 0,
            totalSize: 0,
            contentHash: "pending",
            files: [],
          },
      status: "queued",
    },
  };
};

const rewriteFontAssets = (
  manifest: NuxieRiveManifestV1,
  fontUploads: FontUpload[],
  destinationRoot: string,
): NuxieRiveManifestV1 => ({
  ...manifest,
  assets: {
    ...manifest.assets,
    fonts: manifest.assets.fonts.map((fontAsset) => {
      const upload = fontUploads.find(
        (candidate) => sha256Hex(candidate.body) === fontAsset.sha256,
      );
      const body = upload?.body ?? defaultFontBytes;
      const localPath = localFontPath(fontAsset);
      const absolutePath = path.join(destinationRoot, localPath);
      mkdirSync(path.dirname(absolutePath), { recursive: true });
      writeFileSync(absolutePath, body);
      return {
        ...fontAsset,
        assetUrl: `${fixtureBaseURLToken}/${localPath}`,
      };
    }),
  },
});

const refreshFixture = async (params: {
  source: PublishPathFixture;
  sourceName: string;
  destinationFixtureId: string;
}): Promise<void> => {
  const source = params.source;
  const fontUploads: FontUpload[] = [];
  const compileResult = await riveCompilerBackend.compile({
    flowId: source.flowId,
    buildId: source.buildId,
    publishIr: PublishIRSchema.parse(canonicalPublishIrInput(source)),
    deps: {
      fontAssetStorage: {
        publicUrlBase: "https://cdn.test",
        objectExists: async () => false,
        putObject: async (key, body, options) => {
          fontUploads.push({
            key,
            body: Buffer.from(body),
            contentType: options?.contentType,
          });
        },
      },
      resolveRiveNativeFontAsset: async () => ({
        bytes: defaultFontBytes,
        contentType: "font/ttf",
        format: "ttf",
      }),
    },
    ...(source.snapshotArtifact
      ? {
          sourceArtifacts: {
            snapshot: {
              headSeq: source.snapshotArtifact.headSeq ?? 0,
              snapshot: source.snapshotArtifact.snapshot as ProjectSnapshot,
            },
          },
        }
      : {}),
  });

  const blockingDiagnostics = (compileResult.diagnostics ?? []).filter(
    (diagnostic) => diagnostic.isBlocking || diagnostic.severity === "error",
  );
  if (blockingDiagnostics.length > 0) {
    throw new Error(
      `Publish fixture ${params.sourceName} produced blocking diagnostics: ${JSON.stringify(blockingDiagnostics, null, 2)}`,
    );
  }
  if (compileResult.delivery.kind !== "artifact-files") {
    throw new Error(`Publish fixture ${params.sourceName} did not emit artifact files`);
  }

  const destinationRoot = path.join(fixtureRoot, params.destinationFixtureId);
  rmSync(destinationRoot, { recursive: true, force: true });
  mkdirSync(destinationRoot, { recursive: true });

  const manifestArtifact =
    compileResult.delivery.files[NUXIE_RIVE_MANIFEST_ARTIFACT_PATHS.manifest];
  if (typeof manifestArtifact !== "string") {
    throw new Error(`Publish fixture ${params.sourceName} did not emit a manifest`);
  }
  let manifest = NuxieRiveManifestV1Schema.parse(JSON.parse(manifestArtifact));

  const rivArtifact = compileResult.delivery.files[manifest.riv.path];
  if (!rivArtifact) {
    throw new Error(`Publish fixture ${params.sourceName} did not emit ${manifest.riv.path}`);
  }
  const rivBytes = decodeArtifactFile(rivArtifact);
  writeFileSync(path.join(destinationRoot, manifest.riv.path), rivBytes);

  for (const imageAsset of manifest.assets.images) {
    const imageArtifact = compileResult.delivery.files[imageAsset.path];
    if (!imageArtifact) {
      throw new Error(`Publish fixture ${params.sourceName} did not emit ${imageAsset.path}`);
    }
    const imagePath = path.join(destinationRoot, imageAsset.path);
    mkdirSync(path.dirname(imagePath), { recursive: true });
    writeFileSync(imagePath, decodeArtifactFile(imageArtifact));
  }

  manifest = rewriteFontAssets(manifest, fontUploads, destinationRoot);
  writeFileSync(
    path.join(destinationRoot, NUXIE_RIVE_MANIFEST_ARTIFACT_PATHS.manifest),
    `${JSON.stringify(manifest, null, 2)}\n`,
  );

  console.log(
    `refreshed ${params.destinationFixtureId}: riv=${manifest.riv.sizeBytes} bytes sha=${manifest.riv.sha256}`,
  );
};

// The safe-area fixture's flow descriptions are owned by this script (its
// fixture directory is fully regenerated): a default single-screen run plus a
// modal variant that presents screen_2 as a native sheet so the simulator
// matrix can prove the sheet reads its own view's insets.
const writeSafeAreaFlowDescriptions = (destinationFixtureId: string): void => {
  const destinationRoot = path.join(fixtureRoot, destinationFixtureId);
  const screens = [
    { id: "screen_1", defaultViewModelId: null, defaultInstanceId: null },
    { id: "screen_2", defaultViewModelId: null, defaultInstanceId: null },
  ];
  writeFileSync(
    path.join(destinationRoot, "flow-description.json"),
    `${JSON.stringify({ screens, events: {}, handlers: {} }, null, 2)}\n`,
  );
  writeFileSync(
    path.join(destinationRoot, "flow-description.modal.json"),
    `${JSON.stringify(
      {
        screens,
        events: {},
        handlers: {
          __journey__: [
            {
              id: "interaction_auto_modal",
              eventName: "__nuxie_test_run_transition",
              enabled: true,
              actions: [
                {
                  type: "navigate",
                  screenId: "screen_2",
                  transition: { type: "modal" },
                },
              ],
            },
          ],
        },
      },
      null,
      2,
    )}\n`,
  );
};

const main = async (): Promise<void> => {
  // Optional fixture-id args narrow the refresh (fixtures are regenerated
  // with whatever rive-compiler wasm the monorepo checkout has built, so a
  // narrow refresh avoids byte-churning unrelated fixtures).
  const only = new Set(process.argv.slice(2));
  const enabled = (fixtureId: string): boolean =>
    only.size === 0 || only.has(fixtureId);

  if (enabled("published-font") || enabled("text-input-motion") || enabled("screen-transition-push")) {
    const visualViewContract = polishedTextInputFixture(
      loadPublishPathFixture("visual-view-contract"),
    );
    if (enabled("published-font") || enabled("screen-transition-push")) {
      await refreshFixture({
        source: visualViewContract,
        sourceName: "visual-view-contract",
        destinationFixtureId: "published-font",
      });
    }
    if (enabled("text-input-motion")) {
      await refreshFixture({
        source: textInputMotionFixture(visualViewContract),
        sourceName: "text-input-motion",
        destinationFixtureId: "text-input-motion",
      });
    }
    if (enabled("screen-transition-push")) {
      copyRuntimeArtifacts({
        sourceFixtureId: "published-font",
        destinationFixtureId: "screen-transition-push",
      });
    }
  }

  if (enabled("safe-area-env")) {
    await refreshFixture({
      source: loadPublishPathFixture("safe-area-env-device-proof"),
      sourceName: "safe-area-env-device-proof",
      destinationFixtureId: "safe-area-env",
    });
    writeSafeAreaFlowDescriptions("safe-area-env");
  }
};

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

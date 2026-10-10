# Native Bazel builds

The SDK has direct Swift, Apple framework, application, and XCTest targets.
Select Xcode with `xcode-select`; `.bazelversion` pins Bazel. The frontend installs checksum-pinned Bazelisk automatically in a user-owned tool cache when no explicit launcher is configured.
`MODULE.bazel` pins the Swift/Apple rules, and the authored `Package.resolved`
continues to pin Quick, Nimble, and their transitive test dependencies.

## Worktree caches

Bazel shares action products, dependency downloads, and fetched repositories
with `nuxie-runtime` and the other Nuxie SDKs under `~/.cache/nuxie/bazel`.
Each checkout has its own output base, `bazel-*` links, and prepared SDK outputs.
Matching compile actions reuse the shared cache across worktrees.

Set an absolute `NUXIE_BAZEL_CACHE_DIR` when using `scripts/bazel/sdk.sh` to
relocate only the reusable caches. `NUXIE_IOS_BAZEL_OUTPUT_BASE`, when explicitly
set, must be unique to the checkout. The default already provides isolation.
CI uses batch mode and accepts an absolute `NUXIE_BAZEL_OUTPUT_USER_ROOT` for guarded per-agent output storage. The shared action/repository caches still follow `NUXIE_BAZEL_CACHE_DIR`, and every checkout retains a distinct output base. Set `NUXIE_BAZEL_JOBS` to bound compilation.
Run `python3 -B -m unittest discover -s scripts/bazel -p 'test_cache.py'` for the
cache override checks.

## SDK targets

The public `//:Nuxie` and `//:NuxieRuntime` targets export static Swift and native
link providers. A wrapper can depend on `//:Nuxie` when linking its existing
bridge framework. Resources propagate as `Nuxie_Nuxie.bundle`. This preserves
wrappers that package their own dynamic bridge without introducing another SDK
framework to embed.

```sh
scripts/bazel/sdk.sh build --platform ios-simulator
scripts/bazel/sdk.sh build --platform ios-device --configuration Release
scripts/bazel/sdk.sh test --suite unit
scripts/bazel/sdk.sh test --suite native-runtime
scripts/bazel/sdk.sh test --suite hosted-input
scripts/bazel/sdk.sh test --suite integration
scripts/bazel/sdk.sh test --suite macos-unit
```

`test` defaults to iOS unit, hosted input, integration, and macOS unit. The
focused native-runtime selector retains all three existing runtime classes.
StoreKit, video, runtime/reference UI, and E2E suites are separate selectors.
Use `--test-filter Module/Class[/method]` for a targeted run and
`--simulator-device` / `--simulator-os` to select an installed simulator. The
StoreKit suite requires native StoreKitTest availability; unavailable execution
cannot count as qualification.

Debug uses Swift's debug configuration; Release uses its optimized
configuration. Both retain Swift 5 language mode, the supported iOS 15/macOS 12
deployment targets, and the SDK/runtime strict concurrency checks. XcodeGen's
unit/hosted exclusions, compilation conditions, fixture folders, app identities,
and app versions are retained by the corresponding targets. Source conformance
tests retain the existing checkout-based `#filePath` contract through a declared,
test-only source copy with `#sourceLocation`. Authored tests stay unchanged and
their inspected source and fixture files are declared test inputs. Production
compiler paths retain the shared-cache mapping provided by `rules_swift`.
The SDK and test-support modules retain XcodeGen's explicit testability in both
configurations; runtime adapters, applications, and tests use ordinary Debug
testability and omit it in Release. The published SwiftPM manifest is unchanged.

`make test`, its focused suite targets, `make build-ios-device`, `make build-macos`, and `make build-reference-app` use the native Bazel graph. `make bazel-contract-test` checks frontend, cache, metadata, and publication contracts without compiling Swift. Frameworks and applications are published under checkout-local `.bazel-artifacts/build/<platform>/<configuration>/` after their native/privacy audits pass. XcodeGen remains available for IDE projects; the explicit concurrency-warning and coverage diagnostics retain their existing Xcode/SwiftPM machinery.

Framework publication also retains the configured `NuxieRuntime` Swift module
and C ABI headers so `make check-public-api` imports the same compiled SDK.
The provider adapter consumer smoke still verifies the published SwiftPM package
with third-party provider dependencies. Physical-device video qualification
uses the explicit `make test-video-device TEST_DESTINATION='platform=iOS,id=…'`
Xcode runner; the regular video simulator suite uses Bazel.

## Consumer artifacts

```sh
scripts/bazel/sdk.sh prepare \
  --output /absolute/output/sdk \
  --configuration Release \
  --platform ios-device \
  --platform ios-simulator
```

Each requested platform includes its supported architectures, `Nuxie.framework`,
the standalone `Nuxie_Nuxie.bundle`, static SDK/runtime libraries, Swift import
modules and headers, and the immutable runtime XCFramework. macOS remains
available for the SDK's existing non-rendering surface; iOS wrappers need only
device and simulator products. With no `--platform`, preparation retains all
three SDK platforms. A focused development/import check can select `--architecture arm64`; default preparation retains every supported architecture.

The output root contains `sdk-artifacts.json` with schema version 1, SDK source
revision, dirty state, and source content digest, the exact runtime release URL/checksum/source revision,
platform/configuration products, native C module/header/archive descriptors,
licenses, file SHA-256/size inventory, and framework symlinks. Products select
the exact configured Swift modules linked into their owning framework.
Preparation replaces only an output directory owned by a previous SDK manifest;
it rejects unrelated files. Distribution preparation uses the pinned released
runtime. Local builds/tests retain the explicit `NUXIE_RUNTIME_USE_LOCAL=1`
staged-runtime opt-in.

Distribution preparation requires committed SDK source and checks that its
content identity stays unchanged throughout compilation. For an explicit local
development product, `prepare --allow-dirty` records the dirty state and the
digest of tracked and untracked source inputs. Source-addressed consumers reject
these development manifests; the import check accepts them only with its own
explicit `--allow-dirty` option.

Check the staged consumer interface without building SDK source:

```sh
scripts/bazel/check-consumer.py /absolute/output/sdk/sdk-artifacts.json \
  --platform ios-simulator --configuration Release --architecture arm64
```

The check imports `Nuxie`, `NuxieRuntime`, and `NuxieRuntimeC` in both framework
and static-module modes and checks the owning Swift header and required bundle
resources. Existing privacy/native-symbol/customer-framework audits remain the
distribution authority.

## Retained target names

All twenty XcodeGen target names have a Bazel counterpart. Configure iOS targets
with `--config=ios-simulator` or `--config=ios-device`, and macOS targets with
`--config=macos`. `//:sdk_ios_device` and `//:sdk_ios_simulator` additionally expose
platform-bound framework artifacts.

| Targets | Native Bazel role |
| --- | --- |
| `NuxieRuntime`, `NuxieRuntimeMac` | Swift runtime adapter and Mac alias |
| `NuxieSDK`, `NuxieSDKMac` | SDK dynamic frameworks, including Swift import modules |
| `NuxieTestSupportiOS`, `NuxieTestSupportMac` | Shared test-support module aliases |
| `NuxieSDKUnitTests`, `NuxieSDKMacUnitTests`, `NuxieSDKIntegrationTests` | Unhosted XCTest bundles |
| `NuxieVideoDeviceTests`, `NuxieExperienceInputTests` | Hosted runtime/input XCTest bundles |
| `NuxieStoreKitTestHost`, `NuxieSDKStoreKitTests` | iOS 17 StoreKit host and qualification bundle |
| `NuxieExperienceRuntimeHostApp`, `NuxieExperienceRuntimeReferenceApp` | Runtime host and reference applications |
| `NuxieE2EApp`, `NuxieE2EAppTests`, `NuxieE2EAppUITests` | E2E application and test bundles |
| `NuxieExperienceRuntimeUITests`, `NuxieExperienceRuntimeReferenceUITests` | Runtime/reference UI qualification bundles |

Work is tracked by [UNIV-4176](https://universe.basis.dev/issue/UNIV-4176).

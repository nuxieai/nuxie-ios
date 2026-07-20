# CLAUDE.md - Nuxie iOS SDK

Guidance for Claude Code when working on the Nuxie iOS SDK.

> An SDK-wide cleanup is in progress on the `sdk-cleanup` branch. Before
> structural work, read `plans/nuxie-ios-sdk-cleanup-plan.md` and
> `plans/nuxie-ios-sdk-review.md` in the parent repo (nuxie-dev) — they define
> the target architecture and the phase sequence. Several subsystems described
> below are scheduled to change shape.

## What this SDK does

Connects iOS/macOS apps to Nuxie: tracks events (SQLite-backed local history +
batched network delivery), identifies users, evaluates segments/goals/journey
conditions client-side via a compiled IR, executes server-configured campaign
journeys, and renders Nuxie Runtime-backed flows (paywalls, onboarding, surveys)
delivered as downloadable artifacts.

## Project structure (actual)

```
Sources/Nuxie/
├── NuxieSDK.swift          # Public facade (singleton)
├── NuxieConfiguration.swift
├── DI/NuxieContainer.swift # FactoryKit Container extensions, .sdk scope
├── Core/                   # NuxieLifecycleCoordinator (app lifecycle fan-out)
├── Identity/               # IdentityService (anon id, identify, reset)
├── Session/                # SessionService (30-min idle / 24h rotation)
├── Events/                 # EventLog actor (capture → enrich → persist →
│                           #   durable batched delivery → query, committed-
│                           #   events subscriptions), SQLiteEventStore,
│                           #   TriggerService/TriggerBroker (gating),
│                           #   NuxieContextBuilder, EventSanitizer
├── Profile/                # ProfileService (/profile fetch + cache + apply)
├── Segments/               # SegmentService (IR-evaluated membership)
├── Journey/                # JourneyService (orchestration), GoalEvaluator,
│   ├── Execution/          #   FlowJourneyRunner (action sequencing)
│   ├── Models/             #   Journey, JourneyStatus, GoalModels
│   ├── Events/             #   $journey_* event builders
│   └── Storage/            #   JourneyStore (file persistence)
├── IR/                     # IRInterpreter/IRValue/IRModels + Runtime adapters
├── Flows/                  # RemoteFlow (wire model + JourneyAction schema),
│                           #   FlowService/FlowStore/FlowArtifactStore/
│                           #   RuntimeAssetStore, FlowViewController + bridges,
│                           #   FlowPresentationService (window presentation)
├── StoreKit/               # Product/Transaction services, TransactionObserver
├── Features/               # FeatureService (entitlement checks) + FeatureInfo
├── Network/                # NuxieApi + request/response models
└── Util/                   # NuxieLogger (os_log), DateProvider, UUID.v7

Tests/
├── NuxieUnitTests/         # Quick/Nimble AsyncSpec + XCTest
├── NuxieIntegrationTests/  # incl. Orchestration/ (real services, mock transport)
├── NuxieTestSupport/       # shared mocks (MockFactory, Mock* services)
├── NuxieE2ETests/          # E2E app tests
└── FlowRuntimeHostApp/     # host app for flow runtime UI tests

fixtures/                   # language-neutral conformance vectors — the
                            # cross-SDK contract (see fixtures/README.md)
```

## Commands

- `make test` — unit tests on iOS simulator (default)
- `make test-integration` — integration tests
- `make test-all` — unit + integration
- `make generate` — regenerate NuxieSDK.xcodeproj via XcodeGen (after
  project.yml changes or file adds/removals)
- Targeted run: `make test-unit XCODEBUILD_TEST_FLAGS='-only-testing:NuxieSDKUnitTests/<ClassName>'`
  (integration: `-only-testing:NuxieSDKIntegrationTests/<ClassName>`)
- `make coverage` / `make coverage-html` — coverage via SPM

### Apple runtime artifact

iOS builds link the Rust runtime from the ignored
`.artifacts/NuxieRuntime.xcframework` path. Stage and validate a locally built
artifact with:

```sh
make stage-runtime-xcframework \
  NUXIE_RUNTIME_XCFRAMEWORK=/absolute/path/to/NuxieRuntime.xcframework
```

`make check-staged-runtime-xcframework` repeats validation without copying.
After assembling the SDK, `make verify-customer-framework` requires the Rust
ABI symbols and exact privacy manifest and rejects packaged or linked Rive
artifacts. For a clean SwiftPM checkout, `Package.swift` instead resolves the
exact-checksum `apple-runtime-v0.1.0` release; `make fetch-runtime-xcframework`
uses the same release bytes for CI and clean-room qualification.

**Never run `swift build`** — the SDK is iOS-first and plain `swift build`
compiles for macOS.

## Key invariants

- **Conformance fixtures are the contract.** Semantics of the event pipeline
  (and, as later phases land, journeys/IR/experiments) are pinned by JSON
  vectors in `fixtures/`, shared with the Android SDK. A semantic change
  without a fixture change is a review red flag.
- **Strict concurrency is on as warnings** (`SWIFT_STRICT_CONCURRENCY:
  complete` in project.yml, `StrictConcurrency` experimental feature in
  Package.swift). Do not add new warnings; the baseline (381 unique, recorded
  July 2026 in the cleanup plan) only ratchets down. Swift 6 errors arrive in
  cleanup Phase 10.
- **`$`-prefixed events are internal** ($identify, $app_opened, $journey_*,
  $flow_*, $purchase_*). User events never start with `$`.
- **Batch delivery idempotency**: wire batch items carry the event's UUIDv7 id
  as `idempotency_key` (see fixtures/events/batch-item-encoding.json).
- **Committed-events ordering**: `EventLog` announces an event to subscribers
  only after it is persisted pending delivery, in capture order; subscribers
  registered before `configure` (the journey router) observe every committed
  event. Downstream consumers subscribe — they are never injected into the
  event pipeline.
- **$flow_shown is tracked by FlowPresentationService only**, on successful
  presentation. Never add a second tracking site.
- **TransactionService owns global $purchase_failed**; FlowViewController's
  typed catch must not re-emit it.
- **The Apple runtime is exact-byte pinned.** Do not weaken the immutable
  release URL/checksum, reintroduce `rive-ios`, or allow a local ignored
  artifact to stand in for clean-room distribution qualification.

## DI

Services are FactoryKit factories on `Container.shared` with a custom `.sdk`
scope (`DI/NuxieContainer.swift`); resolution via `@Injected(\.foo)`. Tests
override by re-registering (`Container.shared.foo.register { mock }`) and the
harness resets with `Container.shared.manager.reset(scope: .sdk)`.
(Cleanup Phase 4 replaces this with a constructor-injected composition root —
don't build new machinery on Container.shared.)

## Testing conventions

- Quick 7 / Nimble 13; async specs subclass `AsyncSpec`; plain XCTest is fine
  for table-driven tests (see ConformanceVectorTests).
- Unit tests mock heavily via `NuxieTestSupport`; the Orchestration suite in
  integration tests intentionally uses REAL services + stores over temp
  directories with only the HTTP transport mocked — extend it when touching
  delivery/persistence behavior.
- Each test that touches disk uses a unique temp path; clean up in afterEach.

## Style

- Swift API Design Guidelines; public APIs get doc comments.
- Log via `LogDebug/LogInfo/LogWarning/LogError` (os_log-backed NuxieLogger) —
  never `print`.
- Conventional Commits; commits authored as Levi McCallum
  <levi@levimccallum.com>; no AI co-author trailers.

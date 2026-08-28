# CLAUDE.md - Nuxie iOS SDK

Guidance for Claude Code when working on the Nuxie iOS SDK.

`docs/sdk-api-surface.md` documents the supported public surface. Treat that
document and the conformance fixtures as repository-local contracts.

## What this SDK does

Connects iOS/macOS apps to Nuxie: tracks events (SQLite-backed local history +
batched network delivery), identifies users, evaluates segments/goals/journey
conditions client-side via a compiled IR, executes server-configured experience
journeys, and renders Nuxie Runtime-backed experiences (paywalls, onboarding,
surveys). Releases authenticate and admit an inline signed descriptor, then
acquire its standalone content-addressed RIV, assets, and scripts.

## Project structure (actual)

```
Sources/Nuxie/
├── NuxieSDK.swift          # Public facade (singleton)
├── NuxieConfiguration.swift
├── Core/                   # NuxieLifecycleCoordinator (app lifecycle fan-out)
├── Identity/               # IdentityService (anon id, identify, reset)
├── Events/                 # EventLog actor (capture → enrich → persist →
│                           #   durable batched delivery → query, committed-
│                           #   events subscriptions), SQLiteEventStore,
│                           #   TriggerService/TriggerBroker (journey routing),
│                           #   NuxieContextBuilder, EventSanitizer
├── Profile/                # ProfileService (/profile fetch + cache + apply)
├── Segments/               # SegmentService (IR-evaluated membership)
├── Journey/                # JourneyService (orchestration), GoalEvaluator,
│   ├── Execution/          #   JourneyRunner (action sequencing)
│   ├── Models/             #   Journey, JourneyStatus, GoalModels
│   ├── Events/             #   $journey_* event builders
│   └── Storage/            #   JourneyStore (file persistence)
├── IR/                     # IRInterpreter/IRValue/IRModels + Runtime adapters
├── Experiences/            # Inline descriptor authentication/admission,
│                           #   standalone RIV/assets/scripts acquisition,
│                           #   shared content-addressed artifact caches and
│                           #   immutable prepared-RIV/session reuse,
│                           #   ExperienceService/Store/ViewController,
│                           #   Swift-owned interactive screen + presentation loop,
│                           #   ExperiencePresentationService
├── StoreKit/               # Product/Transaction services, TransactionObserver
├── Features/               # FeatureService (entitlement checks) + FeatureInfo
├── Network/                # NuxieApi + request/response models
└── Util/                   # NuxieLogger (os_log), DateProvider, UUID.v7

Sources/NuxieRuntime/       # Swift Apple runtime adapter over NuxieRuntimeC

Tests/
├── NuxieUnitTests/         # Quick/Nimble AsyncSpec + XCTest
├── NuxieIntegrationTests/  # incl. Orchestration/ (real services, mock transport)
├── NuxieTestSupport/       # shared mocks (MockFactory, Mock* services)
└── ExperienceRuntimeHostApp/     # neutral descriptor-release runtime UI host

fixtures/                   # language-neutral conformance vectors — the
                            # cross-SDK contract (see fixtures/README.md)
Runtime/artifact.json       # immutable XCFramework release URL + checksum
```

## Commands

- `make test` — the holistic gate: iOS unit + focused native-runtime +
  integration + macOS unit
  (same as `make test-all`)
- `make test-unit` / `make test-integration` / `make test-macos-unit` — one scheme
- `make generate` — regenerate NuxieSDK.xcodeproj via XcodeGen (after
  project.yml changes or file adds/removals)
- Targeted run: `make test-unit XCODEBUILD_TEST_FLAGS='-only-testing:NuxieSDKUnitTests/<ClassName>'`
  (integration: `-only-testing:NuxieSDKIntegrationTests/<ClassName>`)
- `make coverage` / `make coverage-html` — coverage via SPM
- `make check-concurrency-warnings` — strict-concurrency warning ratchet:
  clean-builds the iOS framework and fails if unique strict-concurrency
  warnings exceed the committed baseline (0)

### Apple runtime artifact

iOS builds the SDK against the pure-Swift `NuxieRuntime` target. Its native
ownership file is the sole importer of the low-level `NuxieRuntimeC` module.
Download and verify the
immutable runtime release pinned in `Runtime/artifact.json` with:

```sh
make fetch-runtime-xcframework
```

To test an unpublished runtime build without changing the release pin, use:

```sh
make stage-runtime-xcframework \
  NUXIE_RUNTIME_XCFRAMEWORK=/absolute/path/to/NuxieRuntime.xcframework
```

`make check-staged-runtime-xcframework` repeats validation without copying.
After assembling the SDK, `make verify-customer-framework` requires the runtime
ABI symbols and exact privacy manifest and rejects packaged or linked Rive
artifacts. `nuxie-runtime` owns the Apple ABI and XCFramework production;
`nuxie-ios` owns only the Swift adapter and consumer-side qualification. Direct
FFI imports belong only inside `Sources/NuxieRuntime`.

**Never run `swift build`** — the SDK is iOS-first and plain `swift build`
compiles for macOS.

## Key invariants

- **Conformance fixtures are the contract.** Semantics of the event pipeline
  (and, as later phases land, journeys/IR/experiments) are pinned by JSON
  vectors in `fixtures/`, shared with the Android SDK. A semantic change
  without a fixture change is a review red flag.
- **Strict concurrency is on as warnings** (`SWIFT_STRICT_CONCURRENCY:
  complete` in project.yml, `StrictConcurrency` experimental feature in
  Package.swift), and the warning count is ZERO. The SDK stays in Swift 5
  language mode but is Swift 6 compatible: the public API is
  Sendable-correct (pinned by
  `Tests/NuxieUnitTests/PublicAPISendabilityCompileChecks.swift`), and
  `make check-concurrency-warnings` fails if any strict-concurrency warning
  reappears. Ratchet down, never up — fix new warnings instead of raising
  the baseline.
- **`$`-prefixed events are internal** ($identify, $app_opened, $journey_*,
  $experience_*, $purchase_*). User events never start with `$`. The canonical
  machine contract is `fixtures/events/catalog.json`; its derived human view is
  `docs/events-catalog.md`, while `docs/sdk-events.md` contains supplementary
  behavioral guidance. Emit only through the constants in
  `JourneyEvents`/`SystemEventNames` — never bare `$...` string literals.
- **Batch delivery idempotency**: wire batch items carry the event's UUIDv7 id
  as `idempotency_key` (see fixtures/events/batch-item-encoding.json).
- **Committed-events ordering**: `EventLog` announces an event to subscribers
  only after it is persisted pending delivery, in capture order; subscribers
  registered before `configure` (the journey router) observe every committed
  event. Downstream consumers subscribe — they are never injected into the
  event pipeline.
- **Device event history is retained-window-only.** `EventLog` must never claim
  complete lifetime coverage. Unbounded IR event queries that require exact
  history preserve unknown through the interpreter and fail closed at
  `IRRuntime`, including under boolean negation and nested predicates. A
  lower-bounded query is deterministic only when its entire window is inside
  the durable monotonic horizon. Retention deletion and horizon advancement
  are one transaction; failed history writes fence the gap, and corrupt event
  properties, truncation, and storage errors are unknown.
  The full contract and current v1 schema guidance are in
  `docs/event-history-semantics.md`.
- **$experience_shown is tracked by ExperiencePresentationService only**, on successful
  presentation. Never add a second tracking site.
- **TransactionService owns global $purchase_failed**; ExperienceViewController's
  typed catch must not re-emit it.
- **The Apple runtime is an immutable external artifact.** `Package.swift` and
  `Runtime/artifact.json` pin one versioned release URL and checksum. Do not add
  Cargo, Rust source, a runtime submodule, a committed XCFramework, `rive-ios`,
  or let a local override stand in for clean-room release qualification.

## Dependency construction

`NuxieCore` is the constructor-injected composition root. It creates concrete
services in dependency order and passes role-specific protocols to consumers.
Tests construct the same graph with explicit fakes or use `MockFactory` for
shared test fixtures; do not add a service locator or hidden global resolution.

## Testing conventions

- Quick 7 / Nimble 13; async specs subclass `AsyncSpec`; plain XCTest is fine
  for table-driven tests (see ConformanceVectorTests).
- Unit tests mock heavily via `NuxieTestSupport`; the Orchestration suite in
  integration tests intentionally uses REAL services + stores over temp
  directories with only the HTTP transport mocked — extend it when touching
  delivery/persistence behavior.
- Each test that touches disk uses a unique temp path; clean up in afterEach.
- Signed runtime package fixtures are SDK-owned and enumerated by
  `Tests/ExperienceRuntimeHostApp/Fixtures/fixture-index.json`. Regeneration
  lives in the parent repository's iOS E2E harness; qualification packages and
  pixel proofs are not copied into this public SDK.
- Presentation-shell review uses a separate corpus,
  `Tests/ExperienceRuntimeHostApp/PresentationStates/`, whose fixtures differ
  only in their signed `presentation` block. Keep presentation-mode and
  background scenarios there so the cross-SDK renderer contract in
  `Fixtures/` stays about renderer semantics. Both are regenerated from the
  parent repo (`tests/e2e/ios/scripts/refresh-sdk-presentation-state-fixtures.mjs`).
- The loading treatment is not authorable. Every signed presentation shimmers
  over `presentation.backgroundColor` until content is ready; there is no
  `loading` field, and one authored color carries the runtime surface, the
  shimmer field, and the recovery ground.

### Reviewing the presentation shell on device

The loading, recovery, warm, and per-mode presentation
states are only assessable while presented, and the interesting ones never
occur on a healthy cache. Drive them through the ordinary authenticated path:

```sh
xcrun simctl install booted \
  <derived-data>/Build/Products/Debug-iphonesimulator/NuxieExperienceRuntimeHost.app
scripts/capture-presentation-states.sh <output-dir>
```

The host app also accepts `--nuxie-presentation-state <scenario>` and
`--nuxie-presentation-condition normal|slow|failure|warm` to open one state
directly. Conditions delay or fail *acquisition*; no UI state is faked.

## Style

- Swift API Design Guidelines; public APIs get doc comments.
- Log via `LogDebug/LogInfo/LogWarning/LogError` (os_log-backed NuxieLogger) —
  never `print`.
- Conventional Commits; commits authored as Levi McCallum
  <levi@levimccallum.com>; no AI co-author trailers.

# Conformance fixtures

Language-neutral vectors that define Nuxie SDK semantics. The iOS SDK is one of
two native implementations (Kotlin is the other; server-side executors may
follow) — these files, not any one implementation, are the contract. See the
parent repo's `plans/nuxie-ios-sdk-cleanup-plan.md` (design principle 6).

## Layout

- `events/` — event-pipeline semantics: wire encoding, batching, dedup,
  retry/poison transitions
- `journeys/` — golden journeys (`golden-journeys.json`): wire-format
  campaign + flow (journey handlers) + scripted event timeline → ordered
  subsequence of tracked emissions, per-event property assertions,
  forbidden events, and surviving journey count. Runners drive a REAL
  journey service through the production Codable path (iOS:
  `Tests/NuxieIntegrationTests/Fixtures/GoldenJourneyTests.swift`).
  Still to add: clock-advance vectors (delay/time-window),
  experiment-resolution vectors
- `ir/` — IR evaluation vectors (`eval-vectors.json`): envelope + user props +
  event history + segment state + trigger event → expected boolean, including
  unknown-op forward-compat (fail-closed, non-poisoning) and `engine_min`
  gating (`expect_supported`)
- `encodings/` — (Phase 3) canonical wire encodings for cross-bridge types

## File format

Every file is a single JSON object:

```json
{
  "suite": "<area>/<name>",
  "version": 1,
  "description": "what invariant this pins and why",
  "vectors": [ { "name": "...", ...inputs..., "expect": { ... } } ]
}
```

Rules:

- Vectors are pure data-in/data-out. No implementation types, no
  language-specific idioms, all timestamps ISO-8601 UTC.
- Runners must fail on unknown `version`, never skip silently.
- Add vectors alongside the change that defines the semantics; a semantic
  change without a fixture change is a red flag in review.

## Runners

- iOS: `Tests/NuxieUnitTests/Fixtures/ConformanceVectorTests.swift` (loads this
  directory via the repo checkout).
- Android: `sdks/nuxie-android` CI must consume the same files (sync mechanism
  tracked in the cleanup plan, Phase 1).

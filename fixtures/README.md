# Conformance fixtures

Language-neutral vectors that define Nuxie SDK semantics. The iOS SDK is one of
two native implementations (Kotlin is the other; server-side executors may
follow) — these files, not any one implementation, are the contract. See the
parent repo's `plans/nuxie-ios-sdk-cleanup-plan.md` (design principle 6).

## Layout

- `events/` — event-pipeline semantics: wire encoding, batching, dedup,
  retry/poison transitions
- `journeys/` — golden journeys (`golden-journeys.json`, version 2):
  wire-format campaign + flow (journey handlers) + optional server
  experiment assignments + scripted timeline → ordered subsequence of
  tracked emissions, per-event property assertions, forbidden events,
  exact emission counts, and surviving journey count. Runners drive a
  REAL journey service through the production Codable path with a
  controllable clock (iOS:
  `Tests/NuxieIntegrationTests/Fixtures/GoldenJourneyTests.swift`).
  Covers entry actions, delay/clock-advance, goal conversion windows,
  and experiment resolution (assignment, freeze, fallback, error).
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

### Golden-journey timeline steps (`journeys/golden-journeys.json`)

Each timeline entry contains exactly one step key; runners must FAIL on
unknown step kinds (an entry a runner cannot execute must never be
silently skipped):

- `{"track": {"name": "...", "properties": {...}}}` — commit the event to
  history (stamped with the current SDK clock) and route it through the
  journey service, exactly like the production committed-event pipeline.
- `{"advance_clock_seconds": N}` — advance the SDK clock by N seconds and
  fire any timers that are now due (delay/time-window resume uses
  `resumeAt <= now`, so advancing exactly to the boundary fires).
- `{"assert_absent": ["event", ...]}` — mid-timeline checkpoint: none of
  these events may have been tracked yet (e.g. a delayed action must not
  fire before its delay elapses).
- `{"set_experiments": {"<key>": <assignment>, ...}}` — replace the
  profile's server experiment assignments, simulating a profile refetch
  mid-journey (frozen variants must not move).

Vector-level inputs: `experiments` (optional) installs server experiment
assignments (`experimentKey` → `{experimentKey, variantKey, status,
isHoldout}`) in the profile before the timeline runs.

Assertions in `expect`: `ordered_event_subsequence` (ordered-subsequence
match over tracked event names), `forbidden_events` (never tracked),
`event_properties` (subset match on the first tracked emission of each
named event), `event_counts` (exact number of tracked emissions), and
`active_journeys_after` (surviving live journey count).

Semantics the clock/experiment vectors pin down (observed runtime
behavior — record it faithfully, do not "fix" it in a fixture PR):

- Delay: pausing emits `$journey_paused`; after the clock passes
  `durationMs` the remaining actions run, then `$journey_resumed` is
  tracked AFTER the resumed chain (so a resumed chain that exits emits
  `$journey_completed` before `$journey_resumed`).
- Event-goal conversion windows compare the qualifying EVENT's timestamp
  against `[anchor, anchor + window]`; late evaluation is fine, but an
  event tracked after the window never converts. Without an exit policy
  a converted journey emits `$journey_goal_met` and stays active.
- Experiment resolution is server-assigned (profile `experiments` map),
  not locally hashed: a `running` assignment whose variant exists emits
  `$experiment_exposure` (`assignment_source: "profile"`) once per
  journey and freezes the variant for the journey's lifetime (later
  reassignments do not move it); no assignment falls back to the first
  variant with a tagged `$experiment_exposure_fallback`; a `running`
  assignment naming an unknown variant runs NO variant actions and emits
  `$experiment_exposure_error` (`reason: "variant_not_found"`).

## Runners

- iOS: `Tests/NuxieUnitTests/Fixtures/ConformanceVectorTests.swift` (loads this
  directory via the repo checkout).
- Android: `sdks/nuxie-android` CI must consume the same files (sync mechanism
  tracked in the cleanup plan, Phase 1).

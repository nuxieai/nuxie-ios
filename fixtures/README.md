# Experience execution fixtures

These language-neutral vectors pin the cross-plane experience-execution contract:

- `journeys/planes/admission.json`: local-program admission mutations over the
  signed release goldens: cursor and render closure, flat controls, fact proof,
  boundary schemas, and host-dismissal safety, shared by native validators.
- `journeys/planes/occurrence-evaluation.json`: horizon-fenced occurrence counts,
  predicates, numeric aggregates, relative windows, and unknown propagation.
- `journeys/planes/history-coverage.json`: durable count/age retention fences,
  tied timestamps, protected pending captures and server facts, late delivery,
  persistence gaps, restart, and known-empty versus incomplete query windows.
  Both native SQLite stores execute these vectors.
- `journeys/planes/release.json`: canonical TypeScript publisher-signed report-only
  and rendered leg envelopes, using the public development test key. The parent
  repository's device-leg release suite verifies the same envelopes against the
  canonical schemas and Ed25519 verifier; the iOS and macOS admission suites consume
  these bytes without reconstructing a whole journey.
- `journeys/planes/entry-evaluation.json`: flat-fact device-leg entry evaluation,
  including the foreground latch, event edges, opaque positive/negative membership
  gates, current property snapshots, and fail-closed unknown facts under negation.
  These vectors belong to the Experience Plane Partitioning runtime; the legacy
  handoff and claim suites below remain until the coordinated state discard.

- `journeys/transitions`: a timeline maps to ordered `$journey_transition` facts with exact properties.
- `journeys/effects`: deterministic request ids, server completion facts, result binding, timeout, late-arrival, and offline-delivery semantics.
- `segments/seed-mirror`: admitted profile snapshots replace the read-only membership value;
  missing membership rejects the response and explicit empty membership clears it.
- `profile/locale-admission`: locale participates in profile admission by
  invalidating the admission generation at the locale-change entry point;
  locale-scoped state (releases, segments, cached profile) rejects stale
  responses while customer-scoped payloads (facts, properties, mailbox)
  commit from a locale-flip discard and a round trip discards wholesale.
- `events/down-facts`: repeated server facts commit once, never upload, and route once to subscribers.
- `events/experience-events`: canonical `$experience_*` names and the
  experience identity/version properties carried by presentation facts and
  their customer/event/app-action/experiment riders.
- `events/atomic-purchase-sync`: exact `$purchase_synced` properties plus the
  stable retry identity, capture-before-retirement ordering, evidence
  retention, post-use access, and one-emission contract for atomic
  purchase-backed feature use.
- `events/delivery-disposition`: retry/auth/split/poison classification,
  all-or-nothing partial-ack validation, and poison-event isolation without
  disturbing valid neighbors.
- `events/generated-control-routing`: reserved generated native interaction
  identity resolves only to an exact signed control, never from an ordinary
  analytics event's payload.
- `golden-journey`: the minimal synchronous-enrollment journey vocabulary.
- `journeys/handoff`: server→device mailbox claim plus device→server
  `$journey_handoff` property shape, direction, epoch 0/1 encoding,
  destination-region addressing, unknown-version refusal, epoch advancement,
  and transferred terminality.
- `journeys/parking`: background and wait-pause `$journey_parked`
  checkpoints, device-plane tagging, pending deadlines, and epoch stamping.
- `journeys/dismissal`: exact `$journey_exited` host-attribution properties,
  while preserving the existing ordinary-dismissal reason vocabulary.
- `journeys/takeover`: claimable mailbox decoding, stale-checkpoint resume
  metadata, relaunch-equivalent restoration, immediate past-due scheduling,
  and original-device epoch rejection.
- `journeys/seizure-race`: the live device's timeout handoff winning the epoch
  CAS before seizure, with transferred terminality and one effect execution.
- `journeys/handler-host-dispatch`: declaration-strict screen-host routing for
  `$screen_shown`/`$screen_dismissed`, with the global Journey-host lifecycle
  fallback pinned separately from undeclared handler-only hosts.
- `journeys/ghost`: supersede/ghost accounting suppression and the explicit
  host-dismissal exception for a still-presented ghost play-out.
- `journeys/time-window`: identical Swift/server calendar decisions.
- `journeys/experiment-resolution`: identical Swift/server assignment,
  fallback, freezing, and invalid-assignment decisions.
- `journeys/screen-emission-runtime`: one typed control input becomes one
  atomic emission batch, then preserves response state and Customer Event
  identity through durable admission and replay.
- `experience-release-profile-v1/profile.json`: delivery origins plus the
  active and pinned locator/envelope membership wire shape shared by SDKs.
- `experience-release-descriptor/segment-trigger.json`: compiled segment
  predicate semantics, including disjunction and negative membership, kept
  distinct from the segment dependency inventory.
- `features/optimistic-entitlement-projection.json`: retained-evidence ×
  descriptor-allowance projection composed with an admitted authoritative
  snapshot. Vectors pin overlay absence, widening joins, post-ack server
  authority, tri-state readiness, revocation, identity scoping, and
  external-billing absence.

The Swift contract tests exercise the same behaviors. Consumers in other SDKs can reuse these JSON vectors.

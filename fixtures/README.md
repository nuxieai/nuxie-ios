# Experience execution fixtures

These language-neutral vectors pin the cross-plane experience-execution contract:

- `journeys/transitions`: a timeline maps to ordered `$journey_transition` facts with exact properties.
- `journeys/effects`: deterministic request ids, server completion facts, result binding, timeout, late-arrival, and offline-delivery semantics.
- `segments/seed-mirror`: profile generations reconcile an authoritative server membership mirror.
- `events/down-facts`: repeated server facts commit once, never upload, and route once to subscribers.
- `events/experience-events`: canonical `$experience_*` names and the
  experience identity/version properties carried by presentation facts and
  their customer/event/delegate/experiment riders.
- `events/atomic-purchase-sync`: exact `$purchase_synced` properties plus the
  stable retry identity, capture-before-retirement ordering, evidence
  retention, post-use access, and one-emission contract for atomic
  purchase-backed feature use.
- `golden-journey`: the minimal synchronous-enrollment journey vocabulary.
- `journeys/handoff`: server→device mailbox claim plus device→server
  `$journey_handoff` property shape, direction, epoch 0/1 encoding,
  destination-region addressing, unknown-version refusal, epoch advancement,
  and transferred terminality.
- `journeys/parking`: background and wait-pause `$journey_parked`
  checkpoints, device-plane tagging, pending deadlines, and epoch stamping.
- `journeys/takeover`: claimable mailbox decoding, stale-checkpoint resume
  metadata, relaunch-equivalent restoration, immediate past-due scheduling,
  and original-device epoch rejection.
- `journeys/seizure-race`: the live device's timeout handoff winning the epoch
  CAS before seizure, with transferred terminality and one effect execution.
- `journeys/handler-host-dispatch`: declaration-strict screen-host routing for
  `$screen_shown`/`$screen_dismissed`, with the global Journey-host lifecycle
  fallback pinned separately from undeclared handler-only hosts.
- `journeys/ghost`: supersede/ghost accounting suppression.
- `journeys/time-window`: identical Swift/server calendar decisions.
- `journeys/experiment-resolution`: identical Swift/server assignment,
  fallback, freezing, and invalid-assignment decisions.
- `experience-release-profile-v1/profile.json`: delivery origins plus the
  active and pinned locator/envelope membership wire shape shared by SDKs.
- `experience-release-descriptor/segment-trigger.json`: compiled segment
  predicate semantics, including disjunction and negative membership, kept
  distinct from the segment dependency inventory.

The Swift contract tests exercise the same behaviors. Consumers in other SDKs can reuse these JSON vectors.

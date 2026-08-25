# SDK execution event guidance

The canonical machine-readable event contract is
[`fixtures/events/catalog.json`](../fixtures/events/catalog.json). Its derived
human-readable view is [`docs/events-catalog.md`](events-catalog.md). This page
contains supplementary behavioral guidance rather than an event catalog.

Nuxie iOS emits the Experience Execution journey event family through the
normal event pipeline. These names are reserved; applications should not emit
them directly.

## Journey and experience behavior

`settings_snapshot` freezes the goal, conversion anchor and time, optional
goal-window end, and `end_on_goal` policy used for that run. The ownership
epoch changes only when ownership moves between server and device. Every
device-authored `$journey_*` fact carries the epoch the device owns.

The related `$customer_updated`, `$event_sent`, and `$app_action_requested` rider
events carry `experience_id`. `$experiment_exposure` carries both
`experience_id` and `experience_version`. Authored script events receive
`journey_id`, `experience_id`, and `screen_id` from the runner.

## Commerce behavior

For an atomic purchase-backed feature use, transport errors and non-2xx
responses retain the scoped receipt evidence, emit no `$purchase_synced`, and
retry with the same purchase-use event identity. A decoded 2xx response means
the command committed even when its post-use access is disallowed because the
last finite credit was consumed. Before retiring or scrubbing receipt evidence,
the SDK durably captures a stable `$purchase_synced` event scoped to the
purchasing identity. A failed capture keeps the bounded evidence for an
idempotent retry; replaying a captured event acknowledges the same identity
without duplicate delivery. The portable property, retry, and exactly-once contract is
`fixtures/events/atomic-purchase-sync.json`.

A mailbox claim is admitted only after the synchronous claim CAS acknowledges
the device and returns its authoritative epoch. The SDK first persists the
versioned state envelope, then enters through the same disk-resume path used
after process death. Unknown state versions are retained for diagnosis and
never claimed. A device-to-server handoff marks the local run `transferred`,
which is terminal on the device and does not consume completion frequency.

Mailbox entries are kind-discriminated as `pending` or `claimable`.
`claimable` is a parked run from another device; it uses the same claim CAS,
but restoration is no more eager than an ordinary relaunch. Its optional
`resumeNodeId` and `checkpointAt` are retained on the claimed journey as a
`resumePoint`, so presentation code can describe both where continuation
starts and how old that checkpoint is. The entry's `experienceVersion`
identifies the exact artifact to restore: the SDK uses the active inline
version when it matches and otherwise resolves it from profile
`pinnedVersions`. An offer is skipped when the same journey already exists
locally.

Parking does not transfer ownership or increment the epoch. The SDK queues a
device-plane state checkpoint for every live, owned journey when the app
backgrounds and whenever execution pauses on a wait. Wait parking copies
`pending_deadline_at` from the pending action's `resumeAt`. These facts use the
normal persist-first, non-throwing queue and participate in the background
flush; delivery failures remain queued for an ordered decision-lane retry.

The old journey start, lifecycle, goal-hit, node-executed, and completed event families are not emitted. A flow action that records progress uses `{ "type": "milestone", "milestoneId": "…" }`.

## Pre-presentation controls

`$products_unavailable` is a local journey control event, not an analytics
event. The SDK dispatches it to the authenticated journey's global handler when
one or more required live StoreKit products cannot be resolved. This happens
before renderer attachment. The abandoned commercial presentation and its
continuation are discarded; an authored `onProductsUnavailable` branch can
exit, hand off, wait, or otherwise choose a non-commercial path. If the release
does not declare that branch, the journey exits with an error.

## Server facts

Event and profile responses can deliver `$journey_converted`,
`$journey_effect_completed`, and `$journey_superseded` facts. The SDK persists
each fact id once with server provenance, excludes it from the upload queue,
and routes the newly committed event to journey subscribers. Effect
completions resume only the matching journey/node wait, bind the completion
properties into journey context, and select succeeded or failed actions. The
timer path means “no answer”; a terminal server failure is still a completion.

Supersede turns a visible run into local-only ghost play-out. The UI can finish
naturally, but the SDK emits no exit, goal, milestone, authored send-event,
experiment exposure, customer update, or effect request; it records no
completion and consumes no re-entry frequency. An explicit `NuxieSDK.dismiss()`
is the exception: it ends the still-presented local run as host-dismissed,
durably emits `$journey_exited`, and records that dismissal completion.

For compatibility with already-published device effect nodes, a request is
queued before the journey pauses, so airplane mode and app restarts preserve
delivery. Its invocation id is SHA-256 of `journey_id:node_id:attempt`;
transport retries reuse it. Ghost runs suppress the request.

## Segment memberships

Profile `segmentMemberships` is an authoritative server snapshot when present. An absent field makes no claim; an explicitly empty membership list clears the mirror. Server `enteredAt` timestamps are preserved. The SDK does not evaluate segment IR or enroll segment-triggered experiences from seed changes.

See [`fixtures/`](../fixtures/README.md) for portable contract vectors.

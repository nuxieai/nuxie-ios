# SDK execution events

Nuxie iOS emits the Experience Execution journey event family through the
normal event pipeline. These names and properties are reserved; applications
should not emit them directly.

## Journey events

| Event | Properties | Producer |
| --- | --- | --- |
| `$journey_enrolled` | `journey_id`, `epoch`, `experience_id`, `experience_version`, `trigger_ref`, `plane`, `settings_snapshot` | Device |
| `$journey_transition` | `journey_id`, `epoch`, optional `from_node`, `to_node`, `region`, `plane` | Device |
| `$journey_milestone` | `journey_id`, `epoch`, `milestone_id` | Device |
| `$journey_converted` | `journey_id`, `epoch`, `at`, `source_fact_ref` | Device evaluator or server down-fact |
| `$journey_exited` | `journey_id`, `epoch`, `reason`, `at` | Device |
| `$journey_effect_requested` | `journey_id`, `epoch`, `node_id`, deterministic `invocation_id`, `effect`, bounded `payload` | Device durable queue |
| `$journey_effect_completed` | `journey_id`, `node_id`, `invocation_id`, `status`, optional `result` or `error` | Server down-fact |
| `$journey_claimed` | `journey_id`, offered `epoch`, stable `claimant` | Device decision lane |
| `$journey_handoff` | `journey_id`, `epoch`, `direction`, versioned `envelope` | Device decision lane |
| `$journey_parked` | `journey_id`, `epoch`, versioned `checkpoint`, optional `pending_deadline_at`, `reason` (`background` or `wait`) | Device durable decision queue |
| `$journey_superseded` | `journey_id`, optional `winner_journey_id` | Server down-fact |

`settings_snapshot` freezes the goal, conversion anchor and time, optional
goal-window end, and `end_on_goal` policy used for that run. The ownership
epoch changes only when ownership moves between server and device. Every
device-authored `$journey_*` fact carries the epoch the device owns.

## Experience presentation events

| Event | Properties |
| --- | --- |
| `$experience_shown` | `journey_id`, `experience_id`, `experience_version` |
| `$experience_dismissed` | `journey_id`, `experience_id`, `experience_version` |
| `$experience_purchased` | `journey_id`, `experience_id`, `experience_version`, optional `product_id` |
| `$experience_timed_out` | `journey_id`, `experience_id`, `experience_version` |
| `$experience_errored` | `journey_id`, `experience_id`, `experience_version`, optional `error_message` |
| `$experience_artifact_load_succeeded` | `experience_version`, `artifact_build_id`, `artifact_source`, `artifact_content_hash` |
| `$experience_artifact_load_failed` | `experience_version`, `artifact_build_id`, `artifact_source`, `artifact_content_hash`, optional `error_message` |

The related `$customer_updated`, `$event_sent`, and `$delegate_called` rider
events carry `experience_id`. `$experiment_exposure` carries both
`experience_id` and `experience_version`. Authored script events receive
`journey_id`, `experience_id`, and `screen_id` from the runner.

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
completion and consumes no re-entry frequency.

For compatibility with already-published device effect nodes, a request is
queued before the journey pauses, so airplane mode and app restarts preserve
delivery. Its invocation id is SHA-256 of `journey_id:node_id:attempt`;
transport retries reuse it. Ghost runs suppress the request.

## Segment memberships

Profile `segmentMemberships` is an authoritative server snapshot when present. An absent field makes no claim; an explicitly empty membership list clears the mirror. Server `enteredAt` timestamps are preserved. The SDK does not evaluate segment IR or enroll segment-triggered experiences from seed changes.

See [`fixtures/`](../fixtures/README.md) for portable contract vectors.

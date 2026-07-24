# SDK execution events

Nuxie iOS emits the Experience Execution E1 journey event family through the normal event pipeline. These names and properties are reserved; applications should not emit them directly.

## Journey events

| Event | Properties | Producer |
| --- | --- | --- |
| `$journey_enrolled` | `journey_id`, `experience_id`, `experience_version`, `trigger_ref`, `plane`, `settings_snapshot` | Device |
| `$journey_transition` | `journey_id`, `epoch`, optional `from_node`, `to_node`, `region`, `plane` | Device |
| `$journey_milestone` | `journey_id`, `milestone_id` | Device |
| `$journey_converted` | `journey_id`, `at`, `source_fact_ref` | Device evaluator or server down-fact |
| `$journey_exited` | `journey_id`, `reason`, `at` | Device |
| `$journey_effect_requested` | `journey_id`, `node_id`, deterministic `invocation_id`, `effect`, bounded `payload` | Device durable queue |
| `$journey_effect_completed` | `journey_id`, `node_id`, `invocation_id`, `status`, optional `result` or `error` | Server down-fact |

`settings_snapshot` freezes the goal, conversion anchor and time, optional goal-window end, and `end_on_goal` policy used for that run. Transition epochs start at zero and increase monotonically within the device-main region.

The old journey start, lifecycle, goal-hit, node-executed, and completed event families are not emitted. A flow action that records progress uses `{ "type": "milestone", "milestoneId": "…" }`.

## Server facts

Event and profile responses can deliver `$journey_converted` and `$journey_effect_completed` facts. The SDK persists each fact id once with server provenance, excludes it from the upload queue, and routes the newly committed event to journey subscribers. Effect completions resume only the matching journey/node wait, bind the completion properties into journey context, and select succeeded or failed actions. The timer path means “no answer”; a terminal server failure is still a completion.

Connector and entitlement effect actions remain device-owned execution steps. Their request is queued before the journey pauses, so airplane mode and app restarts preserve delivery. The invocation id is SHA-256 of `journey_id:node_id:attempt`; transport retries reuse it.

## Segment memberships

Profile `segmentMemberships` is an authoritative server snapshot when present. An absent field makes no claim; an explicitly empty membership list clears the mirror. Server `enteredAt` timestamps are preserved. The SDK does not evaluate segment IR or enroll segment-triggered campaigns from seed changes in E1.

See [`fixtures/`](../fixtures/README.md) for portable contract vectors.

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

`settings_snapshot` freezes the goal, conversion anchor and time, optional goal-window end, and `end_on_goal` policy used for that run. Transition epochs start at zero and increase monotonically within the device-main region.

The old journey start, lifecycle, goal-hit, node-executed, and completed event families are not emitted. A flow action that records progress uses `{ "type": "milestone", "milestoneId": "…" }`.

## Server facts

Event and profile responses can deliver `$journey_converted` facts. The SDK persists each fact id once with server provenance, excludes it from the upload queue, and routes the newly committed event to journey subscribers. A server conversion latches the run without causing the SDK to emit a second conversion event.

## Segment memberships

Profile `segmentMemberships` is an authoritative server snapshot when present. An absent field makes no claim; an explicitly empty membership list clears the mirror. Server `enteredAt` timestamps are preserved. The SDK does not evaluate segment IR or enroll segment-triggered campaigns from seed changes in E1.

See [`fixtures/`](../fixtures/README.md) for portable contract vectors.

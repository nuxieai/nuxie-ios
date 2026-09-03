# SDK event catalog

`fixtures/events/catalog.json` is the machine-readable authority for every reserved event the current SDK can emit. The catalog contains only live events. Renderer response controls are local Journey inputs and do not belong to the event catalog.

Every event follows one of three paths:

- `processCapture`: ordinary EventLog capture, durable local history, and batch delivery.
- `captureStableSystemEvent`: capture under a stable id before Journey state advances, followed by batch delivery.
- `featureCommand` plus `storePreparedEventInHistory`: the feature command uses `/event`; its accepted result is mirrored once into delivered local history for Journey routing and forwarding.

All three paths apply `beforeSend`. Returning `nil` is a terminal privacy decision: the event is neither uploaded nor forwarded, and stable Journey producers treat the drop as acknowledged so it cannot create an immortal retry.

## Journey execution

| Event | Meaning | Capture path |
| --- | --- | --- |
| `$journey_leg_started` | A Journey began an authenticated release leg. | stable |
| `$journey_leg_completed` | The leg ended and queued its declared outputs and outcome. | stable |
| `$journey_milestone` | The Journey reached an authored milestone. | stable |
| `$experiment_exposure` | A selected experiment variant became visible. | stable |
| `$screen_shown` | A Journey screen became visible. | stable |
| `$screen_dismissed` | A Journey screen was dismissed or replaced. | stable |
| `$products_unavailable` | Required live products could not be resolved before presentation. | stable |

Leg lifecycle and milestone facts carry `journey_id`, `experience_id`, `experience_version_id`, `leg_id`, and `leg_generation`. A completion also carries `started_at`, `completed_at`, `outcome`, and the exact declared `outputs`. Experiment exposure carries the Journey, experience/version, leg identity, selected variant, holdout flag, and whether the selection came from the profile assignment or the authored fallback. Assignment alone never emits an exposure.

## Experience and host effects

| Event | Meaning | Capture path | Public activity |
| --- | --- | --- | --- |
| `$experience_shown` | The Experience became visible. | ordinary | `experienceShown` |
| `$experience_dismissed` | The Experience closed normally. | ordinary | `experienceDismissed` |
| `$experience_errored` | Presentation ended with an error. | ordinary | `experienceErrored` |
| `$experience_artifact_load_succeeded` | A signed artifact loaded. | ordinary | hidden |
| `$experience_artifact_load_failed` | A signed artifact failed to load. | ordinary | `experienceLoadFailed` |
| `$customer_updated` | An authored Journey effect updated customer properties. | stable | hidden |
| `$app_action_requested` | An authored Journey effect invoked the host callback. | stable | hidden |

`$customer_updated` and `$app_action_requested` include the authenticated release and leg identity. An authored send-event action emits its authored application event directly; the SDK does not wrap it in another reserved event.

## Purchases, permissions, lifecycle, and features

| Family | Events | Capture path |
| --- | --- | --- |
| App lifecycle | `$app_installed`, `$app_updated`, `$app_opened`, `$app_backgrounded` | ordinary |
| Permissions | `$notifications_enabled`, `$notifications_denied`, `$permission_granted`, `$permission_denied`, `$tracking_authorized`, `$tracking_denied` | ordinary outside a presentation; stable when Journey-owned |
| Purchase outcomes | `$purchase_cancelled`, `$purchase_failed`, `$purchase_synced`, `$restore_completed`, `$restore_failed`, `$restore_no_purchases` | ordinary or stable, depending on correlation |
| Stable purchase completion | `$purchase_completed` | stable |
| Pending purchase | `$purchase_pending` | ordinary |
| Feature usage | `$feature_used` | durable feature command and delivered-history mirror |
| Identity | `$identify` | ordinary and hidden from public activity |

The exact property schema, emitter files, delivery flags, and forwarding decision for each event live in the JSON catalog. `scripts/check-event-catalog.sh` checks that every catalog constant exists, every declared reserved event has one row, emitter files exist, semantic arrays align, and retired Journey protocol names do not return.

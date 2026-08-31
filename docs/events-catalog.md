# Internal event catalog

This catalog records every reserved `$`-prefixed event declared or emitted by the iOS SDK. It is the human-readable view derived from `fixtures/events/catalog.json`, the canonical machine-readable cross-SDK contract. The fixture records the constant, lifecycle status, author, capture lane, persistence, `beforeSend` policy, wire destination, event-specific properties, production emitters, forwarding curation, fixtures, and public documentation coverage.

The conformance test loads that fixture, binds every declared Swift constant at compile time, requires every event not marked `delete` or `retired` to have a production emitter, and pins each event's exact forwarding value to revision 3 of `specs/sdk-analytics-forwarding-spec.md`. `make check-event-catalog` resolves every catalog emitter to an emission call, reverse-checks source emission calls against the catalog, and verifies every catalog name not marked `delete` or `retired` appears under `Sources`. Generic SDK context properties are intentionally omitted from each row. They are applied by `NuxieContextBuilder` and include app, device, locale, identity, and current session context.

## Lifecycle

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$app_installed` | active | platform | yes | governed | `/i/event` | `appInstalled` | First launch after installation. |
| `$app_updated` | active | platform | yes | governed | `/i/event` | `appUpdated` | First launch after the app version changes. |
| `$app_opened` | active | platform | yes | governed | `/i/event` | `appOpened` | App launch or foreground transition; first/update launches retain their install/update fields. |
| `$app_backgrounded` | active | platform | yes | governed | `/i/event` | `appBackgrounded` | App background transition. |

## Journey protocol

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$journey_started` | retired | platform | no | exempt | none | hidden: retired runtime control | Retired control input with no production emitter. |
| `$journey_enrolled` | active | platform | yes | exempt | `/i/event` | `journeyStarted` | Device enrolls a run against a pinned Experience Version. |
| `$journey_leg_started` | active | platform | yes | governed | batch | `journeyLegStarted` | Device starts one leg, echoing its generation; generation zero also enrolls a new journey. |
| `$journey_leg_completed` | active | platform | yes | governed | batch | `journeyLegCompleted` | Device queues the outcome and declared buffered outputs, then forgets the run. |
| `$journey_transition` | active | platform | yes | exempt / governed | `/i/event` or batch | hidden: state-sync protocol | A run advances between nodes, or pending-action resume records a response-snapshot conflict. |
| `$journey_milestone` | active | platform | yes | exempt | `/i/event` | `milestoneReached` | A run reaches an authored milestone through scoped `trackForTrigger` plus local history, or the runner's `trackWithResponse` fallback. |
| `$journey_converted` | active | platform / server | yes | exempt | `/i/event` or none | `journeyConverted` | A Goal is satisfied locally or arrives as a server down-fact. |
| `$journey_exited` | active | platform | yes | exempt / governed | `/i/event` or batch | `journeyEnded` | A run reaches a terminal state; host exits use stable governed capture. |
| `$journey_effect_requested` | active | platform | yes | governed | batch | hidden: effect protocol | Device requests a durable server effect. |
| `$journey_effect_completed` | active | server | yes | exempt | none | hidden: effect protocol | Server reports an effect outcome. |
| `$journey_claimed` | active | platform | yes | exempt | `/i/event` | hidden: ownership protocol | Device claims a server mailbox offer. |
| `$journey_handoff` | active | platform | yes | exempt | `/i/event` | hidden: ownership protocol | Device transfers a versioned run envelope to the server. |
| `$journey_parked` | active | platform | yes | governed | batch | hidden: checkpoint protocol | Device publishes a resumable checkpoint. |
| `$journey_superseded` | active | server | yes | exempt | none | `journeyEnded` | Server cancels a losing journey owner. |

## Experience presentation

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$experience_shown` | active | platform | yes | governed | batch | `experienceShown` | An Experience becomes visible. |
| `$experience_dismissed` | active | platform | yes | governed | batch | `experienceDismissed` | A visible Experience is dismissed. |
| `$experience_errored` | active | platform | yes | governed | batch | `experienceErrored` | Experience execution fails. |

## Screens

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$screen_shown` | active | platform | yes | governed | batch | `screenShown` | A Journey screen becomes active. |
| `$screen_dismissed` | active | platform | yes | governed | batch | `screenDismissed` | A Journey screen is dismissed. |

## Commerce

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$purchase_completed` | active | platform | yes | governed | batch or `/i/event` | `purchaseCompleted` | Stable transaction paths queue batch delivery; the no-id SystemEventSink fallback uses the trigger lane. |
| `$purchase_failed` | active | platform | yes | governed | `/i/event` | `purchaseFailed` | Purchase setup or execution fails. |
| `$purchase_cancelled` | active | platform | yes | governed | `/i/event` | `purchaseCancelled` | Customer cancels a purchase. |
| `$purchase_pending` | active | platform | yes | governed | `/i/event` | `purchasePending` | Purchase awaits later approval. |
| `$purchase_synced` | active | platform | yes | governed | batch or `/i/event` | `purchaseSynced` | Atomic capture queues batch delivery; ordinary synchronization uses the trigger lane. |

## Restore

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$restore_completed` | active | platform | yes | governed | `/i/event` | `restoreCompleted` | Restore finishes with purchases. |
| `$restore_failed` | active | platform | yes | governed | `/i/event` | `restoreFailed` | Restore fails. |
| `$restore_no_purchases` | active | platform | yes | governed | `/i/event` | `restoreNoPurchases` | Restore finishes without purchases. |

## Features

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$feature_used` | active | platform | yes | governed | `/i/event` | `featureUsed` | Authoritative metered Feature use persists as a stable command before send, then mirrors its accepted result under the same operation id. |

## Experiments

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$experiment_exposure` | active | platform | yes | governed | batch | `experimentExposure` | A real server-assigned variant is exposed. |
| `$experiment_exposure_fallback` | renaming | platform | yes | governed | batch | hidden: default-variant diagnostic | No assignment exists and the authored default variant runs. |
| `$experiment_exposure_error` | active | platform | yes | governed | batch | `experimentError` | A server assignment names an unknown variant. |

## Permissions

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$notifications_enabled` | active | platform | yes | governed | `/i/event` | `permissionResolved` | Notification authorization resolves enabled. |
| `$notifications_denied` | active | platform | yes | governed | `/i/event` | `permissionResolved` | Notification authorization resolves denied. |
| `$permission_granted` | active | platform | yes | governed | `/i/event` | `permissionResolved` | An authored platform permission resolves granted or limited. |
| `$permission_denied` | active | platform | yes | governed | `/i/event` | `permissionResolved` | An authored platform permission resolves denied, including the unsupported scoped path. |
| `$tracking_authorized` | active | platform | yes | governed | `/i/event` | `permissionResolved` | Tracking authorization resolves authorized. |
| `$tracking_denied` | active | platform | yes | governed | `/i/event` | `permissionResolved` | Tracking authorization resolves denied or unsupported. |

Scoped and unscoped permission events use governed, persistent `trackForTrigger`; both paths use the `/i/event` response lane.

## Identity and riders

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$identify` | active | platform | yes | governed | batch | hidden: identity and PII | Identity changes or user properties are recorded. |
| `$customer_updated` | active | designer | yes | governed | batch | hidden: identity and PII rider | An authored action changes customer attributes. |
| `$event_sent` | active | designer | yes | governed | batch | hidden: authored event rider | An authored Send Event action sends its own event. |
| `$app_action_requested` | active | designer | yes | governed | batch | hidden: separate delegate channel | An authored App Action is delivered to the host. |

## Responses

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$response_set` | active | designer | no | exempt | none | hidden: local response control | A published runtime action or native text input writes a response field. |
| `$response_unset` | active | designer | no | exempt | none | hidden: local response control | A published runtime action clears a response field. |

These controls persist through Journey response state rather than the event store.

## Diagnostics

| Name | Status | Authored by | Persists | beforeSend | Wire | Forwarding | Meaning |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `$products_unavailable` | active | platform | yes | governed | batch | `productsUnavailable` | Required live store products cannot be resolved. |
| `$experience_artifact_load_succeeded` | active | platform | yes | governed | batch | hidden: successful load noise | A signed Experience artifact loads successfully. |
| `$experience_artifact_load_failed` | active | platform | yes | governed | batch | `experienceLoadFailed` | A signed Experience artifact cannot be loaded or admitted. |

## Findings

### Inline literals not in constants

No uncataloged event name was found. The inline event-name strings in the renderer screen-emission path and the server down-fact raw values all resolve to existing constants. `$navigate` is excluded because `ExperienceInteractiveScreen` treats it as a rejected runtime control command, not an emitted event.

### Forwarding spec table gaps

None. Every one of the 48 catalog names is mentioned directly or by a grouped row in the revision 3 curation table.

Code reality does conflict with broader forwarding premises. `$journey_effect_requested` and `$journey_parked` use governed `processCapture` and queue batch delivery even though journey protocol facts are described as exempt. `$journey_transition` is normally exempt through `trackWithResponse`, but its response-snapshot-conflict diagnostic uses governed `processCapture`. `$journey_exited` is normally exempt through `trackWithResponse`, while host exits use governed stable capture. `$journey_converted` has both a platform-authored `trackWithResponse` emitter and a server down-fact emitter, while the curation table describes it as a server down-fact.

### Emitter property drift versus fixtures

- On first or updated launches, `$app_opened` reuses the mutable lifecycle properties and therefore retains `install_date`, or `previous_version` and `update_date`, respectively.
- `$journey_transition` has two property variants: canonical node transitions require `epoch`, `journey_id`, `plane`, `region`, and `to_node`; response-snapshot conflicts instead require `journey_id`, `error`, `node_id`, `expected_response_version`, and `actual_response_version`.
- `$feature_used` is pinned in `fixtures/events/batch-item-encoding.json` with `value` and `entityId` in event properties. The durable command retains that transport shape and operation id across retries; after acceptance, history under the same id uses `feature_id`, `amount`, optional `entity_id`, and optional `metadata` for typed forwarding.

Forwarding identity is captured at the producer. Products-unavailable includes product ids; screen, artifact-load, experiment diagnostic, and dismissal events include their available Experience context; dismissal includes the close reason; and purchase synchronization includes recoverable commercial context.

### Documentation notes

The public system-events page omits `$journey_started`, `$products_unavailable`, `$experiment_exposure_fallback`, `$experiment_exposure_error`, `$customer_updated`, `$event_sent`, and `$app_action_requested`. It also says lifecycle capture is switch-controlled even though current lifecycle capture is unconditional.

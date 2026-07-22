# SDK internal events reference

Canonical catalog of every `$`-prefixed internal event the Nuxie iOS SDK
emits, when each fires, its property keys, and its delivery guarantees.
Event names without a `$` prefix are user/authored events and are out of
scope here.

This document is wire-accurate as of the Phase 6 event-taxonomy pass.
Constants live in two files — every emission must reference them (no bare
`$`-event string literals at emitter sites):

- `Sources/Nuxie/Journey/Events/JourneyEvents.swift` — `$journey_*`,
  `$flow_*`, `$experiment_*`, `$customer_updated`, `$event_sent`,
  `$delegate_called`
- `Sources/Nuxie/Events/SystemEventNames.swift` — everything else
  (`$identify`, `$app_*`, `$feature_used`, `$screen_*`, `$purchase_*`,
  `$restore_*`, permissions, `$response_set`)

## Conventions

- **Names**: `$<domain>_<past_tense_verb>` (e.g. `$journey_resumed`,
  `$purchase_completed`). A few names are established noun forms
  (`$journey_action`, `$experiment_exposure`) — kept as-is because they
  are already consistent on the wire and in fixtures.
- **Property keys**: snake_case (`journey_id`, `campaign_id`, `flow_id`,
  `screen_id`, `resume_reason`). Known documented exception:
  `$feature_used` (see below).
- **Fixture-pinned**: names/properties pinned by the cross-SDK
  conformance fixtures in `fixtures/` (the contract shared with the
  Android SDK). Changing them is a cross-SDK/backend change.
- **Backend-ingested by name**: the ingest pipeline routes these
  specially; renames require a coordinated backend change.

## Delivery guarantees

- **Durable queue** (`EventLog.track` / `trackForTrigger`): the event is
  persisted PENDING in SQLite before any network round trip and delivered
  at-least-once in batches; the event's UUIDv7 id is the server-side
  idempotency key (pinned by `fixtures/events/batch-item-encoding.json`).
  Unless noted otherwise, every event below is durable.
- **Trigger-routed** (`NuxieSDK.trigger` → `trackForTrigger`): durable as
  above, plus the event is routed through journey triggers locally first.
- **Internal dispatch only**: synthesized as a `NuxieEvent` and dispatched
  to flow/journey handlers in-process; NOT tracked to the EventLog and
  never sent to the backend by itself.

## The two journey event families

The SDK deliberately emits two parallel families for journey lifecycle.
They are **not** duplicates and must not be merged:

1. **Server journey mirror** — `$journey_start`,
   `$journey_node_executed`, `$journey_completed`. The backend ingests
   these by name into the customer journey mirror and keys them by
   `session_id` (the journey id). `$journey_start` rides the durable
   queue so offline enrollments arrive late but at-least-once.
2. **Observability lifecycle** — `$journey_started`, `$journey_paused`,
   `$journey_resumed`, `$journey_errored`, `$journey_exited`, etc.
   Richer analytics payloads keyed by `journey_id`/`campaign_id`.

`$journey_start` vs `$journey_started` is therefore intentional: the
former is the wire enrollment record, the latter the analytics event.

## Catalog

### Identity & app lifecycle

| Event | Fires when | Properties |
| --- | --- | --- |
| `$identify` | `identify()` changes the user or applies user properties (bare same-id re-identify is a no-op) | `distinct_id`; `$anon_distinct_id` (only on anonymous → identified transition; lifted to a top-level batch field — fixture-pinned) |
| `$app_installed` | First launch ever | `source: "app_lifecycle"`, `app_version`, `install_date` |
| `$app_updated` | Launch after `app_version` changed | `source`, `app_version`, `previous_version`, `update_date` |
| `$app_opened` | Every launch, and every foreground | `source`, `app_version`, `open_date` (launch) or `foreground_date` (foreground). Also the conventional entry-handler event name for flow entry actions |
| `$app_backgrounded` | App enters background | `source`, `background_date` |

All are trigger-routed (they can start journeys).

### Feature usage

| Event | Fires when | Properties |
| --- | --- | --- |
| `$feature_used` | `NuxieSDK.useFeature()` — sent directly to the event endpoint for immediate balance confirmation (not the durable batch queue) | `feature_extId`, `setUsage?`, `metadata?`; `value`/`entityId` ride as top-level request fields (`value`, `entity_id` on the wire — fixture-pinned) |

**Documented key-convention exception**: `feature_extId` and `setUsage`
are camelCase because `nuxie-ingest` requires the `feature_extId`
property by name (it rejects the event without it). Renaming them to
snake_case needs a coordinated backend + Android change; until then they
are the one intentional exception to the snake_case rule.

### Journey mirror (backend-ingested by name; `session_id` = journey id)

| Event | Fires when | Properties |
| --- | --- | --- |
| `$journey_start` | Local-first enrollment, the moment a journey starts from cached config | `session_id`, `campaign_id`, `flow_id`, `entry_node_id` |
| `$journey_node_executed` | A renderer screen change/reveal (async), and remote actions (async fire-and-forget on the durable queue, or synchronous via `trackWithResponse` when the node awaits server execution) | `session_id`, `node_id`, `async`, `context`; remote nodes add `screen_id`, `node_data` |
| `$journey_completed` | A journey completes or is cancelled (fixture-pinned) | `session_id`, `exit_reason`, `goal_met`, `goal_met_at`, `duration_seconds` |

### Journey observability lifecycle

| Event | Fires when | Properties |
| --- | --- | --- |
| `$journey_started` | Immediately after `$journey_start`, with analytics detail | `journey_id`, `campaign_id`, `campaign_name`, `flow_id`, `entry_screen_id?`, `trigger_type`, `trigger_event_name?`, `trigger_event_properties?`, `trigger_segment?` |
| `$journey_paused` | A runner chain pauses (delay, wait_until, remote retry, time window) (fixture-pinned). Note: an event that fails a `wait_until` condition re-arms the same wait and re-emits this | `journey_id`, `campaign_id`, `screen_id?`, `resume_at?` |
| `$journey_resumed` | A paused journey actually moves past its pending action. Tracked AFTER the resumed chain runs (fixture-pinned: a resumed chain that exits emits `$journey_completed` first) | `journey_id`, `campaign_id`, `resume_reason` (`"timer"` \| `"event"`), `screen_id?` |
| `$journey_errored` | A journey exits with `.error` | `journey_id`, `campaign_id`, `screen_id?`, `error_message?` |
| `$journey_goal_hit` | A flow goal action fires (also dispatched as a scoped trigger event) | `journey_id`, `campaign_id`, `goal_id`, `goal_label?`, `screen_id?`, `handler_id?` |
| `$journey_goal_met` | Campaign-level goal evaluation converts the journey (fixture-pinned) | `journey_id`, `campaign_id`, `goal_kind`, `met_at`, `window_seconds` |
| `$journey_exited` | Every journey completion/cancellation (alongside the `$journey_completed` mirror record) | `journey_id`, `campaign_id`, `exit_reason`, `screen_id?` |
| `$journey_action` | Every executed journey action (per-action observability) | `journey_id`, `campaign_id`, `action_type`, `screen_id?`, `handler_id?`, `error_message?` |

#### `$journey_resumed` resume reasons

Every path that resumes a journey emits `$journey_resumed` with a
truthful `resume_reason` (`JourneyEvents.ResumeReasonValue`):

- `"timer"` — the pending action's deadline elapsed. Covers all three
  timer-notice paths: the in-process scheduled timer firing, the
  due-timer sweep during SDK initialize after a relaunch (kill-resume),
  and the due-timer sweep on app foreground.
- `"event"` — a `wait_until` pending action resumed because a routed
  event satisfied (or timed the wait out past) its condition. This
  includes restored journeys whose runner was lazily rebuilt for event
  dispatch. An event that fails the wait condition re-arms the same wait
  and does NOT emit `$journey_resumed`.

### Flow presentation

| Event | Fires when | Properties |
| --- | --- | --- |
| `$flow_shown` | A flow is successfully presented (tracked once, by the presentation service) | `journey_id`, `campaign_id`, `flow_id` |
| `$flow_dismissed` | Presented flow closed by user or goal-met | `journey_id`, `campaign_id`, `flow_id` |
| `$flow_purchased` | Presented flow closed after purchase completion | `journey_id`, `campaign_id`, `flow_id`, `product_id?` |
| `$flow_timed_out` | Presented flow closed by timeout | `journey_id`, `campaign_id`, `flow_id` |
| `$flow_errored` | Presented flow closed by error | `journey_id`, `campaign_id`, `flow_id`, `error_message?` |
| `$flow_artifact_load_succeeded` | Flow artifact finished loading (once per presentation) | `flow_id`, `artifact_build_id`, `artifact_source`, `artifact_content_hash` |
| `$flow_artifact_load_failed` | Flow artifact failed to load (once per presentation) | same + `error_message?` |

`$flow_*` event names are part of the wire layer shared with the Rust
runtime — frozen.

### Journey action side effects

| Event | Fires when | Properties |
| --- | --- | --- |
| `$customer_updated` | `update_customer` action applied user properties | `journey_id`, `campaign_id`, `attributes_updated`, `screen_id?` |
| `$event_sent` | `send_event` action tracked an authored event | `journey_id`, `campaign_id`, `event_name`, `event_properties`, `screen_id?` |
| `$delegate_called` | `call_delegate` action posted to the host app | `journey_id`, `campaign_id`, `message`, `payload?`, `screen_id?` |

The authored event emitted by `send_event` itself is additionally
enriched with `journey_id`, `campaign_id`, and `screen_id?` (snake_case
attribution keys).

### Experiments (fixture-pinned)

| Event | Fires when | Properties |
| --- | --- | --- |
| `$experiment_exposure` | A server assignment resolved to a real variant (once per journey; variant frozen for the journey's lifetime) | `journey_id`, `campaign_id`, `flow_id`, `experiment_key`, `variant_key`, `is_holdout`, `assignment_source?` (`"profile"`) |
| `$experiment_exposure_fallback` | No server assignment; first variant ran as fallback | `experiment_key`, `variant_key`, `assignment_source: "no_assignment"` |
| `$experiment_exposure_error` | Assignment named an unknown variant; no variant ran | `experiment_key`, `variant_key`, `reason: "variant_not_found"` |

### Screens (internal dispatch only)

| Event | Fires when | Properties |
| --- | --- | --- |
| `$screen_shown` | A screen becomes current (navigation or reveal-after-dismiss) | `screen_id` |
| `$screen_dismissed` | A screen is dismissed (native sheet or runtime dismiss) | `screen_id`, `method` |

These are synthesized trigger events for authored flow handlers; they are
not tracked to the EventLog.

### Purchases & restores (trigger-routed)

| Event | Fires when | Properties |
| --- | --- | --- |
| `$purchase_completed` | Purchase succeeded (immediate UI success), or a deferred Ask-to-Buy/SCA transaction resolved | `product_id`, `price`, `display_price` (immediate) / `product_id`, `transaction_id`, `source: "deferred_transaction"` (deferred) |
| `$purchase_failed` | Purchase failed (StoreKit error or product not found) | `product_id`, `error` |
| `$purchase_cancelled` | User cancelled the purchase | `product_id` |
| `$purchase_pending` | Ask-to-Buy/SCA left the purchase pending | `product_id` |
| `$purchase_synced` | Transaction JWS synced with the backend | `transaction_id`, `original_transaction_id`, `product_id`, `customer_id` |
| `$restore_completed` | Restore succeeded | `restored_count` |
| `$restore_failed` | Restore failed | `error` |
| `$restore_no_purchases` | Restore found nothing | — |

Purchase/restore outcome events are also consumed in-process by the
initiating node's outcome outlets (onCompleted/onFailed/onCancelled).

### Permissions (scoped; tracked via the scoped-event pipeline)

| Event | Fires when | Properties |
| --- | --- | --- |
| `$notifications_enabled` / `$notifications_denied` | `request_notifications` action resolved | `journey_id?` |
| `$permission_granted` / `$permission_denied` | `request_permission` action resolved (denied also covers unsupported permission types) | `journey_id?`, `type` |
| `$tracking_authorized` / `$tracking_denied` | `request_tracking` action resolved | `journey_id?` |

### Response collection

| Event | Fires when | Properties |
| --- | --- | --- |
| `$response_set` | A text input commits a value mapped to a response field (renderer event; also runs the built-in response-draft logic) | `field`, `value` |

## Rules for changing this catalog

1. Add/rename events only through the constants files; update this doc in
   the same PR.
2. Never rename anything marked fixture-pinned or backend-ingested
   without a coordinated fixtures + backend (+ Android SDK) change.
3. `$flow_*` names and the FlowRuntime ABI strings (`flow.riv`,
   `nux_flow_runtime_*`) are frozen wire contracts with the Rust runtime.
4. New property keys are snake_case.

# Forward Nuxie activity to your analytics tool

Nuxie exposes a curated activity stream through `NuxieDelegate`. Each callback is delivered on the main actor after its source event is durably captured. Delivery is FIFO and at most once. Activity is not replayed when a delegate is attached late, so assign the delegate before calling `setup(with:)`.

```swift
private extension NuxieActivityValue {
    var analyticsValue: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .double(let value): value
        case .bool(let value): value
        @unknown default: ""
        }
    }
}

private extension Dictionary where Key == String, Value == NuxieActivityValue {
    var analyticsProperties: [String: Any] { mapValues(\.analyticsValue) }
}

@MainActor
final class AnalyticsForwarder: NuxieDelegate {
    func nuxieDidEmit(_ info: NuxieActivityInfo) {
        Amplitude.instance().logEvent(
            info.name,
            withEventProperties: info.properties.analyticsProperties
        )
    }
}

let analyticsForwarder = AnalyticsForwarder()
NuxieSDK.shared.delegate = analyticsForwarder
```

The same flat name and property view works with Mixpanel, PostHog, and similar tools. `NuxieActivityValue` is a JSON-safe scalar enum. Arrays in the typed activity, such as unavailable product identifiers, appear as comma-joined strings in the flat property view.

Use `info.id` as an idempotency key when the destination supports one. `info.timestamp` records when the activity happened; `info.receivedAt` records when this SDK durably captured it. For exhaustive Swift handling, switch over `info.activity` and include an `@unknown default` branch.

## Customer attribution

`info.customerId` identifies the customer who produced the durable activity.
Use that ID when attributing forwarded analytics; the SDK's current customer
may already have changed by the time the delegate runs.

For UI or gameplay tied to the current customer, check `info.isCurrentIdentity`
before acting. This property checks the original capture's identity session when
read. Switching A → B → A does not reactivate activity from the first A session,
and shutting down the SDK invalidates activities from that SDK session. Stale
activities are still delivered for analytics, with their original customer ID.
These fields do not change the flat activity name or properties.

## Curated activity

| Internal source | Public activity |
| --- | --- |
| `$experience_shown` | `experienceShown` |
| `$link_opened` | `linkOpened` |
| `$experience_dismissed` | `experienceDismissed` |
| `$experience_errored` | `experienceErrored` |
| `$journey_leg_started` | `journeyStarted` |
| `$journey_leg_completed` | `journeyCompleted` |
| `$experiment_exposure` | `experimentExposure` |
| `$purchase_completed` | `purchaseCompleted` |
| `$purchase_failed` | `purchaseFailed` |
| `$purchase_cancelled` | `purchaseCancelled` |
| `$purchase_pending` | `purchasePending` |
| `$purchase_synced` | `purchaseSynced` |
| `$restore_completed` | `restoreCompleted` |
| `$restore_failed` | `restoreFailed` |
| `$restore_no_purchases` | `restoreNoPurchases` |
| `$feature_used` | `featureUsed` |
| `$products_unavailable` | `productsUnavailable` |
| `$screen_shown` | `screenShown` |
| `$screen_dismissed` | `screenDismissed` |
| `$experience_artifact_load_failed` | `experienceLoadFailed` |
| `$notifications_enabled`, `$notifications_denied` | `permissionResolved` |
| `$permission_granted`, `$permission_denied` | `permissionResolved` |
| `$tracking_authorized`, `$tracking_denied` | `permissionResolved` |
| `$app_installed` | `appInstalled` |
| `$app_updated` | `appUpdated` |
| `$app_opened` | `appOpened` |
| `$app_backgrounded` | `appBackgrounded` |

`$app_action_requested`, `$customer_updated`, `$experience_artifact_load_succeeded`, and `$identify` are intentionally hidden. App Action uses the separate `nuxie(_:didRequestAppAction:)` callback described in [Run App Action](run-app-action.md).

Journey execution adds `journeyStarted` and `journeyCompleted`. Both include
the experience/version, Journey id, signed release id, and generation;
completion also includes its authored outcome. Buffered outputs remain in the
stable completion report and are omitted from the flat activity view.

## Filtering and delivery

`beforeSend` governs every event path, including stable Journey reports. Returning `nil` suppresses the wire event, history row, and activity callback together. Renaming an event does not change its typed public activity case.

Pending wire delivery may retry after restart, but retries do not replay `nuxieDidEmit`. A process exit between durable capture and callback can lose the callback, which is why the contract is at most once rather than guaranteed delivery.

`$link_opened` forwards as `linkOpened` (`link_opened`), with URL, actual destination, optional original target, optional screen/source alias, and the same Journey leg attribution as the lifecycle activities.

The link record includes `destination` (`in_app` or `external`) and retains the authored `target` separately. A Journey link with no owned Experience opens externally. Invalid step inputs and unavailable handlers advance `next` without opening or recording.

Links use the same state table for runtime hrefs and Journey steps. A settled, owned
Experience opens web links in-app from its topmost controller for an omitted target,
`_self`, `_parent`, `_top`, or `in_app`. `_blank` and `external` use the browser.
Closing, closed, and screenless Experiences use the browser or system for every link.
Background apps open and record nothing. Non-web schemes go to the system only when
available. Broken Journey link steps advance without opening, recording, or dismissing.
`$link_opened` and the public `linkOpened` activity include the actual `destination`
(`in_app` or `external`) and the original optional `target`. Successful Journey links
record under the step identity before `$journey_leg_completed`.

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

## Curated activity

| Internal source | Public activity |
| --- | --- |
| `$experience_shown` | `experienceShown` |
| `$experience_dismissed` | `experienceDismissed` |
| `$experience_errored` | `experienceErrored` |
| `$journey_leg_started` | `journeyStarted` |
| `$journey_leg_completed` | `journeyCompleted` |
| `$journey_milestone` | `milestoneReached` |
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

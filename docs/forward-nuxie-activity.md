# Forward Nuxie activity to your analytics tool

Nuxie exposes a curated activity stream through `NuxieDelegate`. Each callback
is delivered on the main actor after the source event is durably captured.
Delivery is FIFO and at most once. Activity is not replayed when a delegate is
attached late, so assign the delegate before calling `setup(with:)`.

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

The same flat name and property view works with other analytics tools:

```swift
private extension NuxieActivityValue {
    var mixpanelValue: MixpanelType {
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
    var mixpanelProperties: Properties { mapValues(\.mixpanelValue) }
}

Mixpanel.mainInstance().track(event: info.name, properties: info.properties.mixpanelProperties)
PostHogSDK.shared.capture(info.name, properties: info.properties.analyticsProperties)
```

`NuxieActivityValue` is a JSON-safe scalar enum. Convert its `string`, `int`,
`double`, and `bool` cases to the value type accepted by your analytics SDK.
Arrays in the typed activity, such as unavailable product identifiers, appear
as comma-joined strings in the flat property view.

Use `info.id` as an idempotency key if your destination supports one.
`info.timestamp` records when the activity happened. `info.receivedAt` records
when this device learned of it, which can be later for server conversion facts.
For exhaustive Swift handling, switch over `info.activity` and include an
`@unknown default` branch.

## Curated activity

Internal protocol, identity, and response-control events never reach this
delegate. The public mapping is:

| Internal source | Public activity |
| --- | --- |
| `$experience_shown` | `experienceShown` |
| `$experience_dismissed` | `experienceDismissed` |
| `$experience_errored` | `experienceErrored` |
| `$journey_enrolled` | `journeyStarted` |
| `$journey_milestone` | `milestoneReached` |
| `$journey_converted` | `journeyConverted` |
| `$journey_exited`, `$journey_superseded` | `journeyEnded` |
| `$purchase_completed` | `purchaseCompleted` |
| `$purchase_failed` | `purchaseFailed` |
| `$purchase_cancelled` | `purchaseCancelled` |
| `$purchase_pending` | `purchasePending` |
| `$purchase_synced` | `purchaseSynced` |
| `$restore_completed` | `restoreCompleted` |
| `$restore_failed` | `restoreFailed` |
| `$restore_no_purchases` | `restoreNoPurchases` |
| `$feature_used` | `featureUsed` |
| `$experiment_exposure` | `experimentExposure` |
| `$experiment_exposure_error` | `experimentError` |
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

The following source events are intentionally hidden: App Action, customer
update, authored event, successful artifact load, experiment fallback,
identify, journey ownership/effect/checkpoint/transition protocol facts,
retired journey-start control, and local response state. Run App Action uses
the separate `nuxie(_:didRequestAppAction:)` delegate callback described in
[Run App Action](run-app-action.md).

## Filtering

`beforeSend` governs ordinary capture, including lifecycle, presentation,
commerce, permission, and designer-authored events. Returning `nil` suppresses
the wire event, history row, and activity callback together. Renaming an event
does not change its public activity case. Journey protocol facts and server
down-facts are not passed through `beforeSend`.

Pending events may be retried to Nuxie's servers after restart, but retries do
not replay `nuxieDidEmit`. A process exit between durable capture and callback
can lose the callback, which is why the contract is at most once rather than
guaranteed delivery.

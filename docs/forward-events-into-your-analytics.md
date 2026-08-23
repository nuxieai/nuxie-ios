# Forward Nuxie Activity to Your Analytics Tool

Nuxie can expose a curated, low-noise stream of SDK activity to the host app.
Set a `NuxieDelegate` and forward the analytics-ready name and properties to
your provider:

```swift
@MainActor
final class AnalyticsForwarder: NuxieDelegate {
    func nuxieDidEmit(_ info: NuxieActivityInfo) {
        analytics.track(
            name: info.name,
            properties: info.properties.analyticsDictionary
        )
    }
}

let forwarder = AnalyticsForwarder()
NuxieSDK.shared.delegate = forwarder // The SDK holds this weakly.
```

Retain the delegate and assign it before `setup(with:)` if you want lifecycle
activity. Nuxie does not replay captures that occurred before a delegate was
attached.

The provider call is intentionally ordinary. For example:

```swift
Amplitude.instance().logEvent(info.name, withEventProperties: info.properties.analyticsDictionary)
Mixpanel.mainInstance().track(event: info.name, properties: info.properties.analyticsDictionary)
PostHogSDK.shared.capture(info.name, properties: info.properties.analyticsDictionary)
```

`NuxieActivityInfo.activity` is a non-frozen `NuxieActivity` enum for hosts
that prefer typed switching. Include `@unknown default` in switches so newly
added cases remain source-compatible. `name` is the stable snake-case wire name, and
`properties` is a flat `[String: NuxieActivityValue]` containing only string,
integer, double, and boolean values. `id` is the captured event's UUID and can
be used as the downstream idempotency key. `timestamp` records when the
activity happened; `receivedAt` differs only when the device learns about a
server conversion later.

The callback runs on the main actor and preserves durable capture order. It is
observational: it does not replace Nuxie's own delivery. A capture dropped by
`NuxieConfiguration.beforeSend` produces no callback. If that hook renames an
event, the persisted Nuxie event uses the renamed value while the typed
activity keeps its original classification. Pending events restored after an
app relaunch are delivered to Nuxie but are not replayed to this callback.

The complete curation policy is below. Several internal events intentionally
converge on one public case; events in the hidden rows never invoke the
activity callback. Run App Action requests use their dedicated delegate
method instead.

| Internal event | Public `NuxieActivity` case |
| --- | --- |
| `$experience_shown` | `experienceShown` |
| `$experience_dismissed` | `experienceDismissed` |
| `$experience_purchased` | `experienceDismissed` with reason `purchase` |
| `$experience_timed_out` | `experienceTimedOut` |
| `$experience_errored` | `experienceErrored` |
| `$experience_artifact_load_failed` | `experienceLoadFailed` |
| `$journey_enrolled` | `journeyStarted` |
| `$journey_milestone` | `milestoneReached` |
| `$journey_converted` | `journeyConverted` |
| `$journey_exited` | `journeyEnded` |
| `$purchase_completed` | `purchaseCompleted` |
| `$purchase_failed` | `purchaseFailed` |
| `$purchase_cancelled` | `purchaseCancelled` |
| `$purchase_pending` | `purchasePending` |
| `$purchase_synced` | `purchaseSynced` |
| `$restore_completed` | `restoreCompleted` |
| `$restore_failed` | `restoreFailed` |
| `$restore_no_purchases` | `restoreNoPurchases` |
| `$feature_used` | `featureUsed` |
| `$experiment_exposure`, `$experiment_exposure_fallback` | `experimentExposure` (`isFallback` distinguishes them) |
| `$experiment_exposure_error` | `experimentError` |
| `$products_unavailable` | `productsUnavailable` |
| `$screen_shown` | `screenShown` |
| `$screen_dismissed` | `screenDismissed` |
| `$notifications_enabled` | `permissionResolved` with kind `notifications`, granted `true` |
| `$notifications_denied` | `permissionResolved` with kind `notifications`, granted `false` |
| `$permission_granted` | `permissionResolved` with kind `other`, granted `true` |
| `$permission_denied` | `permissionResolved` with kind `other`, granted `false` |
| `$tracking_authorized` | `permissionResolved` with kind `tracking`, granted `true` |
| `$tracking_denied` | `permissionResolved` with kind `tracking`, granted `false` |
| `$app_installed` | `appInstalled` |
| `$app_updated` | `appUpdated` |
| `$app_opened` | `appOpened` |
| `$app_backgrounded` | `appBackgrounded` |
| Hidden identity, control, and response events: `$identify`, `$journey_started`, `$response_set`, `$response_unset` | Hidden |
| Hidden journey protocol facts: `$journey_transition`, `$journey_effect_requested`, `$journey_effect_completed`, `$journey_claimed`, `$journey_handoff`, `$journey_parked`, `$journey_superseded` | Hidden |
| Hidden internal riders: `$experience_artifact_load_succeeded`, `$customer_updated`, `$event_sent`, `$app_action_requested` | Hidden |

The cross-SDK wire contract is versioned by
`NuxieActivityInfo.schemaVersion` and pinned in
`fixtures/encodings/forwarded-activity.json`.

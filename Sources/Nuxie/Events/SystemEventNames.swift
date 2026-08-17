import Foundation

/// Canonical names for `$`-prefixed system events and runtime controls.
/// Durable journey observability facts live in `JourneyEvents`; runtime
/// control inputs such as `$journey_started` live here.
///
/// Naming convention: `$<domain>_<past_tense_verb>` with snake_case
/// property keys. All `$`-event emissions must reference these constants
/// (or `JourneyEvents`) — no bare string literals at emitter sites.
/// The full catalog (when each fires, properties, delivery guarantees)
/// lives in `docs/sdk-events.md`.
enum SystemEventNames {
    // Identity
    static let identify = "$identify"

    // App lifecycle
    static let appInstalled = "$app_installed"
    static let appUpdated = "$app_updated"
    static let appOpened = "$app_opened"
    static let appBackgrounded = "$app_backgrounded"

    // Journey runtime control (an input, not a durable lifecycle fact)
    static let journeyStarted = "$journey_started"
    /// Authored pre-presentation branch when required live store products
    /// cannot be resolved. No commercial renderer has been attached yet.
    static let productsUnavailable = "$products_unavailable"

    // Feature gating / metered usage (backend-ingested by name)
    static let featureUsed = "$feature_used"

    // Screens
    static let screenShown = "$screen_shown"
    static let screenDismissed = "$screen_dismissed"

    // Purchases / restores
    static let purchaseCompleted = "$purchase_completed"
    static let purchaseFailed = "$purchase_failed"
    static let purchaseCancelled = "$purchase_cancelled"
    static let purchasePending = "$purchase_pending"
    static let purchaseSynced = "$purchase_synced"
    static let restoreCompleted = "$restore_completed"
    static let restoreFailed = "$restore_failed"
    static let restoreNoPurchases = "$restore_no_purchases"

    // Permissions
    static let notificationsEnabled = "$notifications_enabled"
    static let notificationsDenied = "$notifications_denied"
    static let permissionGranted = "$permission_granted"
    static let permissionDenied = "$permission_denied"
    static let trackingAuthorized = "$tracking_authorized"
    static let trackingDenied = "$tracking_denied"

    // Response collection
    static let responseSet = "$response_set"
}

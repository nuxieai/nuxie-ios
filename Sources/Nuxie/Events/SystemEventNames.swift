import Foundation

enum SystemEventNames {
    static let screenShown = "$screen_shown"
    static let screenDismissed = "$screen_dismissed"
    static let purchaseCompleted = "$purchase_completed"
    static let purchaseFailed = "$purchase_failed"
    static let purchaseCancelled = "$purchase_cancelled"
    static let restoreCompleted = "$restore_completed"
    static let restoreFailed = "$restore_failed"
    static let restoreNoPurchases = "$restore_no_purchases"
    static let notificationsEnabled = "$notifications_enabled"
    static let notificationsDenied = "$notifications_denied"
    static let permissionGranted = "$permission_granted"
    static let permissionDenied = "$permission_denied"
    static let trackingAuthorized = "$tracking_authorized"
    static let trackingDenied = "$tracking_denied"
    static let responseSet = "$response_set"
}

import Foundation

/// Delegate protocol for receiving Nuxie SDK callbacks
///
/// Implement this protocol to receive notifications about SDK events.
/// All methods are optional - implement only the ones you need.
///
/// ```swift
/// class AppDelegate: NuxieDelegate {
///     func featureAccessDidChange(_ featureId: String, from oldValue: FeatureAccess?, to newValue: FeatureAccess) {
///         print("Feature \(featureId) changed: \(newValue.allowed)")
///     }
/// }
///
/// // Set the delegate
/// NuxieSDK.shared.delegate = appDelegate
/// ```
@MainActor
public protocol NuxieDelegate: AnyObject {

    /// Called when a feature's access status changes
    ///
    /// This is triggered after:
    /// - Feature checks via `hasFeature()`
    /// - Profile refresh (on app foreground or manual refresh)
    /// - User identity changes
    ///
    /// - Parameters:
    ///   - featureId: The feature identifier that changed
    ///   - oldValue: Previous access state (nil if feature was not previously cached)
    ///   - newValue: New access state
    func featureAccessDidChange(_ featureId: String, from oldValue: FeatureAccess?, to newValue: FeatureAccess)

    /// Called once for each curated Nuxie activity after durable capture.
    ///
    /// Activities arrive in capture order. This callback is observational;
    /// use `NuxieConfiguration.beforeSend` to filter or transform events.
    func nuxieDidEmit(_ info: NuxieActivityInfo)

    /// Called when an experience's Run App Action step asks the host app to act.
    func nuxie(_ sdk: NuxieSDK, didRequestAppAction action: AppAction)
}

// MARK: - Default Implementations

public extension NuxieDelegate {
    func featureAccessDidChange(_ featureId: String, from oldValue: FeatureAccess?, to newValue: FeatureAccess) {}
    func nuxieDidEmit(_ info: NuxieActivityInfo) {}
    func nuxie(_ sdk: NuxieSDK, didRequestAppAction action: AppAction) {}
}

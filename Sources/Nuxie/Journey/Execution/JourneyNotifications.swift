import Foundation

extension Notification.Name {
    /// Posted when a purchase action is executed
    static let nuxiePurchase = Notification.Name("com.nuxie.purchase")
    /// Posted when a restore action is executed
    static let nuxieRestore = Notification.Name("com.nuxie.restore")
    /// Posted when an open link action is executed
    static let nuxieOpenLink = Notification.Name("com.nuxie.openLink")
    /// Posted when a dismiss action is executed
    static let nuxieDismiss = Notification.Name("com.nuxie.dismiss")
    /// Posted when a back action is executed
    static let nuxieBack = Notification.Name("com.nuxie.back")
}

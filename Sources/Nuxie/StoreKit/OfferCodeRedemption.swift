import StoreKit

#if canImport(UIKit)
import UIKit

public extension NuxieSDK {
    /// Presents Apple's system offer-code redemption UI.
    @MainActor
    func presentOfferCodeRedemption(in scene: UIWindowScene) async throws {
        if #available(iOS 16.0, *) {
            try await AppStore.presentOfferCodeRedeemSheet(in: scene)
        } else {
            SKPaymentQueue.default().presentCodeRedemptionSheet()
        }
    }
}
#elseif canImport(AppKit)
import AppKit

public extension NuxieSDK {
    /// Presents Apple's system offer-code redemption UI.
    @MainActor
    func presentOfferCodeRedemption(from controller: NSViewController) async throws {
        if #available(macOS 15.0, *) {
            try await AppStore.presentOfferCodeRedeemSheet(from: controller)
        } else {
            throw StoreKitError.storeKitNotAvailable
        }
    }
}
#endif

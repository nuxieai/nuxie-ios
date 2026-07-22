import Foundation

/// Projects purchase/restore lifecycle onto the paywall capability
/// view-model paths (`paywall/purchase/*`, `paywall/restore/*`).
///
/// Data-in/data-out: event name + properties in, an ordered list of
/// path/value writes out. The only state is the active invocation-id pair
/// correlating a begin with its async outcome (single-active-invocation
/// model). The runner applies the writes to the view model.
struct PaywallStatusProjector {
    struct Write: Equatable {
        let path: String
        let value: String
    }

    private let makeInvocationId: () -> String
    private(set) var activePurchaseInvocationId: String?
    private(set) var activeRestoreInvocationId: String?

    init(makeInvocationId: @escaping () -> String = { UUID().uuidString }) {
        self.makeInvocationId = makeInvocationId
    }

    mutating func beginPurchase() -> [Write] {
        let invocationId = makeInvocationId()
        activePurchaseInvocationId = invocationId
        return Self.purchaseWrites(status: "running", errorCode: "", invocationId: invocationId)
    }

    mutating func beginRestore() -> [Write] {
        let invocationId = makeInvocationId()
        activeRestoreInvocationId = invocationId
        return Self.restoreWrites(status: "running", errorCode: "", invocationId: invocationId)
    }

    /// Writes for a purchase/restore outcome event; empty when the event is
    /// not a paywall outcome.
    mutating func project(eventName: String, properties: [String: Any]) -> [Write] {
        switch eventName {
        case SystemEventNames.purchaseCompleted:
            let writes = Self.purchaseWrites(
                status: "success",
                errorCode: "",
                invocationId: activePurchaseInvocationId ?? makeInvocationId()
            )
            activePurchaseInvocationId = nil
            return writes
        case SystemEventNames.purchaseFailed:
            let writes = Self.purchaseWrites(
                status: "error",
                errorCode: Self.errorCode(from: properties),
                invocationId: activePurchaseInvocationId ?? makeInvocationId()
            )
            activePurchaseInvocationId = nil
            return writes
        case SystemEventNames.purchaseCancelled:
            let writes = Self.purchaseWrites(
                status: "cancelled",
                errorCode: "",
                invocationId: activePurchaseInvocationId ?? makeInvocationId()
            )
            activePurchaseInvocationId = nil
            return writes
        case SystemEventNames.purchasePending:
            // Ask-to-Buy / SCA: reflect the deferred state instead of leaving
            // the paywall stuck on "running". The invocation stays active so
            // the eventual outcome still resolves it.
            return Self.purchaseWrites(
                status: "pending",
                errorCode: "",
                invocationId: activePurchaseInvocationId ?? makeInvocationId()
            )
        case SystemEventNames.restoreCompleted:
            let writes = Self.restoreWrites(
                status: "success",
                errorCode: "",
                invocationId: activeRestoreInvocationId ?? makeInvocationId()
            )
            activeRestoreInvocationId = nil
            return writes
        case SystemEventNames.restoreFailed:
            let writes = Self.restoreWrites(
                status: "error",
                errorCode: Self.errorCode(from: properties),
                invocationId: activeRestoreInvocationId ?? makeInvocationId()
            )
            activeRestoreInvocationId = nil
            return writes
        case SystemEventNames.restoreNoPurchases:
            let writes = Self.restoreWrites(
                status: "not_found",
                errorCode: "",
                invocationId: activeRestoreInvocationId ?? makeInvocationId()
            )
            activeRestoreInvocationId = nil
            return writes
        default:
            return []
        }
    }

    static func errorCode(from properties: [String: Any]) -> String {
        for key in ["error_code", "errorCode", "code", "error"] {
            if let value = properties[key] as? String, !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func purchaseWrites(
        status: String,
        errorCode: String,
        invocationId: String
    ) -> [Write] {
        [
            Write(path: "paywall/purchase/status", value: status),
            Write(path: "paywall/purchase/errorCode", value: errorCode),
            Write(path: "paywall/purchase/invocationId", value: invocationId),
        ]
    }

    private static func restoreWrites(
        status: String,
        errorCode: String,
        invocationId: String
    ) -> [Write] {
        [
            Write(path: "paywall/restore/status", value: status),
            Write(path: "paywall/restore/errorCode", value: errorCode),
            Write(path: "paywall/restore/invocationId", value: invocationId),
        ]
    }
}

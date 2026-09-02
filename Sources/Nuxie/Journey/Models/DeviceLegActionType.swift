import Foundation

/// The authenticated local-program operation vocabulary. Decoding the wire
/// string once keeps validation, ownership, dispatch, and outcome correlation
/// on the same closed set.
enum DeviceLegActionType: String, Codable, CaseIterable, Sendable {
    enum ExecutionOwner: Equatable, Sendable {
        case control
        case presentation
        case device
        case server
    }

    case condition
    case experiment
    case timeWindow = "time_window"
    case delay
    case waitUntil = "wait_until"

    case navigate
    case back
    case purchase
    case restore
    case requestNotifications = "request_notifications"
    case requestPermission = "request_permission"
    case requestTracking = "request_tracking"
    case openLink = "open_link"
    case dismiss

    case sendEvent = "send_event"
    case updateCustomer = "update_customer"
    case milestone
    case submitResponse = "submit_response"
    case appAction = "app_action"
    case exit

    case connectorAction = "connector_action"
    case grantEntitlement = "grant_entitlement"
    case deviceAvailable = "device_available"

    init?(action: [String: ExperienceReleaseJSONValue]) {
        guard let rawValue = Self.rawValue(in: action) else { return nil }
        self.init(rawValue: rawValue)
    }

    static func rawValue(
        in action: [String: ExperienceReleaseJSONValue]
    ) -> String? {
        guard case .string(let rawValue)? = action["type"] else { return nil }
        return rawValue
    }

    var executionOwner: ExecutionOwner {
        switch self {
        case .condition, .experiment, .timeWindow, .delay, .waitUntil:
            return .control
        case .navigate, .back, .purchase, .restore, .requestNotifications,
             .requestPermission, .requestTracking, .openLink, .dismiss:
            return .presentation
        case .sendEvent, .updateCustomer, .milestone, .submitResponse,
             .appAction, .exit:
            return .device
        case .connectorAction, .grantEntitlement, .deviceAvailable:
            return .server
        }
    }

    var isPresentationOwned: Bool {
        executionOwner == .presentation
    }

    var isCommerce: Bool {
        self == .purchase || self == .restore
    }

    static func presentationOutcomeRoute(
        eventName: String
    ) -> (actionType: Self, outlet: String)? {
        switch eventName {
        case SystemEventNames.purchaseCompleted:
            return (.purchase, "completed")
        case SystemEventNames.purchaseFailed:
            return (.purchase, "failed")
        case SystemEventNames.purchaseCancelled:
            return (.purchase, "cancelled")
        case SystemEventNames.restoreCompleted:
            return (.restore, "restored")
        case SystemEventNames.restoreFailed:
            return (.restore, "failed")
        case SystemEventNames.restoreNoPurchases:
            return (.restore, "noPurchases")
        default:
            return nil
        }
    }
}

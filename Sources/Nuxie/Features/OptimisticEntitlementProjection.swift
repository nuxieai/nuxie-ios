import Foundation

struct OptimisticPurchaseEvidence: Equatable, Sendable {
    let transactionId: String
    let distinctId: String
    let backendSynced: Bool
    let revoked: Bool
}

struct OptimisticEntitlementAllowance: Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case boolean
        case metered
        case creditSystem = "credit_system"
    }

    let featureId: String
    let kind: Kind
    let unlimited: Bool
    let allowance: Double?

    init(
        featureId: String,
        kind: Kind,
        unlimited: Bool,
        allowance: Double?
    ) {
        self.featureId = featureId
        self.kind = kind
        self.unlimited = unlimited
        self.allowance = allowance
    }

    init(
        featureId: String,
        featureExternalId: String?,
        allowanceType: String?,
        allowance: Double?
    ) {
        let normalizedType = allowanceType?.lowercased()
        self.featureId = featureExternalId ?? featureId
        self.unlimited = normalizedType == "unlimited"
        self.kind = switch normalizedType {
        case nil, "boolean", "unlimited": .boolean
        case "credits", "credit_system": .creditSystem
        default: .metered
        }
        self.allowance = allowance
    }
}

struct OptimisticEntitlementOverlay: Equatable, Sendable {
    let kind: OptimisticEntitlementAllowance.Kind
    let unlimited: Bool
    let allowance: Double?
}

enum OptimisticEntitlementProjection {
    static func derive(
        evidence: [OptimisticPurchaseEvidence]?,
        descriptorAllowances: [String: [OptimisticEntitlementAllowance]]?,
        distinctId: String
    ) -> [String: OptimisticEntitlementOverlay]? {
        guard let evidence, !evidence.isEmpty else { return nil }
        let activeEvidence = evidence.filter {
            $0.distinctId == distinctId && !$0.backendSynced && !$0.revoked
        }
        guard !activeEvidence.isEmpty, let descriptorAllowances else {
            return nil
        }

        var projection: [String: OptimisticEntitlementOverlay] = [:]
        for purchase in activeEvidence {
            guard let allowances = descriptorAllowances[purchase.transactionId],
                  !allowances.isEmpty else {
                // Projection inputs are incomplete, so absence is the only
                // truthful result. An empty overlay would claim that the
                // descriptor authoritatively grants nothing.
                return nil
            }
            for allowance in allowances where !allowance.featureId.isEmpty {
                projection[allowance.featureId] = joining(
                    projection[allowance.featureId],
                    with: allowance
                )
            }
        }
        return projection.isEmpty ? nil : projection
    }

    private static func joining(
        _ current: OptimisticEntitlementOverlay?,
        with allowance: OptimisticEntitlementAllowance
    ) -> OptimisticEntitlementOverlay {
        let incoming = OptimisticEntitlementOverlay(
            kind: allowance.kind,
            unlimited: allowance.unlimited,
            allowance: allowance.kind == .boolean || allowance.unlimited
                ? nil
                : max(0, allowance.allowance ?? 0)
        )
        guard let current else { return incoming }
        if current.unlimited || incoming.unlimited {
            return OptimisticEntitlementOverlay(
                kind: current.kind,
                unlimited: true,
                allowance: nil
            )
        }
        if current.kind == .boolean || incoming.kind == .boolean {
            return OptimisticEntitlementOverlay(
                kind: .boolean,
                unlimited: false,
                allowance: nil
            )
        }
        return OptimisticEntitlementOverlay(
            kind: current.kind,
            unlimited: false,
            allowance: (current.allowance ?? 0) + (incoming.allowance ?? 0)
        )
    }
}

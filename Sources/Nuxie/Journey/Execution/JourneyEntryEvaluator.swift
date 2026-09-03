import Foundation

struct JourneyFactReferences {
    let propertyKeys: [String]
    let segmentIds: [String]
    let experimentIds: [String]
}

/// The presence tag distinguishes an explicitly absent property from a fact
/// the device has not fetched. Only the former may satisfy a negative gate.
struct JourneyFactTable {
    struct Property {
        let present: Bool
        let value: AnyCodable?

    }

    struct Assignment {
        let variantId: String
        let isHoldout: Bool
    }

    let properties: ExactJSONObject<Property>
    let memberships: ExactJSONObject<Bool>
    let assignments: ExactJSONObject<Assignment?>
}

struct JourneyEntryCondition {
    enum Kind: String {
        case event
        case segment
        case appForegrounded = "app_foregrounded"
    }
    let type: Kind
    let eventName: String?
    let segmentId: String?
    let member: Bool?
    let condition: IREnvelope?
}

/// Stateless evaluation against the caller's current foreground state and fact
/// snapshot. Arrival and ordinary events use this same entry point; fetching
/// never clears the app-open latch and this module never captures an event.
enum JourneyEntryEvaluator {
    static func matches(
        _ entry: JourneyEntryCondition,
        facts: JourneyFactTable,
        references: JourneyFactReferences,
        foreground: Bool,
        event: NuxieEvent?,
        now: Date,
        events: IREventQueries? = nil,
        features: IRFeatureQueries? = nil
    ) async -> Bool {
        guard references.propertyKeys.allSatisfy({ facts.properties[$0] != nil }),
              references.segmentIds.allSatisfy({ facts.memberships[$0] != nil }) else { return false }
        switch entry.type {
        case .appForegrounded:
            guard foreground else { return false }
        case .event:
            guard let name = entry.eventName, event?.name == name else { return false }
        case .segment:
            guard let id = entry.segmentId, let wanted = entry.member,
                  let membership = facts.memberships[id], membership == wanted else { return false }
        }
        guard let condition = entry.condition else { return true }
        guard condition.ir_version == 1, condition.isSupportedByThisEngine else { return false }
        let available = FactsAvailability(facts: facts, hasEvent: event != nil, hasEvents: events != nil, hasFeatures: features != nil)
        guard available.contains(condition.expr) else { return false }
        do {
            return try await IRInterpreter(ctx: EvalContext(
                now: now, user: PropertySnapshot(facts: facts), events: events,
                segments: MembershipSnapshot(facts: facts), features: features, event: event
            )).evalBool(condition.expr)
        } catch {
            // Retained-history gaps and failed query reads stay unknown even
            // inside negation; no alternate local segment evaluation exists.
            return false
        }
    }

    fileprivate struct PropertySnapshot {
        let facts: JourneyFactTable
    }

    fileprivate struct MembershipSnapshot {
        let facts: JourneyFactTable
    }

    /// The interpreter returns false for unsupported inputs. A proof before
    /// evaluation prevents negation from turning those inputs into true.
    private struct FactsAvailability {
        let facts: JourneyFactTable
        let hasEvent: Bool
        let hasEvents: Bool
        let hasFeatures: Bool

        private static let propertyOps: Set<String> = [
            "has", "eq", "neq", "icontains", "regex", "gt", "gte", "lt", "lte",
            "is_set", "is_not_set", "is_date_exact", "is_date_after", "is_date_before", "in", "not_in",
        ]
        private static let featureOps: Set<String> = [
            "has", "not_has", "is_unlimited", "credits_eq", "credits_neq", "credits_gt",
            "credits_gte", "credits_lt", "credits_lte",
        ]

        private func containsPredicate(_ expression: IRExpr?) -> Bool {
            guard let expression else { return true }
            switch expression {
            case .pred(let op, _, _) where op == "has":
                // PredicateEval has no `has` alias. Treat it as unavailable,
                // rather than letting a negative occurrence query authorize.
                return false
            case .predAnd(let children), .predOr(let children):
                return children.allSatisfy { containsPredicate($0) }
            case .pred: break
            default: return false
            }
            // A history query supplies its own event for each predicate call.
            return FactsAvailability(facts: facts, hasEvent: true, hasEvents: hasEvents, hasFeatures: hasFeatures)
                .contains(expression)
        }

        func contains(_ optional: IRExpr?) -> Bool { optional.map(contains) ?? true }

        func contains(_ expression: IRExpr) -> Bool {
            switch expression {
            case .unknown, .journeyId, .responseField:
                return false
            case .bool, .number, .string, .timestamp, .duration, .timeNow, .timeWindow:
                return true
            case .list(let children), .and(let children), .or(let children):
                return children.allSatisfy(contains)
            case .predAnd(let children), .predOr(let children):
                return hasEvent && children.allSatisfy(contains)
            case .not(let child), .timeAgo(let child):
                return contains(child)
            case .compare(let op, let left, let right):
                return ["==", "!=", "<", "<=", ">", ">=", "in", "not_in"].contains(op) && contains(left) && contains(right)
            case .user(let op, let key, let value):
                return Self.propertyOps.contains(op) && facts.properties[key] != nil && contains(value)
            case .event(let op, _, let value):
                return Self.propertyOps.contains(op) && hasEvent && contains(value)
            case .pred(let op, _, let value):
                return Self.propertyOps.contains(op) && hasEvent && contains(value)
            case .feature(let op, _, let value):
                return Self.featureOps.contains(op) && hasFeatures && contains(value)
            case .segment(let op, let id, _):
                return ["is_member", "not_member", "in", "not_in"].contains(op) && facts.memberships[id] != nil
            case .eventsExists(_, let since, let until, let within, let predicate),
                 .eventsCount(_, let since, let until, let within, let predicate):
                return hasEvents && [since, until, within].allSatisfy(contains) && containsPredicate(predicate)
            case .eventsFirstTime(_, let predicate), .eventsLastTime(_, let predicate), .eventsLastAge(_, let predicate):
                return hasEvents && containsPredicate(predicate)
            case .eventsAggregate(let op, _, _, let since, let until, let within, let predicate):
                return ["sum", "avg", "min", "max", "unique"].contains(op) && hasEvents && [since, until, within].allSatisfy(contains) && containsPredicate(predicate)
            case .eventsInOrder(let steps, let overall, let perStep, let since, let until):
                return hasEvents && steps.allSatisfy { containsPredicate($0.where_) } && [overall, perStep, since, until].allSatisfy(contains)
            case .eventsActivePeriods(_, _, _, _, let predicate):
                return hasEvents && containsPredicate(predicate)
            case .eventsStopped(_, let inactive, let predicate):
                return hasEvents && contains(inactive) && containsPredicate(predicate)
            case .eventsRestarted(_, let inactive, let within, let predicate):
                return hasEvents && contains(inactive) && contains(within) && containsPredicate(predicate)
            }
        }
    }
}

extension JourneyFactReferences: Codable, Sendable {}
extension JourneyFactTable: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case properties, memberships, assignments
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        properties = try values.decode(ExactJSONObject<Property>.self, forKey: .properties)
        memberships = try values.decode(ExactJSONObject<Bool>.self, forKey: .memberships)

        let delivered = try values.decode(
            ExactJSONObject<JourneyReleaseJSONValue>.self,
            forKey: .assignments
        )
        var normalized = ExactJSONObject<Assignment?>()
        for (key, value) in delivered where !key.isEmpty && key.utf16.count <= 256 {
            normalized[key] = .some(Self.assignment(from: value))
        }
        assignments = normalized
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(properties, forKey: .properties)
        try values.encode(memberships, forKey: .memberships)
        try values.encode(assignments, forKey: .assignments)
    }

    private static func assignment(
        from value: JourneyReleaseJSONValue
    ) -> Assignment? {
        guard case .object(let object) = value,
              object.count == 2,
              case .string(let variantId)? = object["variantId"],
              !variantId.isEmpty,
              variantId.utf16.count <= 256,
              case .bool(let isHoldout)? = object["isHoldout"] else {
            return nil
        }
        return Assignment(variantId: variantId, isHoldout: isHoldout)
    }
}
extension JourneyFactTable.Assignment: Codable, Sendable {}
extension JourneyEntryCondition: Codable, Sendable {}
extension JourneyEntryCondition.Kind: Codable, Hashable, Sendable {}
extension JourneyFactTable.Property: Codable, Sendable {
    private enum CodingKeys: String, CodingKey { case present, value }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        present = try values.decode(Bool.self, forKey: .present)
        guard present == values.contains(.value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "fact presence must match its value"))
        }
        value = present ? try values.decode(AnyCodable.self, forKey: .value) : nil
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(present, forKey: .present)
        if present { try values.encode(value, forKey: .value) }
    }
}

extension JourneyEntryEvaluator.PropertySnapshot: IRUserProps {
    func userProperty(for key: String) async -> Any? { facts.properties[key]?.value?.value }
}

extension JourneyEntryEvaluator.MembershipSnapshot: IRSegmentQueries {
    func isMember(_ segmentId: String) async -> Bool { facts.memberships[segmentId] == true }
    func enteredAt(_ segmentId: String) async -> Date? { nil }
}

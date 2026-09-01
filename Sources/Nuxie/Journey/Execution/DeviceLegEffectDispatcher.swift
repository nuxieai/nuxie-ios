import Foundation

struct DeviceLegProfileFenceToken: Equatable, Sendable {
    let generation: UInt64
}

/// Linearizes same-identity profile replacement with short local publication
/// windows. Async event commits still check the token before and after their
/// durable capture.
final class DeviceLegProfileFence: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0

    func advance() -> UInt64 {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    func token(ifCurrent expectedGeneration: UInt64) -> DeviceLegProfileFenceToken? {
        lock.withLock {
            guard generation == expectedGeneration else { return nil }
            return DeviceLegProfileFenceToken(generation: generation)
        }
    }

    func isCurrent(_ token: DeviceLegProfileFenceToken) -> Bool {
        lock.withLock { generation == token.generation }
    }

    @discardableResult
    func publishIfCurrent(
        _ token: DeviceLegProfileFenceToken,
        _ publication: () -> Void
    ) -> Bool {
        lock.withLock {
            guard generation == token.generation else { return false }
            publication()
            return generation == token.generation
        }
    }
}

struct DeviceLegDispatchRequest: Sendable {
    let runId: String
    let journeyId: String
    let generation: Int
    let reference: ArmedDeviceLeg.Reference
    let release: AuthenticatedDeviceLegRelease
    let stepId: String
    let action: [String: ExperienceReleaseJSONValue]
    let context: ArmedDeviceLeg.Context
    let effectId: String
    let distinctId: String
    let identityFence: IdentityFenceToken
    let profileFence: DeviceLegProfileFence
    let profileFenceToken: DeviceLegProfileFenceToken
}

enum DeviceLegDispatchResult: Equatable, Sendable {
    case outlet(String)
    case complete(String)
    case unsupported
    case failed
}

protocol DeviceLegDispatching: Sendable {
    func dispatch(_ request: DeviceLegDispatchRequest) async -> DeviceLegDispatchResult
}

/// Executes authenticated local effects after DeviceLegRunJournal has made
/// their stable identity durable. Presentation and commerce remain parked at
/// this seam until their artifact-backed adapters are installed.
struct DeviceLegEffectDispatcher: DeviceLegDispatching {
    private let identity: IdentityServiceProtocol
    private let events: any RoutedStableSystemEventCapturing
    private let appActionHandler: @MainActor @Sendable (AppAction) -> Void

    init(
        identity: IdentityServiceProtocol,
        events: any RoutedStableSystemEventCapturing,
        appActionHandler: @escaping @MainActor @Sendable (AppAction) -> Void = { _ in }
    ) {
        self.identity = identity
        self.events = events
        self.appActionHandler = appActionHandler
    }

    func dispatch(_ request: DeviceLegDispatchRequest) async -> DeviceLegDispatchResult {
        guard await requestIsCurrent(request),
              case .string(let type)? = request.action["type"] else {
            return .failed
        }
        switch type {
        case "send_event":
            return await sendEvent(request)
        case "update_customer":
            return await updateCustomer(request)
        case "milestone":
            return await milestone(request)
        case "submit_response":
            return .outlet("next")
        case "app_action":
            return await appAction(request)
        case "exit":
            guard let action = decode(Exit.self, request.action) else { return .failed }
            if let reason = action.reason {
                return reason.isEmpty ? .failed : .complete(reason)
            }
            return .complete("completed")
        default:
            return .unsupported
        }
    }

    private func sendEvent(
        _ request: DeviceLegDispatchRequest
    ) async -> DeviceLegDispatchResult {
        guard let action = decode(SendEvent.self, request.action),
              let payload = resolve(action.payload ?? [:], context: request.context) else {
            return .failed
        }
        var properties = payload
        properties["journey_id"] = request.journeyId
        properties["experience_id"] = request.reference.experienceId
        properties["experience_version_id"] = request.reference.versionId
        properties["leg_id"] = request.reference.legId
        properties["leg_generation"] = request.generation
        guard let capture = await events.captureSystemEvent(
                action.eventName,
                properties: properties,
                eventId: request.effectId,
                distinctId: request.distinctId
              ),
              await requestIsCurrent(request) else {
            return .failed
        }
        await events.routeCapturedSystemEvent(capture)
        return await requestIsCurrent(request) ? .outlet("next") : .failed
    }

    private func updateCustomer(
        _ request: DeviceLegDispatchRequest
    ) async -> DeviceLegDispatchResult {
        guard let action = decode(UpdateCustomer.self, request.action),
              let attributes = resolve(action.attributes, context: request.context) else {
            return .failed
        }
        let attributeKeys = attributes.keys.sorted {
            $0.utf16.lexicographicallyPrecedes($1.utf16)
        }
        let attributesBox = UncheckedSendable(attributes)
        let updated = await MainActor.run {
            var identityUpdated = false
            let profileUpdated = request.profileFence.publishIfCurrent(
                request.profileFenceToken
            ) {
                identityUpdated = identity.publishIfCurrentIdentityFenceToken(
                    request.identityFence
                ) {
                    identity.setUserProperties(attributesBox.value)
                }
            }
            return profileUpdated && identityUpdated
        }
        guard updated else { return .failed }
        var properties = legAttribution(request)
        properties["attributes_updated"] = attributeKeys
        guard await captureRider(
            JourneyEvents.customerUpdated,
            properties: properties,
            request: request
        ) else { return .failed }
        return .outlet("next")
    }

    private func milestone(
        _ request: DeviceLegDispatchRequest
    ) async -> DeviceLegDispatchResult {
        guard let action = decode(Milestone.self, request.action) else { return .failed }
        var properties = legAttribution(request)
        properties["milestone_id"] = action.milestoneId
        guard let capture = await events.captureSystemEvent(
                JourneyEvents.journeyMilestone,
                properties: properties,
                eventId: request.effectId,
                distinctId: request.distinctId
              ),
              await requestIsCurrent(request) else {
            return .failed
        }
        await events.routeCapturedSystemEvent(capture)
        return await requestIsCurrent(request) ? .outlet("next") : .failed
    }

    private func appAction(
        _ request: DeviceLegDispatchRequest
    ) async -> DeviceLegDispatchResult {
        guard let action = decode(AppActionEffect.self, request.action),
              let payload = action.payload.flatMap({ resolve($0, context: request.context) })
                ?? (action.payload == nil ? [:] : nil) else {
            return .failed
        }
        let resolvedPayload = action.payload == nil
            ? nil
            : AppActionValue.resolvedRecord(payload)
        let value = AppAction(
            name: action.name,
            payload: resolvedPayload,
            experience: .init(
                experienceId: request.reference.experienceId,
                experienceVersion: request.reference.versionId,
                journeyId: request.journeyId
            )
        )
        let delivered = await MainActor.run {
            var identityDelivered = false
            let profileDelivered = request.profileFence.publishIfCurrent(
                request.profileFenceToken
            ) {
                identityDelivered = identity.publishIfCurrentIdentityFenceToken(
                    request.identityFence
                ) {
                    appActionHandler(value)
                }
            }
            return profileDelivered && identityDelivered
        }
        guard delivered else {
            return .failed
        }
        var properties = legAttribution(request)
        properties["name"] = action.name
        if action.payload != nil {
            properties["payload"] = AppActionValue.sanitizedRecord(payload)
        }
        guard await captureRider(
            JourneyEvents.appActionRequested,
            properties: properties,
            request: request
        ) else { return .failed }
        return .outlet("next")
    }

    private func captureRider(
        _ event: String,
        properties: sending [String: Any],
        request: DeviceLegDispatchRequest
    ) async -> Bool {
        guard let capture = await events.captureSystemEvent(
            event,
            properties: properties,
            eventId: request.effectId,
            distinctId: request.distinctId
        ), await requestIsCurrent(request) else { return false }
        await events.routeCapturedSystemEvent(capture)
        return await requestIsCurrent(request)
    }

    private func legAttribution(
        _ request: DeviceLegDispatchRequest
    ) -> [String: Any] {
        [
            "journey_id": request.journeyId,
            "experience_id": request.reference.experienceId,
            "experience_version_id": request.reference.versionId,
            "leg_id": request.reference.legId,
            "leg_generation": request.generation,
        ]
    }

    private func identityFenceIsCurrent(_ token: IdentityFenceToken) async -> Bool {
        await MainActor.run {
            identity.publishIfCurrentIdentityFenceToken(token) {}
        }
    }

    private func requestIsCurrent(_ request: DeviceLegDispatchRequest) async -> Bool {
        guard request.profileFence.isCurrent(request.profileFenceToken),
              await identityFenceIsCurrent(request.identityFence) else {
            return false
        }
        return request.profileFence.isCurrent(request.profileFenceToken)
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        _ action: [String: ExperienceReleaseJSONValue]
    ) -> Value? {
        try? ExactJSONCodec.decode(
            type,
            from: ExactJSONCodec.encode(
                ExperienceReleaseJSONValue.object(.init(action))
            )
        )
    }

    private func resolve(
        _ values: ExactJSONObject<JourneyValue>,
        context: ArmedDeviceLeg.Context
    ) -> [String: Any]? {
        var result: [String: Any] = [:]
        for (key, value) in values {
            guard let resolved = DeviceLegValues.resolve(value, context: context),
                  let foundation = foundationValue(resolved) else {
                return nil
            }
            let previousCount = result.count
            result[key] = foundation
            guard result.count == previousCount + 1 else {
                // Swift dictionaries normalize canonically equivalent keys;
                // refuse to collapse two exact authored property names.
                return nil
            }
        }
        return result
    }

    private func foundationValue(_ value: ExperienceReleaseJSONValue) -> Any? {
        switch value {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            var result: [Any] = []
            for value in values {
                guard let converted = foundationValue(value) else { return nil }
                result.append(converted)
            }
            return result
        case .object(let values):
            var result: [String: Any] = [:]
            for (key, value) in values {
                guard let converted = foundationValue(value) else { return nil }
                let previousCount = result.count
                result[key] = converted
                guard result.count == previousCount + 1 else { return nil }
            }
            return result
        }
    }
}

private struct SendEvent: Decodable {
    let eventName: String
    let payload: ExactJSONObject<JourneyValue>?
}

private struct UpdateCustomer: Decodable {
    let attributes: ExactJSONObject<JourneyValue>
}

private struct Milestone: Decodable {
    let milestoneId: String
}

private struct AppActionEffect: Decodable {
    let name: String
    let payload: ExactJSONObject<JourneyValue>?
}

private struct Exit: Decodable {
    let reason: String?
}

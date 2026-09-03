import Foundation

struct JourneyProfileFenceToken: Equatable, Sendable {
    let generation: UInt64
}

/// Linearizes same-identity profile replacement with short local publication
/// windows. Async event commits still check the token before and after their
/// durable capture.
final class JourneyProfileFence: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var generation: UInt64 = 0

    func advance() -> UInt64 {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    func token(ifCurrent expectedGeneration: UInt64) -> JourneyProfileFenceToken? {
        lock.withLock {
            guard generation == expectedGeneration else { return nil }
            return JourneyProfileFenceToken(generation: generation)
        }
    }

    func token() -> JourneyProfileFenceToken {
        lock.withLock { JourneyProfileFenceToken(generation: generation) }
    }

    func isCurrent(_ token: JourneyProfileFenceToken) -> Bool {
        lock.withLock { generation == token.generation }
    }

    /// Runs one synchronous durable commit while the generation is stable.
    /// The lock gives profile replacement and journal admission one exact
    /// ordering without holding actor isolation across file I/O.
    func performIfCurrent<Value>(
        _ token: JourneyProfileFenceToken,
        _ operation: () throws -> Value
    ) rethrows -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == token.generation else { return nil }
        return try operation()
    }

    @discardableResult
    func publishIfCurrent(
        _ token: JourneyProfileFenceToken,
        _ publication: () -> Void
    ) -> Bool {
        lock.withLock {
            guard generation == token.generation else { return false }
            publication()
            return generation == token.generation
        }
    }
}

struct JourneyDispatchRequest: Sendable {
    let runId: String
    let journeyId: String
    let generation: Int
    let reference: ArmedJourney.Reference
    let release: AuthenticatedJourneyRelease
    let stepId: String
    let action: [String: JourneyReleaseJSONValue]
    let context: ArmedJourney.Context
    let effectId: String
    let distinctId: String
    let identityFence: IdentityFenceToken
    let executionFence: JourneyProfileFence
    let executionFenceToken: JourneyProfileFenceToken
}

/// Admits the event store's final synchronous mutation only while both the
/// authenticated execution snapshot and customer identity remain current.
/// The lock order matches other Journey publications: execution first,
/// then identity.
struct JourneyCommitAdmission {
    let identity: IdentityServiceProtocol
    let identityFenceToken: IdentityFenceToken?
    let executionFence: JourneyProfileFence
    let executionFenceToken: JourneyProfileFenceToken

    static func executionOnly(
        identity: IdentityServiceProtocol,
        executionFence: JourneyProfileFence,
        executionFenceToken: JourneyProfileFenceToken
    ) -> Self {
        Self(
            identity: identity,
            identityFenceToken: nil,
            executionFence: executionFence,
            executionFenceToken: executionFenceToken
        )
    }

    func commitIfCurrent(
        _ commit: () throws -> StableEventCaptureCommit
    ) rethrows -> StableEventCaptureCommit? {
        try commitWhileCurrent(commit)
    }

    func commitBatchIfCurrent(
        _ commit: () throws -> [StableEventCaptureCommit]
    ) rethrows -> [StableEventCaptureCommit]? {
        try commitWhileCurrent(commit)
    }

    /// Journal state and its corresponding event publication share the same
    /// execution and identity authority. The journal calls this around its
    /// final synchronous file replacement so revocation cannot land between an
    /// async preflight read and the durable mutation.
    func commitJournalIfCurrent<Value>(
        _ commit: () throws -> Value
    ) rethrows -> Value? {
        try commitWhileCurrent(commit)
    }

    private func commitWhileCurrent<Value>(
        _ commit: () throws -> Value
    ) rethrows -> Value? {
        guard let identityFenceToken else {
            return try executionFence.performIfCurrent(
                executionFenceToken,
                commit
            )
        }
        guard let identityAdmission = try executionFence.performIfCurrent(
            executionFenceToken,
            {
                try identity.performIfCurrentIdentityFenceToken(
                    identityFenceToken,
                    commit
                )
            }
        ) else {
            return nil
        }
        return identityAdmission
    }
}

extension JourneyCommitAdmission: StableEventCaptureCommitAdmission {}
extension JourneyCommitAdmission: StableEventCaptureBatchCommitAdmission {}

enum JourneyDispatchResult: Equatable, Sendable {
    case outlet(String)
    case complete(String)
    case unsupported
    case failed
}

protocol JourneyDispatching: Sendable {
    func dispatch(_ request: JourneyDispatchRequest) async -> JourneyDispatchResult
}

/// Executes authenticated local effects after JourneyRunJournal has made
/// their stable identity durable. Presentation and commerce are handled by
/// the renderer-backed presentation owner before this seam.
struct JourneyEffectDispatcher {
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

    func dispatch(_ request: JourneyDispatchRequest) async -> JourneyDispatchResult {
        guard await requestIsCurrent(request),
              let rawType = JourneyActionType.rawValue(
                in: request.action
              ) else {
            return .failed
        }
        guard let type = JourneyActionType(rawValue: rawType) else {
            return .unsupported
        }
        switch type {
        case .sendEvent:
            return await sendEvent(request)
        case .updateCustomer:
            return await updateCustomer(request)
        case .milestone:
            return await milestone(request)
        case .submitResponse:
            return .outlet("next")
        case .appAction:
            return await appAction(request)
        case .exit:
            guard let action = decode(Exit.self, request.action) else { return .failed }
            if let reason = action.reason, !reason.isEmpty {
                return .complete(reason)
            }
            return .complete("completed")
        default:
            return .unsupported
        }
    }

    private func sendEvent(
        _ request: JourneyDispatchRequest
    ) async -> JourneyDispatchResult {
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
        guard let _ = await events.captureAndRouteSystemEvent(
                .init(
                    name: action.eventName,
                    properties: properties,
                    eventId: request.effectId,
                    distinctId: request.distinctId
                ),
                admission: eventCommitAdmission(request)
              ),
              await requestIsCurrent(request) else {
            return .failed
        }
        return await requestIsCurrent(request) ? .outlet("next") : .failed
    }

    private func updateCustomer(
        _ request: JourneyDispatchRequest
    ) async -> JourneyDispatchResult {
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
            let executionUpdated = request.executionFence.publishIfCurrent(
                request.executionFenceToken
            ) {
                identityUpdated = identity.publishIfCurrentIdentityFenceToken(
                    request.identityFence
                ) {
                    identity.setUserProperties(attributesBox.value)
                }
            }
            return executionUpdated && identityUpdated
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
        _ request: JourneyDispatchRequest
    ) async -> JourneyDispatchResult {
        guard let action = decode(Milestone.self, request.action) else { return .failed }
        var properties = legAttribution(request)
        properties["milestone_id"] = action.milestoneId
        guard let _ = await events.captureAndRouteSystemEvent(
                .init(
                    name: JourneyEvents.journeyMilestone,
                    properties: properties,
                    eventId: request.effectId,
                    distinctId: request.distinctId
                ),
                admission: eventCommitAdmission(request)
              ),
              await requestIsCurrent(request) else {
            return .failed
        }
        return await requestIsCurrent(request) ? .outlet("next") : .failed
    }

    private func appAction(
        _ request: JourneyDispatchRequest
    ) async -> JourneyDispatchResult {
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
            let executionDelivered = request.executionFence.publishIfCurrent(
                request.executionFenceToken
            ) {
                identityDelivered = identity.publishIfCurrentIdentityFenceToken(
                    request.identityFence
                ) {
                    appActionHandler(value)
                }
            }
            return executionDelivered && identityDelivered
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
        request: JourneyDispatchRequest
    ) async -> Bool {
        guard let _ = await events.captureAndRouteSystemEvent(
            .init(
                name: event,
                properties: properties,
                eventId: request.effectId,
                distinctId: request.distinctId
            ),
            admission: eventCommitAdmission(request)
        ), await requestIsCurrent(request) else { return false }
        return await requestIsCurrent(request)
    }

    private func eventCommitAdmission(
        _ request: JourneyDispatchRequest
    ) -> JourneyCommitAdmission {
        JourneyCommitAdmission(
            identity: identity,
            identityFenceToken: request.identityFence,
            executionFence: request.executionFence,
            executionFenceToken: request.executionFenceToken
        )
    }

    private func legAttribution(
        _ request: JourneyDispatchRequest
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

    private func requestIsCurrent(_ request: JourneyDispatchRequest) async -> Bool {
        guard request.executionFence.isCurrent(request.executionFenceToken),
              await identityFenceIsCurrent(request.identityFence) else {
            return false
        }
        return request.executionFence.isCurrent(request.executionFenceToken)
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        _ action: [String: JourneyReleaseJSONValue]
    ) -> Value? {
        try? ExactJSONCodec.decode(
            type,
            from: ExactJSONCodec.encode(
                JourneyReleaseJSONValue.object(.init(action))
            )
        )
    }

    private func resolve(
        _ values: ExactJSONObject<JourneyValue>,
        context: ArmedJourney.Context
    ) -> [String: Any]? {
        var result: [String: Any] = [:]
        for (key, value) in values {
            guard let resolved = JourneyValues.resolve(value, context: context),
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

    private func foundationValue(_ value: JourneyReleaseJSONValue) -> Any? {
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

extension JourneyEffectDispatcher: JourneyDispatching {}

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

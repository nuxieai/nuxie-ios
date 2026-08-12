import Foundation
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

actor MockTriggerService {
    private var updatesToEmit: [TriggerUpdate] = []
    private var updatesToEmitAfterReturn: [TriggerUpdate] = []
    private var receivedPresentationAttempts: [ExperiencePresentationAttempt] = []

    public init() {}

    public func setUpdates(_ updates: [TriggerUpdate], afterReturn: [TriggerUpdate] = []) {
        updatesToEmit = updates
        updatesToEmitAfterReturn = afterReturn
    }

    func presentationAttempts() -> [ExperiencePresentationAttempt] {
        receivedPresentationAttempts
    }

    private func performTrigger(
        presentationAttempt: ExperiencePresentationAttempt?,
        handler: @escaping @Sendable (TriggerUpdate) -> Void
    ) async {
        if let presentationAttempt {
            receivedPresentationAttempts.append(presentationAttempt)
        }
        let immediateUpdates = updatesToEmit
        let delayedUpdates = updatesToEmitAfterReturn

        for update in immediateUpdates {
            await MainActor.run {
                handler(update)
            }
        }

        guard !delayedUpdates.isEmpty else { return }
        Task {
            for update in delayedUpdates {
                try? await Task.sleep(nanoseconds: 20_000_000)
                await MainActor.run {
                    handler(update)
                }
            }
        }
    }
}

extension MockTriggerService: TriggerServiceProtocol {
    public func trigger(
        _ event: String,
        properties: sending [String: Any]?,
        userProperties: sending [String: Any]?,
        userPropertiesSetOnce: sending [String: Any]?,
        handler: @escaping @Sendable (TriggerUpdate) -> Void
    ) async {
        await performTrigger(
            presentationAttempt: nil,
            handler: handler
        )
    }
}

extension MockTriggerService: PresentationAttemptTriggerServiceProtocol {
    func trigger(
        _ event: String,
        properties: sending [String: Any]?,
        userProperties: sending [String: Any]?,
        userPropertiesSetOnce: sending [String: Any]?,
        presentationAttempt: ExperiencePresentationAttempt,
        handler: @escaping @Sendable (TriggerUpdate) -> Void
    ) async {
        await performTrigger(
            presentationAttempt: presentationAttempt,
            handler: handler
        )
    }
}

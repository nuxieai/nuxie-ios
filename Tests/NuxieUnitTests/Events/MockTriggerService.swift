import Foundation
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

public // @preconcurrency: the protocol carries [String: Any] payloads (public
// analytics-style API). Older Swift 6 compilers (current CI runners,
// Xcode 26.2) require the opt-out for the actor-isolated witnesses; newer
// compilers accept the crossing and flag this as having no effect — that
// warning is a known, benign toolchain-skew artifact until the runner
// fleet is on Xcode 26.6+.
actor MockTriggerService: @preconcurrency TriggerServiceProtocol {
    private var updatesToEmit: [TriggerUpdate] = []
    private var updatesToEmitAfterReturn: [TriggerUpdate] = []

    public init() {}

    public func setUpdates(_ updates: [TriggerUpdate], afterReturn: [TriggerUpdate] = []) {
        updatesToEmit = updates
        updatesToEmitAfterReturn = afterReturn
    }

    public func trigger(
        _ event: String,
        properties: sending [String: Any]?,
        userProperties: sending [String: Any]?,
        userPropertiesSetOnce: sending [String: Any]?,
        handler: @escaping @Sendable (TriggerUpdate) -> Void
    ) async {
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


import Foundation

/// Navigation ordering shared by the layer controller and its deterministic tests.
@MainActor
enum ExperienceLayerStep {
    struct Operations {
        var setInputEnabled: (Bool) -> Void
        var prepare: () async throws -> Void
        var register: (String, String) async throws -> AsyncStream<Void>
        var insert: (Int) async throws -> Void
        var phases: ([(String, ExperienceScreenLifecyclePhase)], String) async throws -> Void
        var present: @MainActor @Sendable () async throws -> Void
        var wait: ([AsyncStream<Void>], UInt64) async -> Void
        var remove: () async throws -> Void
        var hidden: () async -> Void
        var active: () async throws -> Void
    }

    static func perform(source: String, target: String, style: ExperienceScreenTransitionSpec.Kind,
                        isBack: Bool, plan: ExperienceScreenCustomTransitionPlan?,
                        exit: ExperienceScreenExitPlan, reduceMotion: Bool,
                        operations: Operations) async throws {
        guard source != target else { return }
        operations.setInputEnabled(false)
        defer { operations.setInputEnabled(true) }
        try await operations.prepare()
        let together = style != .none && plan != nil && !reduceMotion
        let transition = plan?.transitionId ?? ""
        let incomingOnTop = plan?.incomingOnTop ?? (style != .push || !isBack)
        let incomingIndex = incomingOnTop ? 1 : 0
        var loggedPresentationTimeout = false
        // Healthy skipped renders may never produce a phase drawable.
        func present(within milliseconds: UInt64) async throws -> Bool {
            let presented = try await withThrowingTaskGroup(of: Bool.self) { group in
                let presentation = operations.present
                group.addTask { try await presentation(); return true }
                group.addTask {
                    try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
                    return false
                }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
            try Task.checkCancellation()
            if !presented, !loggedPresentationTimeout {
                loggedPresentationTimeout = true
                LogWarning("ExperienceLayerStep: presentation watchdog expired for \(source) to \(target) after \(milliseconds) ms")
            }
            return presented
        }
        if together, let plan {
            let outgoing = try await operations.register(source, plan.outgoingCompletionEventName)
            let incoming = try await operations.register(target, plan.incomingCompletionEventName)
            try await operations.insert(incomingIndex)
            try await operations.phases([(source, .exiting), (target, .entering)], transition)
            if try await present(within: plan.watchdogMilliseconds) {
                await operations.wait([outgoing, incoming], plan.watchdogMilliseconds)
            }
            try Task.checkCancellation()
            try await operations.remove()
        } else {
            let outgoing: AsyncStream<Void>?
            if !reduceMotion, let name = plan?.outgoingCompletionEventName ?? exit.completionEventName {
                outgoing = try await operations.register(source, name)
            } else { outgoing = nil }
            try await operations.phases([(source, .exiting)], transition)
            if !reduceMotion {
                let duration = plan?.watchdogMilliseconds ?? exit.watchdogMilliseconds
                if try await present(within: duration ?? 250), let outgoing, let duration {
                    await operations.wait([outgoing], duration)
                }
            }
            try Task.checkCancellation()
            try await operations.insert(incomingIndex)
            try await operations.remove()
            let incoming: AsyncStream<Void>?
            if !reduceMotion, let plan {
                incoming = try await operations.register(target, plan.incomingCompletionEventName)
            } else { incoming = nil }
            try await operations.phases([(target, .entering)], transition)
            if !reduceMotion {
                if try await present(within: plan?.watchdogMilliseconds ?? 250), let incoming, let plan {
                    await operations.wait([incoming], plan.watchdogMilliseconds)
                }
            }
        }
        try Task.checkCancellation()
        try await operations.phases([(source, .hidden), (target, .active)], "")
        await operations.hidden()
        try Task.checkCancellation()
        try await operations.active()
    }
}

struct ExperienceLayerHistory {
    struct Entry {
        let screenID: String
        let transition: ExperienceScreenTransitionSpec
    }
    private(set) var entries: [Entry]
    var screenIDs: [String] { entries.map(\.screenID) }

    init(root: String) { entries = [Entry(screenID: root, transition: .init(raw: nil))] }

    func backTransition(steps: Int, target: String? = nil,
                        declarations: [NativeExperienceTransition] = []) -> ExperienceScreenTransitionSpec {
        guard let entry = entries.last else { return .none }
        if steps == 1 { return entry.transition }
        if let target, let pair = declarations.first(where: {
            $0.isDefaultPair && (($0.sourceScreenId == entry.screenID && $0.destinationScreenId == target)
                || ($0.destinationScreenId == entry.screenID && $0.sourceScreenId == target && $0.reverse != nil))
        }) {
            // Skipping Back uses the published default pair between its endpoints.
            return .init(kind: .magicMove, transitionId: pair.id)
        }
        return .none
    }

    mutating func visit(_ screenID: String, transition: ExperienceScreenTransitionSpec) {
        if let index = entries.firstIndex(where: { $0.screenID == screenID }) {
            entries = Array(entries.prefix(index + 1))
        } else { entries.append(Entry(screenID: screenID, transition: transition)) }
    }
}

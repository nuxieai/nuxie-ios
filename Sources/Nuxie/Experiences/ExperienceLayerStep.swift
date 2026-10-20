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
        var present: () async throws -> Void
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
        if together, let plan {
            let outgoing = try await operations.register(source, plan.outgoingCompletionEventName)
            let incoming = try await operations.register(target, plan.incomingCompletionEventName)
            try await operations.insert(style == .push && isBack ? 0 : 1)
            try await operations.phases([(source, .exiting), (target, .entering)], transition)
            try await operations.present()
            await operations.wait([outgoing, incoming], plan.watchdogMilliseconds)
            try Task.checkCancellation()
            try await operations.remove()
        } else {
            let outgoing: AsyncStream<Void>?
            if !reduceMotion, let name = exit.completionEventName {
                outgoing = try await operations.register(source, name)
            } else { outgoing = nil }
            try await operations.phases([(source, .exiting)], "")
            if !reduceMotion {
                try await operations.present()
                if let outgoing, let duration = exit.watchdogMilliseconds {
                    await operations.wait([outgoing], duration)
                }
            }
            try Task.checkCancellation()
            try await operations.insert(style == .push && isBack ? 0 : 1)
            try await operations.remove()
            let incoming: AsyncStream<Void>?
            if !reduceMotion, let plan {
                incoming = try await operations.register(target, plan.incomingCompletionEventName)
            } else { incoming = nil }
            try await operations.phases([(target, .entering)], transition)
            if !reduceMotion {
                try await operations.present()
                if let incoming, let plan {
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
            ($0.sourceScreenId == entry.screenID && $0.destinationScreenId == target)
                || ($0.destinationScreenId == entry.screenID && $0.sourceScreenId == target && $0.reverse != nil)
        }) { return .init(kind: .magicMove, transitionId: pair.id) }
        return .none
    }

    mutating func visit(_ screenID: String, transition: ExperienceScreenTransitionSpec) {
        if let index = entries.firstIndex(where: { $0.screenID == screenID }) {
            entries = Array(entries.prefix(index + 1))
        } else { entries.append(Entry(screenID: screenID, transition: transition)) }
    }
}

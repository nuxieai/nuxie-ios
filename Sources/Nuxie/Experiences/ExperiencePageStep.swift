import Foundation

/// Every batch finishes on the page's frame lane before another advance.
@MainActor
enum ExperiencePageStep {
    enum Change: Equatable, Sendable {
        case take
        case position(isBack: Bool)
        case reconcile
        case expand
        case phases([(String, ExperienceScreenLifecyclePhase)], String)
        case begin(String?)
        case end(String?)
        case retire

        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.take, .take), (.retire, .retire), (.reconcile, .reconcile), (.expand, .expand): return true
            case let (.position(a), .position(b)): return a == b
            case let (.begin(a), .begin(b)), let (.end(a), .end(b)): return a == b
            case let (.phases(a, x), .phases(b, y)):
                return x == y && a.count == b.count && zip(a, b).allSatisfy { pair in pair.0.0 == pair.1.0 && pair.0.1 == pair.1.1 }
            default: return false
            }
        }
    }
    struct Operations {
        var setInputEnabled: (Bool) -> Void
        var prepare: () async throws -> Void
        var register: (String, String) async throws -> AsyncStream<Void>
        var batch: ([Change]) async throws -> Void
        var present: @MainActor @Sendable () async throws -> Void
        var wait: ([AsyncStream<Void>], UInt64) async -> Void
        var hidden: () async -> Void
        var active: () async throws -> Void
        var drain: () async throws -> Void = {}
    }

    static func perform(source: String, target: String, style: ExperienceScreenTransitionSpec.Kind,
                        isBack: Bool, plan: ExperienceScreenCustomTransitionPlan?,
                        exit: ExperienceScreenExitPlan, reduceMotion: Bool, coveredCut: Bool = false,
                        operations: Operations) async throws {
        guard source != target else { return }
        operations.setInputEnabled(false)
        defer { operations.setInputEnabled(true) }
        try await operations.prepare()
        let name = plan?.transitionId
        let transition = name ?? ""
        let leaving: Change = .phases([(source, .exiting)], transition)
        let entering: Change = .phases([(target, .entering)], transition)
        let hidden: Change = .phases([(source, .hidden)], "")
        let active: Change = .phases([(target, .active)], "")

        // The completion watchdog starts only after the phase frame is presented.
        // Drawable starvation has its own bounded presentation wait.
        func waitForFrame(_ streams: [AsyncStream<Void>], duration: UInt64) async throws {
            let presented = try await withThrowingTaskGroup(of: Bool.self) { group in
                let present = operations.present
                group.addTask { try await present(); return true }
                group.addTask { try await Task.sleep(nanoseconds: duration * 1_000_000); return false }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
            try Task.checkCancellation()
            if presented { await operations.wait(streams, duration) }
            else { LogWarning("ExperiencePageStep: phase frame presentation watchdog expired") }
            try Task.checkCancellation()
        }

        let incoming: [Change] = [.take, .position(isBack: isBack), .reconcile, .expand]
        if coveredCut {
            try await operations.batch([.phases([(source, .hidden), (target, .hidden)], "")] + incoming + [
                .begin(nil), .end(nil), .retire])
        } else if reduceMotion {
            try await operations.batch(incoming + [leaving, entering, .begin(name), .end(name), hidden, .retire, active])
        } else if style != .none, let plan {
            let outgoing = try await operations.register(source, plan.outgoingCompletionEventName)
            let incomingCompletion = try await operations.register(target, plan.incomingCompletionEventName)
            try await operations.batch(incoming + [.phases([(source, .exiting), (target, .entering)], transition), .begin(name)])
            try await waitForFrame([outgoing, incomingCompletion], duration: plan.watchdogMilliseconds)
            try await operations.batch([.end(name), hidden, .retire, active])
        } else {
            let outgoingName = plan?.outgoingCompletionEventName ?? exit.completionEventName
            let outgoing = try await outgoingName.asyncMap { try await operations.register(source, $0) }
            try await operations.batch([leaving])
            if let outgoing {
                try await waitForFrame([outgoing], duration: plan?.watchdogMilliseconds ?? exit.watchdogMilliseconds ?? 250)
            }
            let incomingCompletion = try await plan.asyncMap { try await operations.register(target, $0.incomingCompletionEventName) }
            try await operations.batch(incoming + [entering, .begin(name), hidden, .retire])
            if let incomingCompletion, let plan {
                try await waitForFrame([incomingCompletion], duration: plan.watchdogMilliseconds)
            }
            try await operations.batch([.end(name), active])
        }
        // step_end commands arrive on the next player step. Deliver that result
        // while the outgoing row still owns host commands, even after retirement.
        try await operations.drain()
        try Task.checkCancellation()
        await operations.hidden()
        try Task.checkCancellation()
        try await operations.active()
    }
}

struct ExperiencePageHistory {
    struct Entry {
        let screenID: String
        let transition: ExperienceScreenTransitionSpec
    }
    private(set) var entries: [Entry]
    var screenIDs: [String] { entries.map(\.screenID) }
    init(root: String) { entries = [.init(screenID: root, transition: .none)] }

    func backTransition(steps: Int, target: String? = nil,
                        declarations: [NativeExperienceTransition] = []) -> ExperienceScreenTransitionSpec {
        guard let entry = entries.last else { return .none }
        if steps == 1 { return entry.transition }
        if let target, let pair = declarations.first(where: {
            $0.isDefaultPair && $0.sourceScreenId == entry.screenID && $0.destinationScreenId == target
        }) { return .init(kind: .magicMove, transitionId: pair.id) }
        return .none
    }

    mutating func visit(_ screenID: String, transition: ExperienceScreenTransitionSpec) {
        entries.append(.init(screenID: screenID, transition: transition))
    }

    mutating func back(to screenID: String, steps: Int? = nil) {
        if let steps, steps > 0, entries.count > steps, entries[entries.count - 1 - steps].screenID == screenID {
            entries.removeLast(steps)
        } else if let index = entries.dropLast().lastIndex(where: { $0.screenID == screenID }) {
            entries = Array(entries.prefix(index + 1))
        }
    }
}

/// The lower page changes while covered, then UIKit reveals it with one pop.
@MainActor
enum ExperiencePageBack {
    static func perform(cut: () async throws -> Void, pop: () async throws -> Void) async throws {
        try await cut()
        try await pop()
    }
}

struct ExperiencePageStack {
    struct Location: Equatable {
        let page: Int
        let entry: Int
        let screenID: String
    }
    static func back(steps: Int, histories: [[String]]) -> Location? {
        let locations = histories.enumerated().flatMap { page, history in
            history.enumerated().map { Location(page: page, entry: $0.offset, screenID: $0.element) }
        }
        guard !locations.isEmpty else { return nil }
        return locations[max(0, locations.count - 1 - max(1, steps))]
    }
}

/// Mirrors list order and sleep state, including index changes after moves and removals.
struct ExperiencePageRows {
    enum Mutation: Equatable {
        case append(String, Int)
        case move(String, Int, Int)
        case collapse(String, Int, Bool)
        case remove(String, Int)
    }
    private(set) var screenIDs: [String] = []
    private(set) var collapsed: Set<String> = []

    mutating func take(_ screenID: String) -> Mutation {
        if let index = screenIDs.firstIndex(of: screenID) {
            collapsed.remove(screenID)
            return .collapse(screenID, index, false)
        }
        let index = screenIDs.count
        screenIDs.append(screenID)
        return .append(screenID, index)
    }

    /// Destination indexes are in the list after removing the incoming item.
    /// Moving preserves the instance and sleep state; taking the row expands it separately.
    mutating func position(_ screenID: String, relativeTo outgoing: String, isBack: Bool) -> Mutation? {
        guard screenID != outgoing,
              let from = screenIDs.firstIndex(of: screenID),
              let outgoingIndex = screenIDs.firstIndex(of: outgoing) else { return nil }
        let adjustedOutgoing = outgoingIndex - (from < outgoingIndex ? 1 : 0)
        let to = adjustedOutgoing + (isBack ? 0 : 1)
        guard from != to else { return nil }
        screenIDs.remove(at: from)
        screenIDs.insert(screenID, at: to)
        return .move(screenID, from, to)
    }

    mutating func remove(_ screenID: String) -> Mutation? {
        guard let index = screenIDs.firstIndex(of: screenID) else { return nil }
        screenIDs.remove(at: index)
        collapsed.remove(screenID)
        return .remove(screenID, index)
    }

    mutating func retire(active: String, reachable: Set<String>) -> [Mutation] {
        var result: [Mutation] = []
        // Collapse against the current runtime order before any removals change that order.
        for id in screenIDs where id != active && reachable.contains(id) {
            if let index = screenIDs.firstIndex(of: id) {
                collapsed.insert(id)
                result.append(.collapse(id, index, true))
            }
        }
        for id in screenIDs where id != active && !reachable.contains(id) {
            if let removal = remove(id) { result.append(removal) }
        }
        return result
    }
}

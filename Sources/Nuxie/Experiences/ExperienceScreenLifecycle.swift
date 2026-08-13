import Foundation

enum ExperienceScreenLifecyclePhase: String, CaseIterable, Sendable {
    case hidden
    case entering
    case active
    case exiting

    var analyticsEventName: String? {
        switch self {
        case .active:
            return SystemEventNames.screenShown
        case .hidden:
            return SystemEventNames.screenDismissed
        case .entering, .exiting:
            return nil
        }
    }
}

struct ExperienceScreenLifecycleSnapshot: Equatable, Sendable {
    let phase: ExperienceScreenLifecyclePhase
    let appearances: UInt64
    let transition: String
    let reduceMotion: Bool

    func stateCommand(
        viewModelName: String,
        instanceID: String?
    ) -> ExperienceInteractiveStateCommand {
        .snapshot([
            .init(
                viewModelName: viewModelName,
                instanceID: instanceID,
                instanceName: nil,
                path: "screen/phase",
                value: .string(phase.rawValue)
            ),
            .init(
                viewModelName: viewModelName,
                instanceID: instanceID,
                instanceName: nil,
                path: "screen/appearances",
                value: .number(Double(appearances))
            ),
            .init(
                viewModelName: viewModelName,
                instanceID: instanceID,
                instanceName: nil,
                path: "screen/transition",
                value: .string(transition)
            ),
            .init(
                viewModelName: viewModelName,
                instanceID: instanceID,
                instanceName: nil,
                path: "env/reduceMotion",
                value: .bool(reduceMotion)
            ),
        ])
    }
}

struct ExperienceScreenLifecycleState: Sendable {
    private(set) var phase: ExperienceScreenLifecyclePhase = .hidden
    private(set) var appearances: UInt64 = 0
    private(set) var transition = ""
    private(set) var reduceMotion: Bool

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    mutating func move(
        to phase: ExperienceScreenLifecyclePhase,
        transition: String = "",
        reduceMotion: Bool? = nil
    ) -> ExperienceScreenLifecycleSnapshot {
        if phase == .entering {
            appearances &+= 1
        }
        self.phase = phase
        self.transition = transition
        if let reduceMotion {
            self.reduceMotion = reduceMotion
        }
        return snapshot
    }

    mutating func updateReduceMotion(_ reduceMotion: Bool) -> ExperienceScreenLifecycleSnapshot {
        self.reduceMotion = reduceMotion
        return snapshot
    }

    var snapshot: ExperienceScreenLifecycleSnapshot {
        ExperienceScreenLifecycleSnapshot(
            phase: phase,
            appearances: appearances,
            transition: transition,
            reduceMotion: reduceMotion
        )
    }
}

struct ExperienceScreenExitPlan: Equatable, Sendable {
    let completionEventName: String?
    let watchdogMilliseconds: UInt64?

    init(declaration: NativeExperienceScreenExit?, reduceMotion: Bool) {
        guard let declaration, !reduceMotion else {
            completionEventName = nil
            watchdogMilliseconds = nil
            return
        }
        completionEventName = declaration.completeEventName
        watchdogMilliseconds = UInt64(max(0, declaration.durationMs)) + 250
    }
}

struct ExperienceScreenCustomTransitionPlan: Equatable, Sendable {
    let transitionId: String
    let durationMilliseconds: UInt64
    let incomingOnTop: Bool
    let outgoingCompletionEventName: String
    let incomingCompletionEventName: String

    var watchdogMilliseconds: UInt64 { durationMilliseconds + 250 }

    static func resolve(
        transitionId: String,
        sourceScreenId: String,
        destinationScreenId: String,
        declarations: [NuxPackageTransition],
        reduceMotion: Bool = false
    ) -> ExperienceScreenCustomTransitionPlan? {
        guard !reduceMotion else { return nil }
        guard let declaration = declarations.first(where: { $0.id == transitionId }) else {
            return nil
        }
        if declaration.sourceScreenId == sourceScreenId,
           declaration.destinationScreenId == destinationScreenId {
            return ExperienceScreenCustomTransitionPlan(
                transitionId: transitionId,
                durationMilliseconds: UInt64(max(0, declaration.durationMs)),
                incomingOnTop: declaration.incomingOnTop,
                outgoingCompletionEventName: declaration.source.completeEventName,
                incomingCompletionEventName: declaration.destination.completeEventName
            )
        }
        guard declaration.destinationScreenId == sourceScreenId,
              declaration.sourceScreenId == destinationScreenId,
              let reverse = declaration.reverse else {
            return nil
        }
        return ExperienceScreenCustomTransitionPlan(
            transitionId: transitionId,
            durationMilliseconds: UInt64(max(0, reverse.durationMs ?? declaration.durationMs)),
            incomingOnTop: reverse.incomingOnTop ?? declaration.incomingOnTop,
            outgoingCompletionEventName: reverse.source.completeEventName,
            incomingCompletionEventName: reverse.destination.completeEventName
        )
    }
}

enum ExperienceScreenExitWatchdog {
    typealias Sleep = @Sendable (_ milliseconds: UInt64) async -> Void

    static func wait(
        for stream: AsyncStream<Void>,
        watchdogMilliseconds: UInt64,
        sleep: @escaping Sleep = { milliseconds in
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        }
    ) async {
        await wait(
            for: [stream],
            watchdogMilliseconds: watchdogMilliseconds,
            sleep: sleep
        )
    }

    static func wait(
        for streams: [AsyncStream<Void>],
        watchdogMilliseconds: UInt64,
        sleep: @escaping Sleep = { milliseconds in
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        }
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for stream in streams {
                    for await _ in stream { break }
                }
            }
            group.addTask {
                await sleep(watchdogMilliseconds)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}

@MainActor
enum ExperienceScreenCustomTransitionExecution {
    typealias Step = () async -> Void
    typealias InputSetter = (_ enabled: Bool) -> Void
    typealias Finalize = () async -> Bool

    static func perform(
        setOutgoingInputEnabled: InputSetter,
        writePhases: Step,
        awaitCompletion: Step,
        finalize: Finalize
    ) async -> Bool {
        setOutgoingInputEnabled(false)
        defer { setOutgoingInputEnabled(true) }
        await writePhases()
        await awaitCompletion()
        return await finalize()
    }
}

@MainActor
enum ExperienceScreenLifecycleNavigation {
    typealias Step = () async -> Void
    typealias NativeOperation = () async throws -> Bool

    static func perform(
        targetEntering: Step,
        sourceExiting: Step,
        nativeOperation: NativeOperation,
        sourceHidden: Step,
        targetActive: Step,
        restoreAfterFailure: Step
    ) async throws -> Bool {
        await targetEntering()
        await sourceExiting()
        do {
            guard try await nativeOperation() else {
                await restoreAfterFailure()
                return false
            }
        } catch {
            await restoreAfterFailure()
            throw error
        }
        await sourceHidden()
        await targetActive()
        return true
    }
}

@MainActor
enum ExperienceScreenLifecycleSheetDismissal {
    typealias Step = () async -> Void

    static func perform(
        dismissedExiting: Step,
        dismissedHidden: Step,
        hiddenAnalytics: Step,
        revealedEntering: Step,
        revealedActive: Step
    ) async {
        await dismissedExiting()
        await dismissedHidden()
        await hiddenAnalytics()
        await revealedEntering()
        await revealedActive()
    }
}

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
                value: .string("")
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
    let transition = ""
    private(set) var reduceMotion: Bool

    init(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
    }

    mutating func move(
        to phase: ExperienceScreenLifecyclePhase,
        reduceMotion: Bool? = nil
    ) -> ExperienceScreenLifecycleSnapshot {
        if phase == .entering {
            appearances &+= 1
        }
        self.phase = phase
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

enum ExperienceScreenExitWatchdog {
    typealias Sleep = @Sendable (_ milliseconds: UInt64) async -> Void

    static func wait(
        for stream: AsyncStream<Void>,
        watchdogMilliseconds: UInt64,
        sleep: @escaping Sleep = { milliseconds in
            try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
        }
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in stream { return }
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

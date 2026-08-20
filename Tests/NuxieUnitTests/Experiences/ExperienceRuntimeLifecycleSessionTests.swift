import XCTest
@testable import Nuxie

@MainActor
final class ExperienceRuntimeLifecycleSessionTests: XCTestCase {
    private struct Navigation: Equatable {
        let id: Int
        let command: String
    }

    func testLifecycleOnlyAcceptsLegalCurrentGenerationTransitions() {
        let session = ExperienceRuntimeLifecycleSession<String, Navigation>()

        XCTAssertNil(session.beginMount())
        XCTAssertFalse(session.becomeReady(generation: 0))

        _ = session.beginLoading()
        let firstGeneration = session.generation
        XCTAssertEqual(session.state, .loading(generation: firstGeneration))
        XCTAssertEqual(session.beginMount()?.generation, firstGeneration)
        XCTAssertTrue(session.becomeReady(generation: firstGeneration))
        XCTAssertEqual(session.state, .ready(generation: firstGeneration))

        _ = session.beginLoading()
        let secondGeneration = session.generation
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        XCTAssertFalse(session.becomeReady(generation: firstGeneration))
        XCTAssertEqual(session.state, .loading(generation: secondGeneration))
    }

    func testTerminalFailureAndTeardownAreIdempotent() {
        let session = ExperienceRuntimeLifecycleSession<String, Navigation>()
        _ = session.beginLoading()
        let generation = session.generation
        _ = session.beginMount()

        XCTAssertTrue(session.latchTerminalFailure(generation: generation))
        XCTAssertFalse(session.latchTerminalFailure(generation: generation))
        XCTAssertEqual(session.state, .terminalFailure(generation: generation))

        let firstTeardown = session.beginTeardown()
        let repeatedTeardown = session.beginTeardown()
        XCTAssertEqual(repeatedTeardown.generation, firstTeardown.generation)
        session.finishTeardown(generation: firstTeardown.generation)
        XCTAssertEqual(session.state, .inactive(generation: firstTeardown.generation))
        XCTAssertEqual(session.beginTeardown().generation, firstTeardown.generation)
    }

    func testRetryRequeuesInterruptedNavigationAheadOfCommandBurst() {
        let session = ExperienceRuntimeLifecycleSession<String, Navigation>()
        _ = session.beginLoading()
        let generation = session.generation
        _ = session.beginMount()
        XCTAssertTrue(session.becomeReady(generation: generation))
        XCTAssertTrue(session.crossInitialActivationBoundary(generation: generation))

        session.enqueue("first")
        session.enqueue("second")
        XCTAssertTrue(session.beginCommandDrain(generation: generation))
        XCTAssertEqual(session.nextCommand(generation: generation), "first")
        session.endCommandDrain()

        let navigation = Navigation(id: 1, command: "navigate")
        XCTAssertTrue(session.beginNavigation(navigation, generation: generation))
        _ = session.beginLoading(requeue: session.activeNavigation?.command)
        let retryGeneration = session.generation
        XCTAssertEqual(session.pendingCommands, ["navigate", "second"])
        XCTAssertNil(session.activeNavigation)
        XCTAssertFalse(session.beginCommandDrain(generation: generation))

        _ = session.beginMount()
        XCTAssertTrue(session.becomeReady(generation: retryGeneration))
        XCTAssertTrue(session.crossInitialActivationBoundary(generation: retryGeneration))
        XCTAssertTrue(session.beginCommandDrain(generation: retryGeneration))
        XCTAssertEqual(session.nextCommand(generation: retryGeneration), "navigate")
        XCTAssertEqual(session.nextCommand(generation: retryGeneration), "second")
        XCTAssertNil(session.nextCommand(generation: retryGeneration))
        session.endCommandDrain()
        XCTAssertTrue(session.consumeReadyNotification(generation: retryGeneration))
        XCTAssertFalse(session.consumeReadyNotification(generation: retryGeneration))
    }

    func testTeardownCancelsOwnedMountAndFailureWork() async {
        let session = ExperienceRuntimeLifecycleSession<String, Navigation>()
        _ = session.beginLoading()
        let generation = session.generation
        _ = session.beginMount()
        let mount = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        session.ownMountTask(mount, generation: generation)
        XCTAssertTrue(session.latchTerminalFailure(generation: generation))
        let failure = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        session.ownFailureTask(failure, generation: generation)

        let work = session.beginTeardown()
        XCTAssertTrue(mount.isCancelled)
        XCTAssertTrue(failure.isCancelled)
        await work.mountTask?.value
        await work.failureTask?.value
        session.finishTeardown(generation: work.generation)
        XCTAssertEqual(session.state, .inactive(generation: work.generation))
    }

    func testInactiveTeardownStillJoinsCleanupAndDropsQueuedCommands() async {
        let session = ExperienceRuntimeLifecycleSession<String, Navigation>()
        _ = session.beginLoading()
        session.enqueue("stale")
        let invalidation = session.invalidateLoading()
        let cleanup = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        session.ownMountTask(cleanup, generation: invalidation.generation)
        XCTAssertEqual(session.state, .inactive(generation: invalidation.generation))

        let work = session.beginTeardown()
        XCTAssertTrue(cleanup.isCancelled)
        XCTAssertTrue(session.pendingCommands.isEmpty)
        XCTAssertTrue(session.state.generation > invalidation.generation)
        await work.mountTask?.value
        session.finishTeardown(generation: work.generation)
        XCTAssertEqual(session.state, .inactive(generation: work.generation))
    }

    func testStaleNavigationCompletionCannotClearNewerNavigation() {
        let session = ExperienceRuntimeLifecycleSession<String, Navigation>()
        _ = session.beginLoading()
        let generation = session.generation
        _ = session.beginMount()
        _ = session.becomeReady(generation: generation)
        _ = session.crossInitialActivationBoundary(generation: generation)

        XCTAssertTrue(session.beginNavigation(.init(id: 1, command: "first"), generation: generation))
        XCTAssertFalse(session.clearNavigation { $0.id == 2 })
        XCTAssertEqual(session.activeNavigation, .init(id: 1, command: "first"))
        XCTAssertTrue(session.clearNavigation { $0.id == 1 })
        XCTAssertNil(session.activeNavigation)
    }

    func testActivationCommandsAndReadyNotificationWaitForRecoveryBoundary() {
        let session = ExperienceRuntimeLifecycleSession<String, Navigation>()
        _ = session.beginLoading()
        let generation = session.generation
        _ = session.beginMount()
        XCTAssertTrue(session.becomeReady(generation: generation))

        // Entry-screen activation may synchronously emit navigation before the
        // persisted screen-routing journal has been recovered.
        session.enqueue("activation-navigation")
        XCTAssertFalse(session.beginCommandDrain(generation: generation))
        XCTAssertFalse(session.consumeReadyNotification(generation: generation))
        XCTAssertEqual(session.pendingCommands, ["activation-navigation"])

        XCTAssertTrue(session.crossInitialActivationBoundary(generation: generation))
        XCTAssertTrue(session.beginCommandDrain(generation: generation))
        XCTAssertEqual(session.nextCommand(generation: generation), "activation-navigation")
        XCTAssertNil(session.nextCommand(generation: generation))
        session.endCommandDrain()
        XCTAssertTrue(session.consumeReadyNotification(generation: generation))
    }
}

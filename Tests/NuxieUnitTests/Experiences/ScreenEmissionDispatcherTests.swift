import XCTest
@testable import Nuxie

final class ScreenEmissionDispatcherTests: XCTestCase {
    func testDeclarativeAndScriptActionsProduceTheSameEmissionContract() async throws {
        let invocation = ScreenActionInvocation(
            actionId: "choose_plan",
            value: .string("premium"),
            componentId: "plan_card",
            instanceId: "premium_monthly"
        )
        let run = ScreenEmissionRun(
            journeyId: "journey_1",
            executionOwnershipEpoch: 3,
            lifecycleGeneration: 2,
            presentationEpoch: 7
        )
        let declarative = ScreenEmissionDispatcher(
            createId: incrementingID(),
            now: { "2026-08-17T22:00:00.000Z" },
            executeScriptAction: { _ in
                XCTFail("declarative action must not execute a script")
                return []
            }
        )
        let scripted = ScreenEmissionDispatcher(
            createId: incrementingID(),
            now: { "2026-08-17T22:00:00.000Z" },
            executeScriptAction: { input in
                XCTAssertEqual(input.actionId, "choose_plan")
                return [
                    .responseSet(field: "plan", value: .string("premium")),
                    .event(name: "plan_chosen", payload: ["plan": .string("premium")]),
                ]
            }
        )

        let declarativeResult = await declarative.dispatch(
            run: run,
            screenId: "survey",
            definition: ScreenControlActionDefinition(
                actionId: "choose_plan",
                binding: .declarative([
                    .responseSet(field: "plan", value: .invocationValue),
                    .emit(
                        eventName: "plan_chosen",
                        payload: ["plan": .invocationValue]
                    ),
                ])
            ),
            invocation: invocation
        )
        let scriptResult = await scripted.dispatch(
            run: run,
            screenId: "survey",
            definition: ScreenControlActionDefinition(
                actionId: "choose_plan",
                binding: .script
            ),
            invocation: invocation
        )

        let declarativeBatch = try XCTUnwrap(declarativeResult.success)
        let scriptBatch = try XCTUnwrap(scriptResult.success)
        XCTAssertEqual(declarativeBatch, scriptBatch)
        XCTAssertEqual(declarativeBatch.source.actionId, "choose_plan")
        XCTAssertEqual(declarativeBatch.source.componentId, "plan_card")
        XCTAssertEqual(declarativeBatch.source.instanceId, "premium_monthly")
    }

    func testFailedScriptPublishesNoPrefixAndLeavesABatchSequenceGap() async throws {
        let dispatcher = ScreenEmissionDispatcher(
            createId: incrementingID(),
            now: { "2026-08-17T22:00:00.000Z" },
            executeScriptAction: { _ in
                throw ScreenEmissionDispatchError.scriptActionMissing(actionId: "submit")
            }
        )
        let run = ScreenEmissionRun(
            journeyId: "journey_1",
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 0
        )

        let failed = await dispatcher.dispatch(
            run: run,
            screenId: "survey",
            definition: ScreenControlActionDefinition(
                actionId: "submit",
                binding: .script
            ),
            invocation: ScreenActionInvocation(actionId: "submit")
        )
        let succeeded = await dispatcher.dispatch(
            run: run,
            screenId: "survey",
            definition: ScreenControlActionDefinition(
                actionId: "clear",
                binding: .declarative([.responseUnset(field: "plan")])
            ),
            invocation: ScreenActionInvocation(actionId: "clear")
        )

        XCTAssertEqual(
            failed.failure,
            .scriptActionMissing(actionId: "submit")
        )
        let batch = try XCTUnwrap(succeeded.success)
        XCTAssertEqual(batch.batchSequence, 1)
        XCTAssertNil(batch.previousCommittedBatchSequence)
        XCTAssertEqual(batch.emissions.map(\.sequence), [0])
        XCTAssertEqual(batch.emissions.map(\.name), ["$response_unset"])
    }

    func testEmptyCustomEventNameIsRejectedForDeclarativeAndScriptDrafts() async throws {
        let run = ScreenEmissionRun(
            journeyId: "journey_1",
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: 0
        )
        let declarative = ScreenEmissionDispatcher(
            createId: incrementingID(),
            now: { "2026-08-17T22:00:00.000Z" },
            executeScriptAction: { _ in [] }
        )
        let script = ScreenEmissionDispatcher(
            createId: incrementingID(),
            now: { "2026-08-17T22:00:00.000Z" },
            executeScriptAction: { _ in [.event(name: "", payload: [:])] }
        )

        let declarativeResult = await declarative.dispatch(
            run: run,
            screenId: "survey",
            definition: ScreenControlActionDefinition(
                actionId: "emit",
                binding: .declarative([.emit(eventName: "", payload: [:])])
            ),
            invocation: ScreenActionInvocation(actionId: "emit")
        )
        let scriptResult = await script.dispatch(
            run: run,
            screenId: "survey",
            definition: ScreenControlActionDefinition(
                actionId: "emit",
                binding: .script
            ),
            invocation: ScreenActionInvocation(actionId: "emit")
        )

        XCTAssertEqual(
            declarativeResult.failure,
            .invalidEventName(eventName: "")
        )
        XCTAssertEqual(scriptResult.failure, .invalidEventName(eventName: ""))
    }

    private func incrementingID() -> @Sendable () -> String {
        let values = LockedCounter()
        return { "id_\(values.next())" }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

private extension Result {
    var success: Success? {
        guard case .success(let value) = self else { return nil }
        return value
    }

    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}

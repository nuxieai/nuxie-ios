import XCTest
@_spi(Testing) @testable import Nuxie

final class JourneyStateOwnershipTests: XCTestCase {
    func testFirstPresentationOutcomeWinsWhenSecondTerminalOutcomeFollows() async {
        let journey = makeJourney()
        let firstTransitionAt = Date(timeIntervalSince1970: 1_700_000_100)
        let secondTransitionAt = Date(timeIntervalSince1970: 1_700_000_200)

        let first = await journey.transitionPresentationOutcome(
            reason: .dismissed,
            outcome: .hostDismissed,
            initiatingDistinctId: "host-user",
            at: firstTransitionAt
        )
        XCTAssertNotNil(first)

        let second = await journey.transitionPresentationOutcome(
            reason: .goalMet,
            outcome: .goalMet,
            initiatingDistinctId: "goal-user",
            at: secondTransitionAt
        )
        XCTAssertNil(second)

        let terminal = await journey.snapshot()
        XCTAssertEqual(terminal.exitReason, .dismissed)
        XCTAssertEqual(terminal.completedAt, firstTransitionAt)
        XCTAssertEqual(terminal.terminalPresentationOutcome, .hostDismissed)
        XCTAssertEqual(terminal.terminalInitiatingDistinctId, "host-user")
    }

    func testFirstTerminalTransitionWinsAcrossLocalDiscardAndPresentationEntries() async {
        let journey = makeJourney()
        let discardedAt = Date(timeIntervalSince1970: 1_700_000_100)

        let discarded = await journey.discardLocally(
            terminalStatus: .superseded,
            at: discardedAt
        )
        XCTAssertTrue(discarded)

        let competing = await journey.transitionPresentationOutcome(
            reason: .goalMet,
            outcome: .goalMet,
            initiatingDistinctId: "goal-user",
            at: Date(timeIntervalSince1970: 1_700_000_200)
        )
        XCTAssertNil(competing)

        let terminal = await journey.snapshot()
        XCTAssertEqual(terminal.status, .superseded)
        XCTAssertEqual(terminal.updatedAt, discardedAt)
        XCTAssertNil(terminal.exitReason)
        XCTAssertNil(terminal.terminalPresentationOutcome)
    }

    func testConcurrentUpdatesAreSerializedWithoutLostWrites() async {
        let journey = makeJourney()

        let observedEpochs = await withTaskGroup(
            of: Int.self,
            returning: [Int].self
        ) { group in
            for _ in 0..<100 {
                group.addTask {
                    await journey.update { state in
                        state.epoch += 1
                        return state.epoch
                    }
                }
            }

            var values: [Int] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(observedEpochs.sorted(), Array(1...100))
        let finalState = await journey.snapshot()
        XCTAssertEqual(finalState.epoch, 100)
    }

    func testSnapshotsRemainImmutableAcrossAtomicStateChanges() async {
        let journey = makeJourney()
        let before = await journey.snapshot()
        let updateTime = Date(timeIntervalSince1970: 1_800_000_000)

        await journey.update { state in
            state.status = .paused
            state.executionState.currentNodeId = "wait-for-purchase"
            state.context["phase"] = AnyCodable("waiting")
            state.updatedAt = updateTime
        }

        let after = await journey.snapshot()
        XCTAssertEqual(before.status, .active)
        XCTAssertNil(before.executionState.currentNodeId)
        XCTAssertNil(before.context["phase"])

        XCTAssertEqual(after.status, .paused)
        XCTAssertEqual(after.executionState.currentNodeId, "wait-for-purchase")
        XCTAssertEqual(after.context["phase"]?.value as? String, "waiting")
        XCTAssertEqual(after.updatedAt, updateTime)
    }

    func testScreenRoutingJournalSurvivesStoreReconstruction() async throws {
        let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "journey-routing-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        var snapshot = await makeJourney().snapshot()
        let batch = ScreenEmissionBatch(
            journeyId: snapshot.id,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 1,
            presentationEpoch: 4,
            batchSequence: 8,
            previousCommittedBatchSequence: 7,
            invocationId: "invocation-8",
            source: ScreenEmissionSource(
                screenId: "survey",
                actionId: "submit",
                componentId: "submit-button",
                instanceId: "survey-1"
            ),
            emissions: [ScreenEmission(
                id: "event-21",
                sequence: 21,
                occurredAt: "2026-08-19T21:00:00.000Z",
                name: "survey_submitted",
                payload: ["plan": .string("premium")]
            )]
        )
        snapshot.executionState.presentationEpoch = 4
        snapshot.executionState.screenRouting.nextBatchSequence = 9
        snapshot.executionState.screenRouting.nextEmissionSequence = 22
        snapshot.executionState.screenRouting.pendingBatches["8"] = batch
        let continuation = JourneyContinuationStep(
            rootId: "event-21",
            operation: .request(JourneyContinuationRequest(
                rootId: "event-21",
                isPriority: false,
                actions: [.sendEvent(SendEventAction(eventName: "continued"))],
                actionPaths: ["/program/0/onSatisfied/0"],
                hostId: "survey",
                screenId: "survey",
                componentId: nil,
                handlerId: "route:revision",
                instanceId: nil,
                payload: nil,
                requiresTerminalTransfer: false,
                startIndex: 0,
                usesPendingResumeContext: false,
                resume: nil,
                screenRouteAdmissionId: "event-21"
            ))
        )
        snapshot.executionState.prePresentationContinuation = [continuation]
        snapshot.executionState.pendingPurchaseOutlets = PersistedOutcomeOutlets(
            first: [.sendEvent(SendEventAction(eventName: "purchased"))],
            second: nil,
            third: nil,
            screenId: "survey",
            handlerId: "route:revision",
            firstProgramPath: "/program/0/onCompleted",
            screenRouteAdmissionId: "event-21"
        )

        let first = JourneyStore(
            customStoragePath: tempRoot,
            dateProvider: SystemDateProvider()
        )
        try first.saveJourney(snapshot)
        let reconstructed = JourneyStore(
            customStoragePath: tempRoot,
            dateProvider: SystemDateProvider()
        )
        let restored = try XCTUnwrap(reconstructed.loadJourney(id: snapshot.id))

        XCTAssertEqual(restored.stateVersion, JourneyStateEnvelope.currentVersion)
        XCTAssertEqual(restored.executionState.presentationEpoch, 4)
        XCTAssertEqual(restored.executionState.screenRouting.nextBatchSequence, 9)
        XCTAssertEqual(restored.executionState.screenRouting.nextEmissionSequence, 22)
        XCTAssertEqual(restored.executionState.screenRouting.pendingBatches["8"], batch)
        guard case .request(let restoredRequest) = try XCTUnwrap(
            restored.executionState.prePresentationContinuation?.first
        ).operation else {
            return XCTFail("expected restored action request")
        }
        XCTAssertEqual(restoredRequest.actionPaths, ["/program/0/onSatisfied/0"])
        XCTAssertEqual(restoredRequest.screenRouteAdmissionId, "event-21")
        XCTAssertEqual(
            restored.executionState.pendingPurchaseOutlets?.screenRouteAdmissionId,
            "event-21"
        )
    }

    private func makeJourney() -> Journey {
        Journey(
            id: "owned-journey",
            experience: Experience(
                id: "owned-experience",
                versionId: "owned-version",
                name: "Owned state",
                reentry: .everyTime,
                publishedAt: "2026-08-12T00:00:00Z",
                trigger: nil,
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                experienceType: nil
            ),
            distinctId: "owned-user",
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

import XCTest
@testable import Nuxie

final class JourneyStateOwnershipTests: XCTestCase {
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

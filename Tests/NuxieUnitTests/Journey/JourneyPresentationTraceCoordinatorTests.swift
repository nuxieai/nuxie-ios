import Foundation
import XCTest
@testable import Nuxie

final class JourneyPresentationTraceCoordinatorTests: XCTestCase {
    func testCorrelatesAnOrdinaryEventWithItsJourneyPresentation() throws {
        let recorder = InMemoryExperiencePresentationTrace()
        let coordinator = JourneyPresentationTraceCoordinator(recorder: recorder)
        let acceptedAt = timestamp(wallClock: 10, monotonic: 100)
        let trackedAt = timestamp(wallClock: 11, monotonic: 101)
        let matchedAt = timestamp(wallClock: 12, monotonic: 102)
        let requestedAt = timestamp(wallClock: 13, monotonic: 103)

        let correlation = try XCTUnwrap(coordinator.beginTrigger(
            event: "upgrade_tapped",
            at: acceptedAt
        ))
        let consumed = try XCTUnwrap(coordinator.consumeEvent(
            id: correlation.eventId,
            at: trackedAt
        ))
        XCTAssertEqual(consumed, correlation.attempt)

        coordinator.bind(
            consumed,
            toRunId: "journey:0",
            journeyId: "journey",
            at: matchedAt
        )
        let context = try XCTUnwrap(coordinator.beginPresentation(
            runId: "journey:0",
            journeyId: "journey",
            experienceVersionId: "experience-v1",
            at: requestedAt
        ))
        XCTAssertEqual(context.attempt, correlation.attempt)

        // The event handler's deferred completion must not close the routing
        // span a second time after presentation began.
        coordinator.completeRouting(correlation.attempt, at: requestedAt)

        let stages = recorder.events(for: correlation.attempt.id).map(\.stage)
        XCTAssertEqual(stages[0], .triggerAccepted)
        guard case .workStarted(_, .triggerRouting, _) = stages[1] else {
            return XCTFail("Expected the trigger routing span to start")
        }
        XCTAssertEqual(stages[2], .eventTracked(eventId: correlation.eventId))
        XCTAssertEqual(stages[3], .journeyMatched(journeyId: "journey"))
        XCTAssertEqual(
            stages[4],
            .presentationRequested(
                experienceVersionId: "experience-v1",
                route: .journey
            )
        )
        guard case .workCompleted(_, .triggerRouting, _, _) = stages[5] else {
            return XCTFail("Expected the trigger routing span to complete")
        }
        XCTAssertEqual(stages.count, 6)
    }

    func testCompletesRoutingWhenTheEventMatchesNoJourney() throws {
        let recorder = InMemoryExperiencePresentationTrace()
        let coordinator = JourneyPresentationTraceCoordinator(recorder: recorder)
        let correlation = try XCTUnwrap(coordinator.beginTrigger(
            event: "ordinary_event",
            at: timestamp(wallClock: 20, monotonic: 200)
        ))

        _ = coordinator.consumeEvent(
            id: correlation.eventId,
            at: timestamp(wallClock: 21, monotonic: 201)
        )
        coordinator.completeRouting(
            correlation.attempt,
            at: timestamp(wallClock: 22, monotonic: 202)
        )

        let stages = recorder.events(for: correlation.attempt.id).map(\.stage)
        XCTAssertEqual(stages.count, 4)
        guard case .workCompleted(_, .triggerRouting, _, _) = stages.last else {
            return XCTFail("Expected unmatched event routing to complete")
        }
    }

    func testRestoredJourneyClaimsTheExplicitRestorationAttemptOnce() throws {
        let recorder = InMemoryExperiencePresentationTrace()
        let attempt = ExperiencePresentationAttempt(
            id: "restored-attempt",
            triggerEvent: "restore",
            startedAt: Date(timeIntervalSince1970: 30),
            startedAtMonotonicTime: 300
        )
        let coordinator = JourneyPresentationTraceCoordinator(
            recorder: recorder,
            restoredAttempt: attempt
        )

        let first = coordinator.beginPresentation(
            runId: "restored:0",
            journeyId: "restored",
            experienceVersionId: "experience-v1",
            at: timestamp(wallClock: 31, monotonic: 301)
        )
        let second = coordinator.beginPresentation(
            runId: "other:0",
            journeyId: "other",
            experienceVersionId: "experience-v2",
            at: timestamp(wallClock: 32, monotonic: 302)
        )

        XCTAssertEqual(first?.attempt, attempt)
        XCTAssertNil(second)
        XCTAssertEqual(recorder.events(for: attempt.id).map(\.stage), [
            .journeyMatched(journeyId: "restored"),
            .presentationRequested(
                experienceVersionId: "experience-v1",
                route: .journey
            ),
        ])
    }

    private func timestamp(
        wallClock: TimeInterval,
        monotonic: TimeInterval
    ) -> ExperiencePresentationTimestamp {
        ExperiencePresentationTimestamp(
            wallClock: Date(timeIntervalSince1970: wallClock),
            monotonicTime: monotonic
        )
    }
}

import Foundation
import os
import XCTest
@testable import Nuxie

final class ExperiencePresentationSignpostsTests: XCTestCase {
    func testPassesEveryStageToTheQualificationRecorderUnchanged() {
        let downstream = InMemoryExperiencePresentationTrace()
        let recorder = ExperiencePresentationSignposts(downstream: downstream)
        let attempt = ExperiencePresentationAttempt.make(
            triggerEvent: "lesson_opened",
            startedAt: Date(timeIntervalSince1970: 10),
            startedAtMonotonicTime: 100
        )
        let context = ExperiencePresentationTraceContext(
            attempt: attempt,
            recorder: recorder
        )

        XCTAssertTrue(recorder.isEnabled)
        context.recordTriggerAcceptedAndBeginRouting(at: .now())
        let span = context.begin(.artifactAcquisition, attributes: ["phase": "presentation"])
        context.complete(span, attributes: ["prepared_release": "hit"])
        context.record(.revealed)

        let stages = downstream.events(for: attempt.id).map(\.stage)
        XCTAssertEqual(stages.count, 5)
        XCTAssertEqual(stages.first, .triggerAccepted)
        XCTAssertEqual(stages.last, .revealed)
        guard case .workCompleted(let spanId, .artifactAcquisition, _, let attributes) = stages[3] else {
            return XCTFail("expected the completed acquisition span, got \(stages[3])")
        }
        XCTAssertEqual(spanId, span.id)
        XCTAssertEqual(attributes, ["prepared_release": "hit"])
    }

    func testDisabledSignpostsLeaveADisabledTraceDisabled() {
        let recorder = ExperiencePresentationSignposts(
            downstream: DisabledExperiencePresentationTrace(),
            signposter: .disabled
        )
        XCTAssertFalse(recorder.isEnabled)
    }
}

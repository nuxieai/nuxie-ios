import XCTest
@testable import Nuxie

final class ExperienceSemanticTextDraftTests: XCTestCase {
    func testSourceRefreshChangesIdleValueWithoutEmittingAUserCommit() {
        var draft = ExperienceSemanticTextDraft(text: "initial")
        XCTAssertTrue(draft.receiveSourceValue("external"))
        XCTAssertEqual(draft.text, "external")
        XCTAssertEqual(draft.acceptedText, "external")
        XCTAssertNil(draft.requestValueChange())
    }

    func testSourceRefreshPreservesCompositionAndPendingAdmission() throws {
        var draft = ExperienceSemanticTextDraft(text: "initial")
        draft.present(captureID: UUID())
        draft.replaceText("한", isComposing: true)
        XCTAssertFalse(draft.receiveSourceValue("external"))
        let write = try XCTUnwrap(draft.takeWrite())
        XCTAssertFalse(draft.receiveSourceValue("external"))
        XCTAssertNil(draft.finish(write, outcome: .accepted))
        XCTAssertFalse(draft.receiveSourceValue("external"), "Accepted provisional composition still belongs to UIKit")
        XCTAssertEqual(draft.text, "한")
        draft.replaceText("한")
        XCTAssertFalse(draft.receiveSourceValue("external"), "Source refresh cannot consume an unreported user edit")
        XCTAssertEqual(draft.requestValueChange(), "한")
        XCTAssertTrue(draft.receiveSourceValue("external"))
    }

    func testReturnAndEditingEndedRemainDistinctAfterTextAdmission() throws {
        var draft = ExperienceSemanticTextDraft(text: "saved")
        draft.present(captureID: UUID())
        draft.replaceText("Alice")
        let write = try XCTUnwrap(draft.takeWrite())
        XCTAssertNil(draft.requestValueChange())
        XCTAssertEqual(draft.requestEvent(.returnPressed), [])
        XCTAssertEqual(draft.requestEvent(.editingEnded), [])
        XCTAssertEqual(draft.finish(write, outcome: .accepted), "Alice")
        XCTAssertEqual(draft.takeReadyEvents(), [
            .init(kind: .returnPressed, text: "Alice"),
            .init(kind: .editingEnded, text: "Alice"),
        ])
        XCTAssertEqual(draft.takeReadyEvents(), [])
        XCTAssertNil(draft.requestValueChange())
        XCTAssertEqual(draft.requestEvent(.returnPressed), [.init(kind: .returnPressed, text: "Alice")],
            "Repeated Return is intentional even when the text has not changed")
    }

    func testRejectedOrWithdrawnTextCannotDeliverPendingEditingEvents() throws {
        for reject in [false, true] {
            var draft = ExperienceSemanticTextDraft(text: "saved")
            draft.present(captureID: UUID())
            draft.replaceText("late")
            let write = try XCTUnwrap(draft.takeWrite())
            XCTAssertEqual(draft.requestEvent(.editingEnded), [])
            if reject { _ = draft.finish(write, outcome: .rejected) }
            else { draft.withdraw() }
            XCTAssertEqual(draft.takeReadyEvents(), [])
        }
    }

    func testRapidTypingCoalescesAndCommitWaitsForLatestNativeAcceptance() throws {
        var draft = ExperienceSemanticTextDraft(text: "saved")
        draft.present(captureID: UUID())
        draft.replaceText("A")
        let first = try XCTUnwrap(draft.takeWrite())
        draft.replaceText("Alice")
        XCTAssertNil(draft.takeWrite())
        XCTAssertNil(draft.requestValueChange())
        XCTAssertNil(draft.finish(first, outcome: .accepted))
        let latest = try XCTUnwrap(draft.takeWrite())
        XCTAssertEqual(latest.text, "Alice")
        XCTAssertEqual(draft.finish(latest, outcome: .accepted), "Alice")
        XCTAssertNil(draft.requestValueChange())
    }

    func testStaleCaptureRetainsDraftAndResumesOnlyWithFreshCapture() throws {
        var draft = ExperienceSemanticTextDraft(text: "saved")
        draft.present(captureID: UUID())
        draft.replaceText("Alice")
        let write = try XCTUnwrap(draft.takeWrite())
        XCTAssertNil(draft.requestValueChange())
        XCTAssertNil(draft.finish(write, outcome: .staleCapture))
        XCTAssertEqual(draft.text, "Alice")
        XCTAssertEqual(draft.acceptedText, "saved")
        XCTAssertNil(draft.takeWrite())
        let replacement = UUID()
        draft.present(captureID: replacement)
        let retry = try XCTUnwrap(draft.takeWrite())
        XCTAssertEqual(retry.captureID, replacement)
        XCTAssertEqual(retry.text, "Alice")
        XCTAssertEqual(draft.finish(retry, outcome: .accepted), "Alice")
    }

    func testLateStaleResultDoesNotDiscardAlreadyPresentedReplacement() throws {
        var draft = ExperienceSemanticTextDraft(text: "")
        draft.present(captureID: UUID())
        draft.replaceText("new")
        let first = try XCTUnwrap(draft.takeWrite())
        let replacement = UUID()
        draft.present(captureID: replacement)
        XCTAssertNil(draft.finish(first, outcome: .staleCapture))
        XCTAssertEqual(draft.takeWrite()?.captureID, replacement)
    }

    func testPendingCommitCannotPublishAReplacementComposingDraft() throws {
        var draft = ExperienceSemanticTextDraft(text: "saved")
        draft.present(captureID: UUID())
        draft.replaceText("A")
        let first = try XCTUnwrap(draft.takeWrite())
        XCTAssertNil(draft.requestValueChange())
        draft.replaceText("한", isComposing: true)
        XCTAssertNil(draft.finish(first, outcome: .accepted))
        let composing = try XCTUnwrap(draft.takeWrite())
        XCTAssertNil(draft.finish(composing, outcome: .accepted))
        XCTAssertNil(draft.requestValueChange())
        draft.replaceText("한")
        XCTAssertEqual(draft.requestValueChange(), "한")
        XCTAssertNil(draft.requestValueChange())
    }

    func testWithdrawnInFlightWriteReconcilesAcceptedValueOnNextCapture() throws {
        var draft = ExperienceSemanticTextDraft(text: "saved")
        draft.present(captureID: UUID())
        draft.replaceText("provisional")
        let write = try XCTUnwrap(draft.takeWrite())
        draft.withdraw()
        XCTAssertNil(draft.finish(write, outcome: .accepted))
        draft.present(captureID: UUID())
        let reconciliation = try XCTUnwrap(draft.takeWrite())
        XCTAssertEqual(reconciliation.text, "saved")
        XCTAssertNil(draft.finish(reconciliation, outcome: .accepted))
        XCTAssertNil(draft.takeWrite())
        XCTAssertNil(draft.requestValueChange())
    }

    func testWithdrawalAndRejectionRestoreAcceptedTextAndFenceLateCompletion() throws {
        for reject in [false, true] {
            var draft = ExperienceSemanticTextDraft(text: "saved")
            draft.present(captureID: UUID())
            draft.replaceText("late")
            let write = try XCTUnwrap(draft.takeWrite())
            XCTAssertNil(draft.requestValueChange())
            if reject { XCTAssertNil(draft.finish(write, outcome: .rejected)) }
            else { draft.withdraw() }
            XCTAssertNil(draft.finish(write, outcome: .accepted))
            XCTAssertEqual(draft.text, "saved")
            XCTAssertEqual(draft.acceptedText, "saved")
            XCTAssertNil(draft.takeWrite())
            XCTAssertNil(draft.requestValueChange())
        }
    }
}

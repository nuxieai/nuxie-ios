import XCTest
@testable import Nuxie

final class ExperienceSemanticTextDraftTests: XCTestCase {
    func testScriptCommitWaitsForDisplayAcceptanceAndRetriesWithFreshCapture() throws {
        var draft = ExperienceSemanticTextDraft(text: "saved")
        draft.present(captureID: UUID(), commitsThroughNative: true)
        draft.replaceText("静かな夜")
        let display = try XCTUnwrap(draft.takeWrite())
        XCTAssertFalse(display.isCommit)
        XCTAssertNil(draft.requestCommit())
        XCTAssertNil(draft.finish(display, outcome: .accepted))
        let commit = try XCTUnwrap(draft.takeWrite())
        XCTAssertTrue(commit.isCommit)
        XCTAssertEqual(commit.text, "静かな夜")
        XCTAssertNil(draft.finish(commit, outcome: .staleCapture))
        XCTAssertNil(draft.takeWrite())
        let replacement = UUID()
        draft.present(captureID: replacement, commitsThroughNative: true)
        let retry = try XCTUnwrap(draft.takeWrite())
        XCTAssertTrue(retry.isCommit)
        XCTAssertEqual(retry.captureID, replacement)
        XCTAssertEqual(draft.finish(retry, outcome: .accepted), "静かな夜")
        XCTAssertNil(draft.requestCommit())
        XCTAssertNil(draft.takeWrite(), "Repeated blur/submit must not dispatch again")
    }

    func testScriptCommitDoesNotRunForTypingOrCompositionAndWithdrawalFencesCompletion() throws {
        var draft = ExperienceSemanticTextDraft(text: "")
        draft.present(captureID: UUID(), commitsThroughNative: true)
        draft.replaceText("한", isComposing: true)
        let display = try XCTUnwrap(draft.takeWrite())
        XCTAssertNil(draft.finish(display, outcome: .accepted))
        XCTAssertNil(draft.takeWrite(), "Typing alone must not run the script")
        XCTAssertNil(draft.requestCommit())
        XCTAssertNil(draft.takeWrite(), "IME marked text is not a committed edit")
        draft.replaceText("한")
        let commit = try XCTUnwrap(draft.takeWrite())
        XCTAssertTrue(commit.isCommit)
        draft.withdraw()
        XCTAssertNil(draft.finish(commit, outcome: .accepted))
        XCTAssertNil(draft.takeWrite())
    }

    func testRejectedScriptCommitCanBeRequestedAgain() throws {
        var draft = ExperienceSemanticTextDraft(text: "saved")
        draft.present(captureID: UUID(), commitsThroughNative: true)
        draft.replaceText("")
        let display = try XCTUnwrap(draft.takeWrite())
        _ = draft.finish(display, outcome: .accepted)
        XCTAssertNil(draft.requestCommit())
        let commit = try XCTUnwrap(draft.takeWrite())
        XCTAssertNil(draft.finish(commit, outcome: .rejected))
        draft.present(captureID: UUID(), commitsThroughNative: true)
        XCTAssertNil(draft.requestCommit())
        let retry = try XCTUnwrap(draft.takeWrite())
        XCTAssertTrue(retry.isCommit)
        XCTAssertEqual(draft.finish(retry, outcome: .accepted), "")
    }

    func testRapidTypingCoalescesAndCommitWaitsForLatestNativeAcceptance() throws {
        var draft = ExperienceSemanticTextDraft(text: "saved")
        draft.present(captureID: UUID())
        draft.replaceText("A")
        let first = try XCTUnwrap(draft.takeWrite())
        draft.replaceText("Alice")
        XCTAssertNil(draft.takeWrite())
        XCTAssertNil(draft.requestCommit())
        XCTAssertNil(draft.finish(first, outcome: .accepted))
        let latest = try XCTUnwrap(draft.takeWrite())
        XCTAssertEqual(latest.text, "Alice")
        XCTAssertEqual(draft.finish(latest, outcome: .accepted), "Alice")
        XCTAssertNil(draft.requestCommit())
    }

    func testStaleCaptureRetainsDraftAndResumesOnlyWithFreshCapture() throws {
        var draft = ExperienceSemanticTextDraft(text: "saved")
        draft.present(captureID: UUID())
        draft.replaceText("Alice")
        let write = try XCTUnwrap(draft.takeWrite())
        XCTAssertNil(draft.requestCommit())
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
        XCTAssertNil(draft.requestCommit())
        draft.replaceText("한", isComposing: true)
        XCTAssertNil(draft.finish(first, outcome: .accepted))
        let composing = try XCTUnwrap(draft.takeWrite())
        XCTAssertNil(draft.finish(composing, outcome: .accepted))
        XCTAssertNil(draft.requestCommit())
        draft.replaceText("한")
        XCTAssertEqual(draft.requestCommit(), "한")
        XCTAssertNil(draft.requestCommit())
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
        XCTAssertNil(draft.requestCommit())
    }

    func testWithdrawalAndRejectionRestoreAcceptedTextAndFenceLateCompletion() throws {
        for reject in [false, true] {
            var draft = ExperienceSemanticTextDraft(text: "saved")
            draft.present(captureID: UUID())
            draft.replaceText("late")
            let write = try XCTUnwrap(draft.takeWrite())
            XCTAssertNil(draft.requestCommit())
            if reject { XCTAssertNil(draft.finish(write, outcome: .rejected)) }
            else { draft.withdraw() }
            XCTAssertNil(draft.finish(write, outcome: .accepted))
            XCTAssertEqual(draft.text, "saved")
            XCTAssertEqual(draft.acceptedText, "saved")
            XCTAssertNil(draft.takeWrite())
            XCTAssertNil(draft.requestCommit())
        }
    }
}

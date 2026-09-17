import Foundation

/// Serializes one editor's native writes while retaining the latest user draft.
/// A response becomes ready only after its text has been admitted by native code.
struct ExperienceSemanticTextDraft {
    struct Write: Equatable {
        let id: UUID
        let captureID: UUID
        let text: String
    }

    enum Outcome: Sendable { case accepted, staleCapture, rejected }

    private(set) var text: String
    private(set) var acceptedText: String
    private var committedText: String
    private var captureID: UUID?
    private var inFlight: Write?
    private var commitRequested = false
    private var isComposing = false
    private var needsInitialWrite: Bool

    init(text: String, needsInitialWrite: Bool = false) {
        self.needsInitialWrite = needsInitialWrite
        self.text = text
        acceptedText = text
        committedText = text
    }

    mutating func replaceText(_ text: String, isComposing: Bool = false) {
        self.text = text
        self.isComposing = isComposing
    }
    mutating func present(captureID: UUID) { self.captureID = captureID }

    mutating func takeWrite() -> Write? {
        guard inFlight == nil, (needsInitialWrite || text != acceptedText), let captureID else { return nil }
        let write = Write(id: UUID(), captureID: captureID, text: text)
        inFlight = write
        return write
    }

    mutating func requestCommit() -> String? {
        commitRequested = true
        return takeReadyCommit()
    }

    mutating func finish(_ write: Write, outcome: Outcome) -> String? {
        guard inFlight?.id == write.id else { return nil }
        inFlight = nil
        switch outcome {
        case .accepted:
            acceptedText = write.text
            needsInitialWrite = false
        case .staleCapture:
            if captureID == write.captureID { captureID = nil }
        case .rejected:
            withdraw()
            return nil
        }
        return takeReadyCommit()
    }

    mutating func withdraw() {
        // A native write may have completed before its callback reaches this editor.
        // Reconcile that provisional value when a new owner capture is presented.
        if inFlight != nil { needsInitialWrite = true }
        captureID = nil
        inFlight = nil
        text = acceptedText
        isComposing = false
        commitRequested = false
    }

    private mutating func takeReadyCommit() -> String? {
        guard commitRequested, !isComposing, !needsInitialWrite, inFlight == nil, text == acceptedText else { return nil }
        commitRequested = false
        guard committedText != acceptedText else { return nil }
        committedText = acceptedText
        return acceptedText
    }
}

import Foundation

enum ExperienceTextInputEventKind: String, Decodable, Equatable, Sendable {
    case editingEnded = "editing-ended"
    case returnPressed = "return"
}

struct ExperienceTextInputEvent: Equatable {
    let kind: ExperienceTextInputEventKind
    let text: String
}

/// Serializes one editor's native writes while retaining the latest user draft.
/// Value notifications and lifecycle events wait for native admission.
struct ExperienceSemanticTextDraft {
    struct Write: Equatable {
        let id: UUID
        let captureID: UUID
        let text: String
    }

    enum Outcome: Sendable { case accepted, staleCapture, rejected }

    private(set) var text: String
    private(set) var acceptedText: String
    private var notifiedText: String
    private var captureID: UUID?
    private var inFlight: Write?
    private var valueChangeRequested = false
    private var pendingEvents: [ExperienceTextInputEventKind] = []
    private var isComposing = false
    private var needsInitialWrite: Bool

    init(text: String, needsInitialWrite: Bool = false) {
        self.needsInitialWrite = needsInitialWrite
        self.text = text
        acceptedText = text
        notifiedText = text
    }

    mutating func replaceText(_ text: String, isComposing: Bool = false) {
        self.text = text
        self.isComposing = isComposing
    }
    mutating func present(captureID: UUID) { self.captureID = captureID }

    /// A source update can refresh an idle editor, but cannot replace UIKit's
    /// provisional composition or an edit still awaiting native admission.
    mutating func receiveSourceValue(_ value: String) -> Bool {
        guard !isComposing, inFlight == nil, !needsInitialWrite,
              text == acceptedText, acceptedText == notifiedText,
              pendingEvents.isEmpty, !valueChangeRequested else { return false }
        text = value
        acceptedText = value
        notifiedText = value
        return true
    }

    mutating func takeWrite() -> Write? {
        guard inFlight == nil, (needsInitialWrite || text != acceptedText), let captureID else { return nil }
        let write = Write(id: UUID(), captureID: captureID, text: text)
        inFlight = write
        return write
    }

    mutating func requestValueChange() -> String? {
        valueChangeRequested = true
        return takeReadyValueChange()
    }

    /// Lifecycle events are deliberate, even when the value has not changed.
    /// They wait for the same native admission as the value they accompany.
    mutating func requestEvent(_ kind: ExperienceTextInputEventKind) -> [ExperienceTextInputEvent] {
        pendingEvents.append(kind)
        return takeReadyEvents()
    }

    mutating func takeReadyEvents() -> [ExperienceTextInputEvent] {
        guard !isComposing, !needsInitialWrite, inFlight == nil, text == acceptedText else { return [] }
        let events = pendingEvents.map { ExperienceTextInputEvent(kind: $0, text: acceptedText) }
        pendingEvents.removeAll()
        return events
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
        return takeReadyValueChange()
    }

    mutating func withdraw() {
        // A native write may have completed before its callback reaches this editor.
        // Reconcile that provisional value when a new owner capture is presented.
        if inFlight != nil { needsInitialWrite = true }
        captureID = nil
        inFlight = nil
        text = acceptedText
        isComposing = false
        valueChangeRequested = false
        pendingEvents.removeAll()
    }

    private mutating func takeReadyValueChange() -> String? {
        guard valueChangeRequested, !isComposing, !needsInitialWrite, inFlight == nil, text == acceptedText else { return nil }
        valueChangeRequested = false
        guard notifiedText != acceptedText else { return nil }
        notifiedText = acceptedText
        return acceptedText
    }
}

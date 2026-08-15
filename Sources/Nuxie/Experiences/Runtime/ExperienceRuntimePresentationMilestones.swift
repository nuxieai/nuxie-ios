import Foundation

enum ExperienceShellRevealTransition {
    static func duration(reduceMotion: Bool) -> TimeInterval {
        reduceMotion ? 0 : 0.18
    }
}

/// Evidence emitted after a runtime frame has both rendered successfully and
/// reached the strongest presentation observation available on this platform.
struct ExperienceRuntimePresentedDrawable: Equatable, Sendable {
    enum Provenance: Equatable, Sendable {
        /// Backed by `MTLDrawable.addPresentedHandler` on a physical iOS device.
        case physicalPresentedHandler
        /// A non-device runtime can only observe native render completion, not display scan-out.
        case runtimeCompletionProxy
        /// Reserved for deterministic tests of callback ordering.
        case injectedTestObserver
    }

    let presentedTime: TimeInterval
    let frameNumber: UInt64
    let pixelWidth: UInt32
    let pixelHeight: UInt32
    let drawCalls: UInt64
    let provenance: Provenance

    init(
        presentedTime: TimeInterval,
        frameNumber: UInt64 = 0,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        drawCalls: UInt64,
        provenance: Provenance
    ) {
        self.presentedTime = presentedTime
        self.frameNumber = frameNumber
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.drawCalls = drawCalls
        self.provenance = provenance
    }

    var isConfirmedDisplayPresentation: Bool {
        provenance == .physicalPresentedHandler
    }

    var isComplete: Bool {
        pixelWidth > 0 && pixelHeight > 0 && drawCalls > 0
    }
}

/// Joins renderer and interaction readiness without letting either signal
/// reveal an incomplete Experience on its own.
struct ExperienceRevealGate {
    private var inputIsReady = false
    private var hasCompleteDrawable = false
    private var didReveal = false

    mutating func markInputReady() -> Bool {
        inputIsReady = true
        return claimRevealIfReady()
    }

    mutating func markPresentedDrawable(
        _ drawable: ExperienceRuntimePresentedDrawable
    ) -> Bool {
        guard drawable.isComplete else { return false }
        hasCompleteDrawable = true
        return claimRevealIfReady()
    }

    private mutating func claimRevealIfReady() -> Bool {
        guard inputIsReady, hasCompleteDrawable, !didReveal else { return false }
        didReveal = true
        return true
    }
}

/// Emitted only after a successful native player step consumed a non-empty
/// pointer batch.
struct ExperienceRuntimeAcceptedPointerInput: Equatable, Sendable {
    let eventCount: Int
}

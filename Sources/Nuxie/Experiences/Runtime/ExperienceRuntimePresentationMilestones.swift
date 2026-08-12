import Foundation

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
}

/// Emitted only after a successful native player step consumed a non-empty
/// pointer batch.
struct ExperienceRuntimeAcceptedPointerInput: Equatable, Sendable {
    let eventCount: Int
}

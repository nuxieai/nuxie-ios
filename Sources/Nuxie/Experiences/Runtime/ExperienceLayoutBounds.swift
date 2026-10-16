import CoreGraphics
import Foundation

/// Copies settled bounds from the runtime actor to synchronous UIKit geometry readers.
final class ExperienceLayoutBounds: @unchecked Sendable {
    private let lock = NSLock()
    private var bounds: CGRect

    init(_ bounds: CGRect) { self.bounds = bounds }

    func read() -> CGRect { lock.withLock { bounds } }

    func update(size: CGSize) {
        lock.withLock { bounds.size = size }
    }
}

/// Decides when a fit-content screen measures its content height again. Measuring costs two
/// extra runtime steps, so it runs only after something could have moved the layout, and not
/// while another Journey layer covers the screen. Covering is set from the main actor.
final class ExperienceContentMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var stale = true
    private var covered = false

    /// Something was written or resized that can change the content height.
    func invalidate() { lock.withLock { stale = true } }

    /// A covered screen keeps drawing in its viewport and measures again once revealed.
    func setCovered(_ value: Bool) {
        lock.withLock {
            covered = value
            if !value { stale = true }
        }
    }

    /// Whether to measure on this step. Starting a measurement clears the stale mark.
    func begin(layoutMayHaveChanged: Bool) -> Bool {
        lock.withLock {
            if layoutMayHaveChanged { stale = true }
            guard stale, !covered else { return false }
            stale = false
            return true
        }
    }
}

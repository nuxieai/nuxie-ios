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

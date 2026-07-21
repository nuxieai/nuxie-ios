import Foundation

/// Converts display timestamps into bounded runtime deltas.
///
/// A reset (initial attach, backgrounding, or visibility pause) guarantees the
/// next frame advances by zero instead of including time spent suspended.
struct FlowRuntimeFrameClock {
    private var previousTimestamp: TimeInterval?

    mutating func frame(at timestamp: TimeInterval) -> FlowRuntimeFrameTime {
        guard timestamp.isFinite else {
            return FlowRuntimeFrameTime(
                timestamp: previousTimestamp ?? 0,
                delta: 0
            )
        }
        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return FlowRuntimeFrameTime(timestamp: timestamp, delta: 0)
        }

        let delta = max(0, timestamp - previousTimestamp)
        self.previousTimestamp = max(previousTimestamp, timestamp)
        return FlowRuntimeFrameTime(timestamp: timestamp, delta: delta)
    }

    /// Produces a render time without advancing authored time.
    ///
    /// Once seeded, the clock deliberately retains its prior timestamp. A
    /// text-only render therefore neither regresses time nor consumes elapsed
    /// animation time that the next ordinary display frame must advance.
    mutating func zeroDeltaFrame(at timestamp: TimeInterval) -> FlowRuntimeFrameTime {
        if let previousTimestamp {
            return FlowRuntimeFrameTime(timestamp: previousTimestamp, delta: 0)
        }
        guard timestamp.isFinite else {
            return FlowRuntimeFrameTime(timestamp: 0, delta: 0)
        }
        previousTimestamp = timestamp
        return FlowRuntimeFrameTime(timestamp: timestamp, delta: 0)
    }

    mutating func reset() {
        previousTimestamp = nil
    }
}

enum FlowRuntimeSurfaceSizing {
    static func pixels(
        width: CGFloat,
        height: CGFloat,
        scale: CGFloat
    ) -> FlowRuntimeSurfaceSize {
        FlowRuntimeSurfaceSize(
            pixelWidth: pixels(points: width, scale: scale),
            pixelHeight: pixels(points: height, scale: scale)
        )
    }

    private static func pixels(points: CGFloat, scale: CGFloat) -> UInt32 {
        guard points.isFinite,
              scale.isFinite,
              points > 0,
              scale > 0 else {
            return 0
        }
        let value = ceil(Double(points * scale))
        guard value < Double(UInt32.max) else { return UInt32.max }
        return UInt32(value)
    }
}

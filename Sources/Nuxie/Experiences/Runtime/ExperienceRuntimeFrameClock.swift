import Foundation
import NuxieRuntime

/// Converts display timestamps into bounded runtime deltas.
///
/// A reset (initial attach, backgrounding, or visibility pause) guarantees the
/// next frame advances by zero instead of including time spent suspended.
struct ExperienceRuntimeFrameClock {
    private var previousTimestamp: TimeInterval?

    mutating func frame(at timestamp: TimeInterval) -> ExperienceRuntimeFrameTime {
        guard timestamp.isFinite else {
            return ExperienceRuntimeFrameTime(
                timestamp: previousTimestamp ?? 0,
                delta: 0
            )
        }
        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return ExperienceRuntimeFrameTime(timestamp: timestamp, delta: 0)
        }

        let delta = max(0, timestamp - previousTimestamp)
        self.previousTimestamp = max(previousTimestamp, timestamp)
        return ExperienceRuntimeFrameTime(timestamp: timestamp, delta: delta)
    }

    /// Produces a render time without advancing authored time.
    ///
    /// Once seeded, the clock deliberately retains its prior timestamp. A
    /// text-only render therefore neither regresses time nor consumes elapsed
    /// animation time that the next ordinary display frame must advance.
    mutating func zeroDeltaFrame(at timestamp: TimeInterval) -> ExperienceRuntimeFrameTime {
        if let previousTimestamp {
            return ExperienceRuntimeFrameTime(timestamp: previousTimestamp, delta: 0)
        }
        guard timestamp.isFinite else {
            return ExperienceRuntimeFrameTime(timestamp: 0, delta: 0)
        }
        previousTimestamp = timestamp
        return ExperienceRuntimeFrameTime(timestamp: timestamp, delta: 0)
    }

    mutating func reset() {
        previousTimestamp = nil
    }
}

enum ExperienceRuntimeSurfaceSizing {
    static func pixels(
        width: CGFloat,
        height: CGFloat,
        scale: CGFloat
    ) -> ExperienceRuntimeSurfaceSize {
        ExperienceRuntimeSurfaceSize(
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

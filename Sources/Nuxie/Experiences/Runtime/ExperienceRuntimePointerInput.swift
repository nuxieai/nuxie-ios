#if canImport(UIKit)
import CoreGraphics
import Foundation
import NuxieRuntime

/// Opaque UIKit identity used only while routing input into one runtime session.
/// Native object addresses never cross the runtime boundary.
struct ExperienceRuntimePointerSourceID: Hashable {
    fileprivate let objectID: ObjectIdentifier

    init(_ object: AnyObject) {
        objectID = ObjectIdentifier(object)
    }
}

/// A pointer sample in the surface view's logical coordinate space.
struct ExperienceRuntimeViewPointerEvent: Equatable {
    let source: ExperienceRuntimePointerSourceID
    let kind: ExperienceRuntimePointerKind
    let location: CGPoint
    let timestampSeconds: TimeInterval

    init(
        source: ExperienceRuntimePointerSourceID,
        kind: ExperienceRuntimePointerKind,
        location: CGPoint,
        timestampSeconds: TimeInterval = 0
    ) {
        self.source = source
        self.kind = kind
        self.location = location
        self.timestampSeconds = timestampSeconds
    }
}

/// Owns the bounded UIKit-to-runtime identity table for one live session.
/// IDs are stable for an active pointer, positive, and shared by touch and hover.
struct ExperienceRuntimePointerInputRouter {
    private var idsBySource: [ExperienceRuntimePointerSourceID: Int32] = [:]

    mutating func runtimeEvents(
        for samples: [ExperienceRuntimeViewPointerEvent],
        transform: ExperienceContainCenterTransform
    ) -> [ExperienceRuntimePointerEvent] {
        var events: [ExperienceRuntimePointerEvent] = []
        events.reserveCapacity(min(samples.count, ScreenSessionLimits.pointerEvents))

        for sample in samples {
            let artboardPoint = transform.artboardPoint(fromViewport: sample.location)
            let x = Float(artboardPoint.x)
            let y = Float(artboardPoint.y)
            let abiTimestamp = Float(sample.timestampSeconds)
            guard x.isFinite,
                  y.isFinite,
                  sample.timestampSeconds.isFinite,
                  sample.timestampSeconds >= 0,
                  abiTimestamp.isFinite else {
                if sample.kind.isTerminal {
                    idsBySource.removeValue(forKey: sample.source)
                }
                continue
            }

            let pointerID: Int32?
            if sample.kind.isTerminal {
                pointerID = idsBySource.removeValue(forKey: sample.source)
            } else {
                pointerID = existingOrAllocatedID(for: sample.source)
            }
            guard let pointerID else { continue }

            events.append(ExperienceRuntimePointerEvent(
                kind: sample.kind,
                pointerID: pointerID,
                x: x,
                y: y,
                timestampSeconds: sample.timestampSeconds
            ))
        }
        return events
    }

    mutating func reset() {
        idsBySource.removeAll(keepingCapacity: false)
    }

    private mutating func existingOrAllocatedID(
        for source: ExperienceRuntimePointerSourceID
    ) -> Int32? {
        if let existing = idsBySource[source] {
            return existing
        }
        guard idsBySource.count < ScreenSessionLimits.pointerEvents else {
            return nil
        }

        let used = Set(idsBySource.values)
        for candidate in Int32(1)...Int32(ScreenSessionLimits.pointerEvents) {
            guard !used.contains(candidate) else { continue }
            idsBySource[source] = candidate
            return candidate
        }
        return nil
    }
}

private extension ExperienceRuntimePointerKind {
    var isTerminal: Bool {
        switch self {
        case .up, .cancel, .exit:
            true
        case .down, .move:
            false
        }
    }
}
#endif

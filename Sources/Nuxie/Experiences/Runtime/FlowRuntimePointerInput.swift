#if canImport(UIKit)
import CoreGraphics
import Foundation

/// Opaque UIKit identity used only while routing input into one runtime session.
/// Native object addresses never cross the runtime boundary.
struct FlowRuntimePointerSourceID: Hashable {
    fileprivate let objectID: ObjectIdentifier

    init(_ object: AnyObject) {
        objectID = ObjectIdentifier(object)
    }
}

/// A pointer sample in the surface view's logical coordinate space.
struct FlowRuntimeViewPointerEvent: Equatable {
    let source: FlowRuntimePointerSourceID
    let kind: FlowRuntimePointerKind
    let location: CGPoint
    let timestampSeconds: TimeInterval

    init(
        source: FlowRuntimePointerSourceID,
        kind: FlowRuntimePointerKind,
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
struct FlowRuntimePointerInputRouter {
    private var idsBySource: [FlowRuntimePointerSourceID: Int32] = [:]

    mutating func runtimeEvents(
        for samples: [FlowRuntimeViewPointerEvent],
        transform: FlowContainCenterTransform
    ) -> [FlowRuntimePointerEvent] {
        var events: [FlowRuntimePointerEvent] = []
        events.reserveCapacity(min(samples.count, FlowRuntimeSessionLimits.pointerEvents))

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

            events.append(FlowRuntimePointerEvent(
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
        for source: FlowRuntimePointerSourceID
    ) -> Int32? {
        if let existing = idsBySource[source] {
            return existing
        }
        guard idsBySource.count < FlowRuntimeSessionLimits.pointerEvents else {
            return nil
        }

        let used = Set(idsBySource.values)
        for candidate in Int32(1)...Int32(FlowRuntimeSessionLimits.pointerEvents) {
            guard !used.contains(candidate) else { continue }
            idsBySource[source] = candidate
            return candidate
        }
        return nil
    }
}

private extension FlowRuntimePointerKind {
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

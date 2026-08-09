#if canImport(UIKit)
import CoreGraphics
import Foundation

/// Opaque UIKit identity retained only while one pointer is active.
struct ExperienceRuntimePointerSourceID: Hashable {
    fileprivate let objectID: ObjectIdentifier

    init(_ object: AnyObject) {
        objectID = ObjectIdentifier(object)
    }
}

/// A UIKit pointer sample before projection into authored artboard space.
struct ExperienceRuntimeViewPointerEvent: Equatable {
    let source: ExperienceRuntimePointerSourceID
    let kind: ExperienceInteractivePointerKind
    let location: CGPoint
    let timestampSeconds: TimeInterval

    init(
        source: ExperienceRuntimePointerSourceID,
        kind: ExperienceInteractivePointerKind,
        location: CGPoint,
        timestampSeconds: TimeInterval = 0
    ) {
        self.source = source
        self.kind = kind
        self.location = location
        self.timestampSeconds = timestampSeconds
    }
}

/// MainActor-owned pointer identity and coordinate projection for one screen.
struct ExperienceRuntimePointerInputRouter {
    static let maximumActivePointers = 64

    private var idsBySource: [ExperienceRuntimePointerSourceID: Int32] = [:]

    mutating func runtimeEvents(
        for samples: [ExperienceRuntimeViewPointerEvent],
        transform: ExperienceContainCenterTransform
    ) -> [ExperienceInteractivePointerEvent] {
        var events: [ExperienceInteractivePointerEvent] = []
        events.reserveCapacity(min(samples.count, Self.maximumActivePointers))

        for sample in samples {
            let point = transform.artboardPoint(fromViewport: sample.location)
            let x = Float(point.x)
            let y = Float(point.y)
            let timestamp = Float(sample.timestampSeconds)
            guard x.isFinite,
                  y.isFinite,
                  sample.timestampSeconds.isFinite,
                  sample.timestampSeconds >= 0,
                  timestamp.isFinite else {
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
            events.append(ExperienceInteractivePointerEvent(
                kind: sample.kind,
                x: x,
                y: y,
                pointerID: pointerID,
                timestamp: timestamp
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
        if let existing = idsBySource[source] { return existing }
        guard idsBySource.count < Self.maximumActivePointers else { return nil }

        let used = Set(idsBySource.values)
        for candidate in Int32(1)...Int32(Self.maximumActivePointers)
        where !used.contains(candidate) {
            idsBySource[source] = candidate
            return candidate
        }
        return nil
    }
}

private extension ExperienceInteractivePointerKind {
    var isTerminal: Bool {
        switch self {
        case .up, .exit: true
        case .down, .move: false
        }
    }
}
#endif

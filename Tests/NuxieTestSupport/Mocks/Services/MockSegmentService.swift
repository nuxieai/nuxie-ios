import Foundation
@testable import Nuxie

/// Mock implementation of SegmentService for testing
public actor MockSegmentService: SegmentServiceProtocol {
    private var memberships: [SegmentService.SegmentMembership] = []
    private var segmentChangesContinuation: AsyncStream<SegmentService.SegmentEvaluationResult>.Continuation?
    public nonisolated let segmentChanges: AsyncStream<SegmentService.SegmentEvaluationResult>
    
    public init() {
        var continuation: AsyncStream<SegmentService.SegmentEvaluationResult>.Continuation?
        self.segmentChanges = AsyncStream { cont in
            continuation = cont
        }
        self.segmentChangesContinuation = continuation
    }
    
    deinit {
        segmentChangesContinuation?.finish()
    }
    
    public func getCurrentMemberships() async -> [SegmentService.SegmentMembership] {
        return memberships
    }
    
    public private(set) var updatedSegments: [Segment] = []
    public func updateSegments(_ segments: [Segment], for distinctId: String) async {
        updatedSegments = segments
    }

    @discardableResult
    public func applySeed(
        _ seed: SegmentMembershipSeed?,
        generation: UInt64,
        distinctId: String
    ) async -> SegmentService.SegmentEvaluationResult? {
        guard let seed else { return nil }
        let previousIds = Set(memberships.map(\.segmentId))
        let nextIds = Set(seed.memberships.map(\.segmentId))
        memberships = seed.memberships.map {
            SegmentService.SegmentMembership(
                segmentId: $0.segmentId,
                segmentName: $0.segmentId,
                enteredAt: $0.enteredAt,
                lastEvaluated: seed.evaluatedAt
            )
        }
        let entered = nextIds.subtracting(previousIds).map { testSegment(id: $0) }
        let exited = previousIds.subtracting(nextIds).map { testSegment(id: $0) }
        let remained = nextIds.intersection(previousIds).map { testSegment(id: $0) }
        let result = SegmentService.SegmentEvaluationResult(
            distinctId: distinctId,
            entered: entered,
            exited: exited,
            remained: remained
        )
        if result.hasChanges {
            segmentChangesContinuation?.yield(result)
        }
        return result
    }
    
    public func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        // No-op for tests
    }
    
    public func clearSegments(for distinctId: String) async {
        memberships.removeAll()
    }
    
    public func isInSegment(_ segmentId: String) async -> Bool {
        return memberships.contains { $0.segmentId == segmentId }
    }

    public func isMember(_ segmentId: String) async -> Bool {
        await isInSegment(segmentId)
    }
    
    
    public func enteredAt(_ segmentId: String) async -> Date? {
        return memberships.first { $0.segmentId == segmentId }?.enteredAt
    }
    
    // Test helpers
    public func reset() async {
        memberships.removeAll()
    }
    
    public func setMembership(_ segmentId: String, isMember: Bool) async {
        if isMember {
            // Add if not already present
            if !memberships.contains(where: { $0.segmentId == segmentId }) {
                await addMembership(segmentId: segmentId, segmentName: segmentId)
            }
        } else {
            // Remove if present
            memberships.removeAll { $0.segmentId == segmentId }
        }
    }
    
    public func addMembership(segmentId: String, segmentName: String) async {
        let membership = SegmentService.SegmentMembership(
            segmentId: segmentId,
            segmentName: segmentName,
            enteredAt: Date(),
            lastEvaluated: Date()
        )
        memberships.append(membership)
    }
    
    public func triggerSegmentChange(entered: [Segment], exited: [Segment], remained: [Segment]) async {
        // Update in-memory memberships first so IR checks reflect the change immediately
        for s in entered {
            await addMembership(segmentId: s.id, segmentName: s.name)
        }
        for s in exited {
            memberships.removeAll { $0.segmentId == s.id }
        }
        for s in remained where !memberships.contains(where: { $0.segmentId == s.id }) {
            await addMembership(segmentId: s.id, segmentName: s.name)
        }

        // Then notify listeners
        let result = SegmentService.SegmentEvaluationResult(
            distinctId: "test-user",  // Mock user for testing
            entered: entered,
            exited: exited,
            remained: remained
        )
        segmentChangesContinuation?.yield(result)
    }

    private func testSegment(id: String) -> Segment {
        Segment(
            id: id,
            name: id,
            condition: IREnvelope(
                ir_version: 1,
                engine_min: nil,
                compiled_at: nil,
                expr: .bool(true)
            )
        )
    }
}

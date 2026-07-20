import Foundation

/// Adapter that bridges SegmentServiceProtocol to IRSegmentQueries
public struct IRSegmentQueriesAdapter: IRSegmentQueries {
    private let segmentService: SegmentServiceProtocol
    
    public init(segmentService: SegmentServiceProtocol) {
        self.segmentService = segmentService
    }
    
    public func isMember(_ segmentId: String) async -> Bool {
        return await segmentService.isInSegment(segmentId)
    }
    
    public func enteredAt(_ segmentId: String) async -> Date? {
        return await segmentService.enteredAt(segmentId)
    }
}
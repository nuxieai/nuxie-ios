import Foundation

/// Read/write boundary for the server-owned segment membership mirror.
public protocol SegmentServiceProtocol: AnyObject, Sendable {
    /// Returns the active memberships for the current identity.
    func getCurrentMemberships() async -> [SegmentService.SegmentMembership]
    /// Replaces delivered definitions and activates the specified identity.
    func updateSegments(_ segments: [Segment], for distinctId: String) async

    /// Apply one authoritative profile snapshot. A nil seed means the backend did not make a
    /// membership claim and therefore leaves the mirror unchanged.
    @discardableResult
    func applySeed(
        _ seed: SegmentMembershipSeed?,
        generation: UInt64,
        distinctId: String
    ) async -> SegmentService.SegmentEvaluationResult?

    /// Switches membership state to a new identity.
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async
    /// Clears definitions, memberships, and cached state for an identity.
    func clearSegments(for distinctId: String) async
    /// Emits authoritative membership changes.
    var segmentChanges: AsyncStream<SegmentService.SegmentEvaluationResult> { get }
    /// Returns whether the current identity belongs to a segment.
    func isInSegment(_ segmentId: String) async -> Bool
    /// Alias for `isInSegment(_:)`.
    func isMember(_ segmentId: String) async -> Bool
    /// Returns the server-owned segment entry time, when known.
    func enteredAt(_ segmentId: String) async -> Date?
}

public extension SegmentServiceProtocol {
    /// Default no-op for conformers that do not maintain a server membership mirror.
    @discardableResult
    func applySeed(
        _ seed: SegmentMembershipSeed?,
        generation: UInt64,
        distinctId: String
    ) async -> SegmentService.SegmentEvaluationResult? {
        nil
    }
}

/// Mirrors authoritative memberships delivered with profile snapshots.
///
/// E1 deliberately has no local segment evaluator: event history, timers, and IR cannot mutate
/// this store. This keeps pre-install and cross-device history owned by the server.
public actor SegmentService: SegmentServiceProtocol {
    /// Persisted membership metadata for one segment.
    public struct SegmentMembership: Codable, Equatable, Sendable {
        let segmentId: String
        let segmentName: String
        let enteredAt: Date
        let lastEvaluated: Date

        init(segmentId: String, segmentName: String, enteredAt: Date, lastEvaluated: Date? = nil) {
            self.segmentId = segmentId
            self.segmentName = segmentName
            self.enteredAt = enteredAt
            self.lastEvaluated = lastEvaluated ?? enteredAt
        }
    }

    /// The change set produced by applying an authoritative snapshot.
    public struct SegmentEvaluationResult: Sendable {
        /// Identity to which the snapshot applies.
        public let distinctId: String
        /// Newly active segment definitions.
        public let entered: [Segment]
        /// Segment definitions no longer active.
        public let exited: [Segment]
        /// Segment definitions that remained active.
        public let remained: [Segment]

        /// Whether the snapshot entered or exited any segment.
        public var hasChanges: Bool {
            !entered.isEmpty || !exited.isEmpty
        }

        /// Creates a segment membership change set.
        public init(distinctId: String, entered: [Segment], exited: [Segment], remained: [Segment]) {
            self.distinctId = distinctId
            self.entered = entered
            self.exited = exited
            self.remained = remained
        }
    }

    private var segments: [Segment] = []
    private var memberships: [String: SegmentMembership] = [:]
    private var activeDistinctId: String?
    private var appliedGenerations: [String: UInt64] = [:]
    private let membershipCache: DiskCache<[String: SegmentMembership]>?

    private var segmentChangesContinuation: AsyncStream<SegmentEvaluationResult>.Continuation?
    public let segmentChanges: AsyncStream<SegmentEvaluationResult>

    init() {
        var continuation: AsyncStream<SegmentEvaluationResult>.Continuation?
        segmentChanges = AsyncStream { continuation = $0 }
        segmentChangesContinuation = continuation

        if let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let options = DiskCacheOptions(
                baseDirectory: cachesDirectory,
                subdirectory: "nuxie-segments",
                defaultTTL: nil,
                maxTotalBytes: 10 * 1024 * 1024,
                excludeFromBackup: true,
                fileProtection: .completeUntilFirstUserAuthentication
            )
            do {
                membershipCache = try DiskCache<[String: SegmentMembership]>(options: options)
            } catch {
                membershipCache = nil
                LogWarning("Failed to initialize segment disk cache: \(error)")
            }
        } else {
            membershipCache = nil
        }
    }

    deinit {
        segmentChangesContinuation?.finish()
    }

    public func updateSegments(_ segments: [Segment], for distinctId: String) async {
        await activate(distinctId)
        self.segments = segments
        LogInfo("Updated \(segments.count) server-owned segment definitions for user \(NuxieLogger.shared.logDistinctID(distinctId))")
    }

    @discardableResult
    public func applySeed(
        _ seed: SegmentMembershipSeed?,
        generation: UInt64,
        distinctId: String
    ) async -> SegmentEvaluationResult? {
        guard let seed else {
            return nil
        }
        await activate(distinctId)

        if let applied = appliedGenerations[distinctId], generation <= applied {
            return nil
        }
        appliedGenerations[distinctId] = generation

        let previous = memberships
        var definitionsById: [String: Segment] = [:]
        for segment in segments {
            definitionsById[segment.id] = segment
        }
        var seedById: [String: SeededSegmentMembership] = [:]
        for membership in seed.memberships where definitionsById[membership.segmentId] != nil {
            if let existing = seedById[membership.segmentId] {
                if membership.enteredAt < existing.enteredAt {
                    seedById[membership.segmentId] = membership
                }
            } else {
                seedById[membership.segmentId] = membership
            }
        }

        var next: [String: SegmentMembership] = [:]
        for segment in segments {
            guard let entry = seedById[segment.id] else { continue }
            next[segment.id] = SegmentMembership(
                segmentId: segment.id,
                segmentName: segment.name,
                enteredAt: entry.enteredAt,
                lastEvaluated: seed.evaluatedAt ?? entry.enteredAt
            )
        }
        memberships = next
        await persistMemberships(for: distinctId)

        let entered = segments.filter { previous[$0.id] == nil && next[$0.id] != nil }
        let exited = segments.filter { previous[$0.id] != nil && next[$0.id] == nil }
        let remained = segments.filter { previous[$0.id] != nil && next[$0.id] != nil }
        let result = SegmentEvaluationResult(
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
        if activeDistinctId == oldDistinctId {
            await persistMemberships(for: oldDistinctId)
        }
        activeDistinctId = nil
        memberships = [:]
        segments = []
        await activate(newDistinctId)
    }

    public func clearSegments(for distinctId: String) async {
        if activeDistinctId == distinctId {
            memberships = [:]
            segments = []
        }
        appliedGenerations.removeValue(forKey: distinctId)
        await membershipCache?.remove(forKey: cacheKey(for: distinctId))
    }

    public func getCurrentMemberships() async -> [SegmentMembership] {
        Array(memberships.values).sorted { $0.segmentId < $1.segmentId }
    }

    public func isInSegment(_ segmentId: String) async -> Bool {
        memberships[segmentId] != nil
    }

    public func isMember(_ segmentId: String) async -> Bool {
        memberships[segmentId] != nil
    }

    public func enteredAt(_ segmentId: String) async -> Date? {
        memberships[segmentId]?.enteredAt
    }

    private func activate(_ distinctId: String) async {
        guard activeDistinctId != distinctId else { return }
        if let activeDistinctId {
            await persistMemberships(for: activeDistinctId)
        }
        activeDistinctId = distinctId
        memberships = await membershipCache?.retrieve(
            forKey: cacheKey(for: distinctId),
            allowStale: true
        ) ?? [:]
    }

    private func persistMemberships(for distinctId: String) async {
        guard let membershipCache else { return }
        do {
            try await membershipCache.store(memberships, forKey: cacheKey(for: distinctId))
        } catch {
            LogWarning("Failed to persist segment memberships: \(error)")
        }
    }

    private func cacheKey(for distinctId: String) -> String {
        "segments_\(distinctId)"
    }
}

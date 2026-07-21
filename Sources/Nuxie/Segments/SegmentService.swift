import Foundation

/// Protocol for segment service operations
public protocol SegmentServiceProtocol: AnyObject {
    /// Get current segment memberships for the user
    func getCurrentMemberships() async -> [SegmentService.SegmentMembership]

    /// Update segment definitions for a specific user. Only segments
    /// referenced by the given experiences (trigger conditions, goals —
    /// transitively through other segments' conditions) are evaluated.
    func updateSegments(
        _ segments: [Segment], referencedBy campaigns: [Campaign], for distinctId: String
    ) async

    /// Re-evaluate memberships because an event was committed to the log.
    /// This is the only mid-session membership change detector (Phase 9:
    /// event-driven; the periodic timer is gone). Evaluations coalesce:
    /// events arriving during an in-flight evaluation trigger exactly one
    /// follow-up pass.
    func handleCommittedEvent(_ event: NuxieEvent) async

    /// Handle user change (identity transition)
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async

    /// Clear all segment data for a specific user
    func clearSegments(for distinctId: String) async

    /// Get async stream of segment changes
    var segmentChanges: AsyncStream<SegmentService.SegmentEvaluationResult> { get }

    /// Check if user is in a specific segment
    func isInSegment(_ segmentId: String) async -> Bool

    /// When did the user enter this segment?
    func enteredAt(_ segmentId: String) async -> Date?
}

/// Manages segment evaluation, membership tracking, and change notifications
public actor SegmentService: SegmentServiceProtocol {

    // MARK: - Types

    /// Represents a user's membership in a segment
    public struct SegmentMembership: Codable {
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

    /// Result of segment evaluation
    public struct SegmentEvaluationResult {
        public let distinctId: String     // User this evaluation is for
        public let entered: [Segment]     // Segments user just entered
        public let exited: [Segment]      // Segments user just exited
        public let remained: [Segment]    // Segments user remained in

        public var hasChanges: Bool {
            return !entered.isEmpty || !exited.isEmpty
        }
    }

    // MARK: - Properties

    /// Segments actively evaluated on-device (referenced by cached experiences).
    private var segments: [Segment] = []
    private var memberships: [String: SegmentMembership] = [:] // segmentId -> membership
    private var irCache: [String: IRExpr] = [:] // segmentId -> compiled IR expression
    private let membershipCache: DiskCache<[String: SegmentMembership]>?

    // Constructor-injected collaborators (Phase 4c composition root).
    // Note: eventLog/featureService are still resolved lazily inside
    // IRRuntime.Config.standard to avoid circular dependencies until the
    // final 4c slice.
    private let identityService: IdentityServiceProtocol
    private let dateProvider: DateProviderProtocol
    private let irRuntime: IRRuntime

    // AsyncStream for segment changes
    private var segmentChangesContinuation: AsyncStream<SegmentEvaluationResult>.Continuation?
    public let segmentChanges: AsyncStream<SegmentEvaluationResult>

    // Event-driven evaluation coalescing
    private var isEvaluating = false
    private var pendingEvaluationDistinctId: String?

    // MARK: - Initialization

    init(
        identity: IdentityServiceProtocol,
        dateProvider: DateProviderProtocol,
        irRuntime: IRRuntime
    ) {
        self.identityService = identity
        self.dateProvider = dateProvider
        self.irRuntime = irRuntime

        // Set up AsyncStream
        var continuation: AsyncStream<SegmentEvaluationResult>.Continuation?
        self.segmentChanges = AsyncStream { cont in
            continuation = cont
        }
        self.segmentChangesContinuation = continuation

        // Disk cache for segment memberships (optional)
        if let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cacheOptions = DiskCacheOptions(
                baseDirectory: cachesDirectory,
                subdirectory: "nuxie-segments",
                defaultTTL: nil,  // No TTL for segment memberships
                maxTotalBytes: 10 * 1024 * 1024,  // 10 MB cap
                excludeFromBackup: true,
                fileProtection: .completeUntilFirstUserAuthentication
            )

            do {
                self.membershipCache = try DiskCache<[String: SegmentMembership]>(options: cacheOptions)
                LogDebug("Segment disk cache initialized successfully")
            } catch {
                self.membershipCache = nil
                LogWarning("Failed to initialize segment disk cache, using in-memory only: \(error)")
            }
        } else {
            self.membershipCache = nil
            LogWarning("Could not access caches directory, using in-memory segment storage only")
        }

        LogInfo("SegmentService initialized")
    }

    deinit {
        segmentChangesContinuation?.finish()
    }

    // MARK: - Public Methods - Segment Management

    /// Update segment definitions for a specific user, scoped to the
    /// segments the given experiences reference.
    public func updateSegments(
        _ segments: [Segment], referencedBy campaigns: [Campaign], for distinctId: String
    ) async {
        let active = Self.referencedSegments(from: segments, campaigns: campaigns)
        self.segments = active

        // Cache IR expressions for each active segment
        irCache.removeAll()
        for segment in active {
            guard segment.condition.isSupportedByThisEngine else {
                LogWarning("IR: segment \(segment.name) requires engine >= \(segment.condition.engine_min ?? "?") — membership fail-closed")
                continue  // no cached expr → evaluateSegmentCondition returns false
            }
            irCache[segment.id] = segment.condition.expr
        }

        LogInfo(
            "Updated segment definitions for user \(NuxieLogger.shared.logDistinctID(distinctId)): \(active.count) evaluated of \(segments.count) delivered"
        )

        // Load cached memberships if not already loaded
        if memberships.isEmpty, let cache = membershipCache {
            let cacheKey = getCacheKey(for: distinctId)
            if let cached = await cache.retrieve(forKey: cacheKey) {
                self.memberships = cached
                LogDebug("Loaded \(cached.count) cached segment memberships")
            }
        }

        // Perform evaluation for the specified user. An empty server list
        // propagates deletions: evaluation against zero definitions clears
        // all memberships.
        _ = await performEvaluation(for: distinctId)
    }

    /// The segments experiences can observe: ids referenced by campaign
    /// triggers/goals, expanded transitively through segment conditions that
    /// reference other segments.
    ///
    /// Note on segment-references-segment: membership for a referencing
    /// segment reads the referenced segment's membership from the PREVIOUS
    /// evaluation pass (one-tick lag). This is deliberate — no two-pass
    /// dependency ordering.
    private static func referencedSegments(
        from segments: [Segment], campaigns: [Campaign]
    ) -> [Segment] {
        let byId = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var referenced = Set<String>()
        var frontier = campaigns.reduce(into: Set<String>()) { acc, campaign in
            acc.formUnion(campaign.referencedSegmentIds)
        }

        while !frontier.isEmpty {
            var next = Set<String>()
            for id in frontier where !referenced.contains(id) {
                referenced.insert(id)
                if let segment = byId[id] {
                    next.formUnion(segment.condition.referencedSegmentIds)
                }
            }
            frontier = next.subtracting(referenced)
        }

        // Preserve server delivery order for determinism
        return segments.filter { referenced.contains($0.id) }
    }

    // MARK: - Public Methods - Event-driven evaluation

    public func handleCommittedEvent(_ event: NuxieEvent) async {
        guard !segments.isEmpty else { return }
        // Only the current user's events can change the current memberships
        guard event.distinctId == identityService.getDistinctId() else { return }

        // Coalesce: if an evaluation is running, remember that one more pass
        // is needed and return — the running evaluation re-runs once at the
        // end. Bursts of events cost at most one trailing evaluation.
        if isEvaluating {
            pendingEvaluationDistinctId = event.distinctId
            return
        }

        isEvaluating = true
        defer { isEvaluating = false }

        var target: String? = event.distinctId
        while let distinctId = target {
            _ = await performEvaluation(for: distinctId)
            target = pendingEvaluationDistinctId
            pendingEvaluationDistinctId = nil
        }
    }

    /// Handle user change (identity transition)
    public func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        LogInfo("Handling user change from \(NuxieLogger.shared.logDistinctID(oldDistinctId)) to \(NuxieLogger.shared.logDistinctID(newDistinctId))")

        // Save old user's memberships if needed
        if !memberships.isEmpty, let cache = membershipCache {
            let oldCacheKey = getCacheKey(for: oldDistinctId)
            try? await cache.store(memberships, forKey: oldCacheKey)
        }

        // Load new user's cached memberships if available
        if let cache = membershipCache {
            let newCacheKey = getCacheKey(for: newDistinctId)
            if let cached = await cache.retrieve(forKey: newCacheKey) {
                self.memberships = cached
                LogDebug("Loaded \(cached.count) cached segment memberships for new user")
            } else {
                self.memberships = [:]
            }
        } else {
            self.memberships = [:]
        }

        // Evaluate segments for the new user if we have segment definitions
        if !segments.isEmpty {
            _ = await performEvaluation(for: newDistinctId)
        }
    }

    // MARK: - Public Methods - Membership Queries

    /// Get current segment memberships
    public func getCurrentMemberships() async -> [SegmentMembership] {
        return Array(memberships.values)
    }

    /// Check if user is in a specific segment
    public func isInSegment(_ segmentId: String) async -> Bool {
        return memberships[segmentId] != nil
    }

    /// When did the user enter this segment?
    public func enteredAt(_ segmentId: String) async -> Date? {
        return memberships[segmentId]?.enteredAt
    }

    /// Clear all segment data for a specific user
    public func clearSegments(for distinctId: String) async {
        memberships.removeAll()
        if let cache = membershipCache {
            let cacheKey = getCacheKey(for: distinctId)
            await cache.remove(forKey: cacheKey)
        }
        LogInfo("Cleared segment data for user \(NuxieLogger.shared.logDistinctID(distinctId))")
    }

    // MARK: - Private Methods - Evaluation

    private func performEvaluation(for distinctId: String) async -> SegmentEvaluationResult {
        let now = dateProvider.now()

        var entered: [Segment] = []
        var exited: [Segment] = []
        var remained: [Segment] = []
        var newMemberships: [String: SegmentMembership] = [:]

        // Evaluate each segment
        for segment in segments {
            let qualifies = await evaluateSegmentCondition(segment, at: now)

            if qualifies {
                if let existingMembership = memberships[segment.id] {
                    // User remained in segment
                    remained.append(segment)
                    newMemberships[segment.id] = SegmentMembership(
                        segmentId: existingMembership.segmentId,
                        segmentName: existingMembership.segmentName,
                        enteredAt: existingMembership.enteredAt,
                        lastEvaluated: now
                    )
                } else {
                    // User entered segment
                    entered.append(segment)
                    newMemberships[segment.id] = SegmentMembership(
                        segmentId: segment.id,
                        segmentName: segment.name,
                        enteredAt: now,
                        lastEvaluated: now
                    )
                    LogInfo("User entered segment: \(segment.name)")
                }
            } else if memberships[segment.id] != nil {
                // User exited segment
                exited.append(segment)
                LogInfo("User exited segment: \(segment.name)")
            }
        }

        // Update memberships
        memberships = newMemberships
        await persistMemberships(for: distinctId)

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

    private func evaluateSegmentCondition(_ segment: Segment, at now: Date) async -> Bool {
        guard let expr = irCache[segment.id] else {
            // Unsupported engine_min (or a decode gap): membership fail-closed
            LogWarning("No IR expression cached for segment \(segment.name)")
            return false
        }

        // Adapters query live services; there is no snapshot context to build.
        // `segments: self` so direct-constructed instances (tests) answer
        // their own segment-references-segment queries.
        let cfg = irRuntime.standardConfig(now: now, segments: self)

        do {
            let interpreter = await irRuntime.makeInterpreter(cfg)
            return try await interpreter.evalBool(expr)
        } catch {
            LogError("IR evaluation failed for segment \(segment.name): \(error)")
            return false
        }
    }

    private func persistMemberships(for distinctId: String) async {
        guard let cache = membershipCache else {
            LogDebug("No disk cache available for segment memberships")
            return
        }

        let cacheKey = getCacheKey(for: distinctId)
        do {
            try await cache.store(memberships, forKey: cacheKey)
            LogDebug("Persisted \(memberships.count) segment memberships to disk for user \(NuxieLogger.shared.logDistinctID(distinctId))")
        } catch {
            LogWarning("Failed to persist segment memberships to disk: \(error)")
        }
    }

    /// Generate cache key for a specific user
    private func getCacheKey(for distinctId: String) -> String {
        return "segments_\(distinctId)"
    }
}

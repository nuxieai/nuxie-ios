import Foundation
import FactoryKit

/// Protocol for segment service operations
public protocol SegmentServiceProtocol {
    /// Get current segment memberships for the user
    func getCurrentMemberships() async -> [SegmentService.SegmentMembership]

    /// Update segment definitions for a specific user
    func updateSegments(_ segments: [Segment], for distinctId: String) async

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

    private var segments: [Segment] = []
    private var memberships: [String: SegmentMembership] = [:] // segmentId -> membership
    private var irCache: [String: IRExpr] = [:] // segmentId -> compiled IR expression
    private let membershipCache: DiskCache<[String: SegmentMembership]>?

    // Dependencies
    @Injected(\.identityService) private var identityService: IdentityServiceProtocol
    // Note: eventService/featureService are resolved lazily in
    // evaluateSegmentCondition to avoid circular dependencies.
    @Injected(\.dateProvider) private var dateProvider: DateProviderProtocol
    @Injected(\.sleepProvider) private var sleepProvider: SleepProviderProtocol
    @Injected(\.irRuntime) private var irRuntime: IRRuntime

    // AsyncStream for segment changes
    private var segmentChangesContinuation: AsyncStream<SegmentEvaluationResult>.Continuation?
    public let segmentChanges: AsyncStream<SegmentEvaluationResult>

    // Periodic re-evaluation. This timer is the only mid-session membership
    // change detector until event-driven evaluation lands (cleanup Phase 9);
    // it is internal machinery, not public API.
    private var monitoringTask: Task<Void, Never>?
    private let evaluationInterval: TimeInterval

    // MARK: - Initialization

    init(evaluationInterval: TimeInterval = 60) {
        self.evaluationInterval = evaluationInterval

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
        monitoringTask?.cancel()
        segmentChangesContinuation?.finish()
    }

    // MARK: - Public Methods - Segment Management

    /// Update segment definitions for a specific user
    public func updateSegments(_ segments: [Segment], for distinctId: String) async {
        self.segments = segments

        // Cache IR expressions for each segment
        irCache.removeAll()
        for segment in segments {
            irCache[segment.id] = segment.condition.expr
        }

        LogInfo("Updated \(segments.count) segment definitions with IR expressions for user \(NuxieLogger.shared.logDistinctID(distinctId))")

        // Load cached memberships if not already loaded
        if memberships.isEmpty, let cache = membershipCache {
            let cacheKey = getCacheKey(for: distinctId)
            if let cached = await cache.retrieve(forKey: cacheKey) {
                self.memberships = cached
                LogDebug("Loaded \(cached.count) cached segment memberships")
            }
        }

        // Perform evaluation for the specified user
        _ = await performEvaluation(for: distinctId)

        // Start monitoring if not already running
        if monitoringTask == nil {
            startMonitoring()
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
            startMonitoring()
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

    // MARK: - Private Methods - Monitoring

    private func startMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            guard let self = self else { return }
            LogInfo("Started segment monitoring (interval: \(self.evaluationInterval)s)")
            while !Task.isCancelled {
                do {
                    try await self.sleepProvider.sleep(for: self.evaluationInterval)
                    guard !Task.isCancelled else { break }
                    let distinctId = await self.identityService.getDistinctId()
                    _ = await self.performEvaluation(for: distinctId)
                } catch {
                    // Task was cancelled or sleep interrupted
                    break
                }
            }
            LogInfo("Segment monitoring stopped")
        }
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
            // Should not happen since we cache all segment conditions
            LogWarning("No IR expression cached for segment \(segment.name)")
            return false
        }

        // Adapters query live services; there is no snapshot context to build.
        let userAdapter = IRUserPropsAdapter(identityService: identityService)
        let eventsAdapter = IREventQueriesAdapter(eventService: Container.shared.eventService())
        let segmentsAdapter = IRSegmentQueriesAdapter(segmentService: self)
        // Resolve featureService lazily to break circular dependency
        let featuresAdapter = IRFeatureQueriesAdapter(featureService: Container.shared.featureService())

        let cfg = IRRuntime.Config(
            now: now,
            user: userAdapter,
            events: eventsAdapter,
            segments: segmentsAdapter,
            features: featuresAdapter
        )

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

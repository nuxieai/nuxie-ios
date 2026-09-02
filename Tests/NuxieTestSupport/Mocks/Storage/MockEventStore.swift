import Foundation
import SQLite3
@testable import Nuxie

/// Mock implementation of EventStoreProtocol for testing.
///
/// Thread safety: EventLog awaits these nonisolated-async methods from
/// several tasks (capture worker, delivery flushes, queries), so they run
/// concurrently on the cooperative pool. Every state access goes through
/// one lock — an unsynchronized mock segfaults under real load.
public final class MockEventStore: EventStoreProtocol, @unchecked Sendable {

    public enum InitializeFailure: Equatable, Sendable {
        case none
        case generic
        case invalidSchema
    }

    private let lock = NSLock()

    // Storage (lock-guarded)
    private var _storedEvents: [StoredEvent] = []
    private var _originsByEventId: [String: StoredEventOrigin] = [:]
    private var _pendingIds: Set<String> = []
    private var _deliveredIds: [String] = []
    private var _stableDroppedAt: [String: Date] = [:]
    private var _historyCoverageStart: Date?
    private var _journeyOwnershipFences: [String: Int] = [:]
    private var _unresolvedJourneyOwnershipResponses:
        [String: Set<JourneyEventOwnership>] = [:]
    private var _isInitialized = false
    private var _isClosed = false
    private var _nextCommitSequence: UInt64 = 0

    public var storedEvents: [StoredEvent] {
        get { lock.withLock { _storedEvents } }
        set {
            lock.withLock {
                _storedEvents = newValue
                _originsByEventId = Dictionary(
                    uniqueKeysWithValues: newValue.map { ($0.id, .device) }
                )
            }
        }
    }
    /// Ids currently marked pending delivery (pending inserts minus markDelivered).
    public var pendingIds: Set<String> {
        get { lock.withLock { _pendingIds } }
        set { lock.withLock { _pendingIds = newValue } }
    }
    public var deliveredIds: [String] {
        lock.withLock { _deliveredIds }
    }
    public var stableDroppedIds: Set<String> {
        lock.withLock { Set(_stableDroppedAt.keys) }
    }
    public var historyCoverageStart: Date? {
        get { lock.withLock { _historyCoverageStart } }
        set { lock.withLock { _historyCoverageStart = newValue } }
    }
    public var journeyOwnershipFences: [String: Int] {
        lock.withLock { _journeyOwnershipFences }
    }
    public var unresolvedJourneyOwnershipResponses:
        [String: Set<JourneyEventOwnership>] {
        lock.withLock { _unresolvedJourneyOwnershipResponses }
    }
    public var isInitialized: Bool {
        get { lock.withLock { _isInitialized } }
        set { lock.withLock { _isInitialized = newValue } }
    }
    public var isClosed: Bool {
        get { lock.withLock { _isClosed } }
        set { lock.withLock { _isClosed = newValue } }
    }

    // Error simulation (lock-guarded)
    private var _initializeFailure: InitializeFailure = .none
    private var _shouldFailStore = false
    private var _shouldFailQuery = false
    private var _shouldFailIRQuery = false
    private var _shouldFailMarkDelivered = false
    private var _shouldFailOwnershipFenceRecord = false
    private var _shouldFailUnresolvedJourneyOwnershipResponseRecord = false
    private var _pendingDeliveryQueryDelay: TimeInterval = 0
    private var _pendingInsertDelayNanoseconds: UInt64 = 0
    private var _suspendNextInsert = false
    private var _suspendedInsertIds: Set<String> = []
    private var _suspendedInsertContinuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var _suspendedStableCaptureAfterCommitIds: Set<String> = []
    private var _suspendedStableCaptureAfterCommitContinuations:
        [String: CheckedContinuation<Void, Never>] = [:]
    private var _waitingStableCaptureAfterCommitIds: Set<String> = []
    private var _suspendedStableCaptureBeforeCommitIds: Set<String> = []
    private var _suspendedStableCaptureBeforeCommitContinuations:
        [String: CheckedContinuation<Void, Never>] = [:]
    private var _waitingStableCaptureBeforeCommitIds: Set<String> = []
    private var _stableCaptureDelayNanoseconds: UInt64 = 0
    private var _stableCaptureCommitCallCount = 0
    private var _stableCaptureBatchFailureIndex: Int?

    public var shouldFailInitialize: Bool {
        get { lock.withLock { _initializeFailure != .none } }
        set { lock.withLock { _initializeFailure = newValue ? .generic : .none } }
    }
    public var initializeFailure: InitializeFailure {
        get { lock.withLock { _initializeFailure } }
        set { lock.withLock { _initializeFailure = newValue } }
    }
    public var shouldFailStore: Bool {
        get { lock.withLock { _shouldFailStore } }
        set { lock.withLock { _shouldFailStore = newValue } }
    }
    public var shouldFailQuery: Bool {
        get { lock.withLock { _shouldFailQuery } }
        set { lock.withLock { _shouldFailQuery = newValue } }
    }
    public var shouldFailIRQuery: Bool {
        get { lock.withLock { _shouldFailIRQuery } }
        set { lock.withLock { _shouldFailIRQuery = newValue } }
    }
    public var shouldFailMarkDelivered: Bool {
        get { lock.withLock { _shouldFailMarkDelivered } }
        set { lock.withLock { _shouldFailMarkDelivered = newValue } }
    }
    public var shouldFailOwnershipFenceRecord: Bool {
        get { lock.withLock { _shouldFailOwnershipFenceRecord } }
        set { lock.withLock { _shouldFailOwnershipFenceRecord = newValue } }
    }
    /// Makes unresolved ownership-response marker writes fail independently
    /// from ownership-fence writes.
    public var shouldFailUnresolvedJourneyOwnershipResponseRecord: Bool {
        get { lock.withLock { _shouldFailUnresolvedJourneyOwnershipResponseRecord } }
        set { lock.withLock { _shouldFailUnresolvedJourneyOwnershipResponseRecord = newValue } }
    }
    public var pendingDeliveryQueryDelay: TimeInterval {
        get { lock.withLock { _pendingDeliveryQueryDelay } }
        set { lock.withLock { _pendingDeliveryQueryDelay = newValue } }
    }
    public var pendingInsertDelayNanoseconds: UInt64 {
        get { lock.withLock { _pendingInsertDelayNanoseconds } }
        set { lock.withLock { _pendingInsertDelayNanoseconds = newValue } }
    }

    /// Deterministically holds a selected insert before its durable commit.
    /// Tests use this to interleave EventLog lanes without timing assumptions.
    public func suspendInsert(id: String) {
        _ = lock.withLock { _suspendedInsertIds.insert(id) }
    }

    /// Holds the next insert without requiring the caller to know the event's
    /// generated id in advance.
    public func suspendNextInsert() {
        lock.withLock { _suspendNextInsert = true }
    }

    public var waitingInsertIds: Set<String> {
        lock.withLock { Set(_suspendedInsertContinuations.keys) }
    }

    public func resumeInsert(id: String) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            _suspendedInsertIds.remove(id)
            return _suspendedInsertContinuations.removeValue(forKey: id)
        }
        continuation?.resume()
    }

    /// Holds a stable capture after its row and commit sequence have been
    /// assigned, but before the EventLog receives the commit result. This
    /// lets ordering tests interleave a later commit deterministically.
    public func suspendStableCaptureAfterCommit(id: String) {
        _ = lock.withLock { _suspendedStableCaptureAfterCommitIds.insert(id) }
    }

    /// Holds a stable capture after all async preparation but before its
    /// terminal admission and store mutation.
    public func suspendStableCaptureBeforeCommit(id: String) {
        _ = lock.withLock { _suspendedStableCaptureBeforeCommitIds.insert(id) }
    }

    public func resumeStableCaptureBeforeCommit(id: String) {
        let continuation = lock.withLock {
            _suspendedStableCaptureBeforeCommitIds.remove(id)
            _waitingStableCaptureBeforeCommitIds.remove(id)
            return _suspendedStableCaptureBeforeCommitContinuations
                .removeValue(forKey: id)
        }
        continuation?.resume()
    }

    public func isStableCaptureBeforeCommitWaiting(id: String) -> Bool {
        lock.withLock { _waitingStableCaptureBeforeCommitIds.contains(id) }
    }

    public func resumeStableCaptureAfterCommit(id: String) {
        let continuation = lock.withLock {
            _suspendedStableCaptureAfterCommitIds.remove(id)
            _waitingStableCaptureAfterCommitIds.remove(id)
            return _suspendedStableCaptureAfterCommitContinuations.removeValue(forKey: id)
        }
        continuation?.resume()
    }

    public func isStableCaptureAfterCommitWaiting(id: String) -> Bool {
        lock.withLock { _waitingStableCaptureAfterCommitIds.contains(id) }
    }
    public var stableCaptureDelayNanoseconds: UInt64 {
        get { lock.withLock { _stableCaptureDelayNanoseconds } }
        set { lock.withLock { _stableCaptureDelayNanoseconds = newValue } }
    }
    public var stableCaptureCommitCallCount: Int {
        lock.withLock { _stableCaptureCommitCallCount }
    }
    public var stableCaptureBatchFailureIndex: Int? {
        get { lock.withLock { _stableCaptureBatchFailureIndex } }
        set { lock.withLock { _stableCaptureBatchFailureIndex = newValue } }
    }

    // Call tracking (lock-guarded)
    private var _initializeCallCount = 0
    private var _storeEventCallCount = 0
    private var _getRecentEventsCallCount = 0
    private var _getEventsForUserCallCount = 0
    private var _getEventCountCallCount = 0
    private var _closeCallCount = 0
    private var _reassignEventsCallCount = 0
    private var _journeyOwnershipFenceRecordCallCount = 0
    private var _unresolvedJourneyOwnershipResponseRecordCallCount = 0
    private var _journeyOwnershipFenceWriteCount = 0

    public var initializeCallCount: Int { lock.withLock { _initializeCallCount } }
    public var storeEventCallCount: Int { lock.withLock { _storeEventCallCount } }
    public var getRecentEventsCallCount: Int { lock.withLock { _getRecentEventsCallCount } }
    public var getEventsForUserCallCount: Int { lock.withLock { _getEventsForUserCallCount } }
    public var getEventCountCallCount: Int { lock.withLock { _getEventCountCallCount } }
    public var closeCallCount: Int { lock.withLock { _closeCallCount } }
    public var reassignEventsCallCount: Int { lock.withLock { _reassignEventsCallCount } }
    /// Total attempted ownership-fence writes, including failed attempts.
    public var unresolvedJourneyOwnershipResponseRecordCallCount: Int {
        lock.withLock { _unresolvedJourneyOwnershipResponseRecordCallCount }
    }

    public var journeyOwnershipFenceRecordCallCount: Int {
        lock.withLock { _journeyOwnershipFenceRecordCallCount }
    }
    /// Successful ownership-fence writes.
    public var journeyOwnershipFenceWriteCount: Int {
        lock.withLock { _journeyOwnershipFenceWriteCount }
    }

    // Session tracking

    public init() {}

    private func mockError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "MockEventStore", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: - EventStoreProtocol Implementation

    public func initialize(path: URL?) async throws {
        try lock.withLock {
            _initializeCallCount += 1
            switch _initializeFailure {
            case .none:
                break
            case .generic:
                throw mockError(1, "Mock initialization error")
            case .invalidSchema:
                throw EventStorageError.invalidSchema(EventStoreSchemaError(
                    targetVersion: 2,
                    operation: "validate user_version",
                    sqliteCode: SQLITE_SCHEMA,
                    sqliteMessage: "unsupported test schema"
                ))
            }
            _isInitialized = true
        }
    }

    public func reset() async {
        let suspended = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let suspended = Array(_suspendedInsertContinuations.values)
                + Array(_suspendedStableCaptureAfterCommitContinuations.values)
            _storedEvents.removeAll()
            _originsByEventId.removeAll()
            _pendingIds.removeAll()
            _stableDroppedAt.removeAll()
            _historyCoverageStart = nil
            _journeyOwnershipFences.removeAll()
            _unresolvedJourneyOwnershipResponses.removeAll()
            _isInitialized = false
            _isClosed = false
            _pendingInsertDelayNanoseconds = 0
            _suspendNextInsert = false
            _suspendedInsertIds.removeAll()
            _suspendedInsertContinuations.removeAll()
            _suspendedStableCaptureAfterCommitIds.removeAll()
            _suspendedStableCaptureAfterCommitContinuations.removeAll()
            _waitingStableCaptureAfterCommitIds.removeAll()
            _nextCommitSequence = 0
            _shouldFailOwnershipFenceRecord = false
            return suspended
        }
        suspended.forEach { $0.resume() }
    }

    public func insert(
        _ event: StoredEvent,
        deliveryState: EventDeliveryState,
        origin: StoredEventOrigin,
        assigningCommitSequence: Bool
    ) async throws -> EventStoreInsertCommit {
        let delayNanoseconds = try lock.withLock {
            _storeEventCallCount += 1
            if _shouldFailStore {
                throw mockError(2, "Mock store error")
            }
            return _pendingInsertDelayNanoseconds
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let shouldSuspend = lock.withLock {
            if _suspendNextInsert {
                _suspendNextInsert = false
                _suspendedInsertIds.insert(event.id)
            }
            return _suspendedInsertIds.contains(event.id)
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    guard _suspendedInsertIds.contains(event.id) else { return true }
                    _suspendedInsertContinuations[event.id] = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
        return lock.withLock {
            if let existing = _storedEvents.first(where: { $0.id == event.id }) {
                if !existing.isByteEquivalent(to: event) {
                    LogError(
                        "Event id collision for \(event.id): stored '\(existing.name)', attempted '\(event.name)'"
                    )
                }
                return EventStoreInsertCommit(
                    newlyDurable: false,
                    commitSequence: takeCommitSequence(if: assigningCommitSequence)
                )
            }
            _storedEvents.append(event)
            _originsByEventId[event.id] = origin
            if deliveryState == .pending {
                _pendingIds.insert(event.id)
            }
            return EventStoreInsertCommit(
                newlyDurable: true,
                commitSequence: takeCommitSequence(if: assigningCommitSequence)
            )
        }
    }

    public func queryStableCapture(
        id: String
    ) async throws -> StableEventCaptureOutcome? {
        try lock.withLock {
            if _shouldFailQuery { throw mockError(3, "Mock query error") }
            if let event = _storedEvents.first(where: { $0.id == id }) {
                return .captured(event, isNew: false)
            }
            return _stableDroppedAt[id] != nil ? .dropped : nil
        }
    }

    public func commitStableCapture(
        eventId: String,
        event: StoredEvent?,
        recordedAt: Date,
        ownership: JourneyEventOwnership?,
        assigningCommitSequence: Bool,
        admission: (any StableEventCaptureCommitAdmission)?
    ) async throws -> StableEventCaptureCommit {
        let delayNanoseconds = lock.withLock {
            _stableCaptureCommitCallCount += 1
            return _stableCaptureDelayNanoseconds
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let shouldSuspendBeforeCommit = lock.withLock {
            _suspendedStableCaptureBeforeCommitIds.contains(eventId)
        }
        if shouldSuspendBeforeCommit {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    guard _suspendedStableCaptureBeforeCommitIds
                        .contains(eventId) else {
                        return true
                    }
                    _suspendedStableCaptureBeforeCommitContinuations[eventId] =
                        continuation
                    _waitingStableCaptureBeforeCommitIds.insert(eventId)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
        let operation = { [self] () throws -> StableEventCaptureCommit in
          try lock.withLock { () -> StableEventCaptureCommit in
            _storeEventCallCount += 1
            if _shouldFailStore { throw mockError(2, "Mock store error") }
            if let existing = _storedEvents.first(where: { $0.id == eventId }) {
                return StableEventCaptureCommit(
                    outcome: .captured(existing, isNew: false),
                    commitSequence: takeCommitSequence(if: assigningCommitSequence)
                )
            }
            if _stableDroppedAt[eventId] != nil {
                return StableEventCaptureCommit(
                    outcome: .dropped,
                    commitSequence: takeCommitSequence(if: assigningCommitSequence)
                )
            }
            if let ownership,
               (_journeyOwnershipFences[ownership.journeyId] ?? Int.min)
                >= ownership.epoch {
                return StableEventCaptureCommit(
                    outcome: .ownershipLost,
                    commitSequence: takeCommitSequence(if: assigningCommitSequence)
                )
            }
            if let ownership,
               _unresolvedJourneyOwnershipResponses.values
                .flatMap({ $0 })
                .contains(where: {
                    $0.journeyId == ownership.journeyId
                        && $0.epoch >= ownership.epoch
                }) {
                throw mockError(
                    3,
                    "Mock unresolved journey ownership response"
                )
            }
            guard let event else {
                _stableDroppedAt[eventId] = recordedAt
                return StableEventCaptureCommit(
                    outcome: .dropped,
                    commitSequence: takeCommitSequence(if: assigningCommitSequence)
                )
            }
            _storedEvents.append(event)
            _originsByEventId[eventId] = .device
            _pendingIds.insert(eventId)
            return StableEventCaptureCommit(
                outcome: .captured(event, isNew: true),
                commitSequence: takeCommitSequence(if: assigningCommitSequence)
            )
          }
        }
        let commit: StableEventCaptureCommit
        if let admission {
            guard let admitted = try admission.commitIfCurrent(operation) else {
                throw StableEventCaptureCommitAdmissionError.rejected
            }
            commit = admitted
        } else {
            commit = try operation()
        }
        let shouldSuspend = lock.withLock {
            _suspendedStableCaptureAfterCommitIds.contains(eventId)
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    guard _suspendedStableCaptureAfterCommitIds.contains(eventId) else {
                        return true
                    }
                    _suspendedStableCaptureAfterCommitContinuations[eventId] = continuation
                    _waitingStableCaptureAfterCommitIds.insert(eventId)
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        }
        return commit
    }

    public func commitStableCaptureBatch(
        _ records: [StableEventCaptureRecord],
        assigningCommitSequence: Bool,
        admission: (any StableEventCaptureBatchCommitAdmission)?
    ) async throws -> [StableEventCaptureCommit] {
        let operation = { [self] () throws -> [StableEventCaptureCommit] in
            try lock.withLock {
                if _shouldFailStore { throw mockError(2, "Mock store error") }
                var storedEvents = _storedEvents
                var originsByEventId = _originsByEventId
                var pendingIds = _pendingIds
                var stableDroppedAt = _stableDroppedAt
                var nextCommitSequence = _nextCommitSequence
                var commits: [StableEventCaptureCommit] = []
                commits.reserveCapacity(records.count)

                func takeSequence() -> UInt64? {
                    guard assigningCommitSequence else { return nil }
                    defer { nextCommitSequence &+= 1 }
                    return nextCommitSequence
                }

                for (index, record) in records.enumerated() {
                    if _stableCaptureBatchFailureIndex == index {
                        throw mockError(8, "Mock stable capture batch error")
                    }
                    if let existing = storedEvents.first(where: {
                        $0.id == record.eventId
                    }) {
                        commits.append(.init(
                            outcome: .captured(existing, isNew: false),
                            commitSequence: takeSequence()
                        ))
                        continue
                    }
                    if stableDroppedAt[record.eventId] != nil {
                        commits.append(.init(
                            outcome: .dropped,
                            commitSequence: takeSequence()
                        ))
                        continue
                    }
                    if let ownership = record.ownership,
                       (_journeyOwnershipFences[ownership.journeyId] ?? Int.min)
                        >= ownership.epoch {
                        commits.append(.init(
                            outcome: .ownershipLost,
                            commitSequence: takeSequence()
                        ))
                        continue
                    }
                    if let ownership = record.ownership,
                       _unresolvedJourneyOwnershipResponses.values
                        .flatMap({ $0 })
                        .contains(where: {
                            $0.journeyId == ownership.journeyId
                                && $0.epoch >= ownership.epoch
                        }) {
                        throw mockError(
                            3,
                            "Mock unresolved journey ownership response"
                        )
                    }
                    if let event = record.event {
                        storedEvents.append(event)
                        originsByEventId[record.eventId] = .device
                        pendingIds.insert(record.eventId)
                        commits.append(.init(
                            outcome: .captured(event, isNew: true),
                            commitSequence: takeSequence()
                        ))
                    } else {
                        stableDroppedAt[record.eventId] = record.recordedAt
                        commits.append(.init(
                            outcome: .dropped,
                            commitSequence: takeSequence()
                        ))
                    }
                }

                _stableCaptureCommitCallCount += records.count
                _storeEventCallCount += records.count
                _storedEvents = storedEvents
                _originsByEventId = originsByEventId
                _pendingIds = pendingIds
                _stableDroppedAt = stableDroppedAt
                _nextCommitSequence = nextCommitSequence
                return commits
            }
        }
        if let admission {
            guard let committed = try admission.commitBatchIfCurrent(operation) else {
                throw StableEventCaptureCommitAdmissionError.rejected
            }
            return committed
        }
        return try operation()
    }

    private func takeCommitSequence(if requested: Bool) -> UInt64? {
        guard requested else { return nil }
        defer { _nextCommitSequence &+= 1 }
        return _nextCommitSequence
    }

    public func recordJourneyOwnershipLoss(
        _ ownership: JourneyEventOwnership,
        recordedAt: Date
    ) async throws {
        try lock.withLock {
            _journeyOwnershipFenceRecordCallCount += 1
            if _shouldFailStore || _shouldFailOwnershipFenceRecord {
                throw mockError(2, "Mock ownership fence store error")
            }
            _journeyOwnershipFenceWriteCount += 1
            let current = _journeyOwnershipFences[ownership.journeyId]
            _journeyOwnershipFences[ownership.journeyId] = max(
                current ?? Int.min,
                ownership.epoch
            )
        }
    }

    public func hasJourneyOwnershipLoss(
        _ ownership: JourneyEventOwnership
    ) async throws -> Bool {
        try lock.withLock {
            if _shouldFailQuery { throw mockError(3, "Mock query error") }
            return (_journeyOwnershipFences[ownership.journeyId] ?? Int.min)
                >= ownership.epoch
        }
    }

    public func recordUnresolvedJourneyOwnershipResponse(
        sourceEventId: String,
        ownership: JourneyEventOwnership,
        recordedAt _: Date
    ) async throws {
        lock.withLock { _unresolvedJourneyOwnershipResponseRecordCallCount += 1 }
        try lock.withLock {
            if _shouldFailStore || _shouldFailUnresolvedJourneyOwnershipResponseRecord {
                throw mockError(2, "Mock unresolved ownership response store error")
            }
            _unresolvedJourneyOwnershipResponses[sourceEventId, default: []]
                .insert(ownership)
        }
    }

    public func hasUnresolvedJourneyOwnershipResponse(
        _ ownership: JourneyEventOwnership
    ) async throws -> Bool {
        try lock.withLock {
            if _shouldFailQuery { throw mockError(3, "Mock query error") }
            return _unresolvedJourneyOwnershipResponses.values
                .flatMap { $0 }
                .contains {
                    $0.journeyId == ownership.journeyId
                        && $0.epoch >= ownership.epoch
                }
        }
    }

    public func queryUnresolvedJourneyOwnershipResponse(
        sourceEventId: String
    ) async throws -> [JourneyEventOwnership] {
        try lock.withLock {
            if _shouldFailQuery { throw mockError(3, "Mock query error") }
            return Array(_unresolvedJourneyOwnershipResponses[sourceEventId] ?? [])
        }
    }

    public func clearUnresolvedJourneyOwnershipResponse(
        sourceEventId: String
    ) async throws {
        try lock.withLock {
            if _shouldFailStore {
                throw mockError(2, "Mock unresolved ownership response delete error")
            }
            _unresolvedJourneyOwnershipResponses.removeValue(forKey: sourceEventId)
        }
    }

    public func deleteStableDropsOlderThan(_ olderThan: Date) async throws -> Int {
        lock.withLock {
            let oldIds = _stableDroppedAt.compactMap { id, date in
                date < olderThan ? id : nil
            }
            oldIds.forEach { _stableDroppedAt.removeValue(forKey: $0) }
            return oldIds.count
        }
    }

    public func queryEvent(id: String) async throws -> StoredEvent? {
        try lock.withLock {
            if _shouldFailQuery {
                throw mockError(3, "Mock query error")
            }
            return _storedEvents.first { $0.id == id }
        }
    }

    public func queryRecentEvents(limit: Int) async throws -> [StoredEvent] {
        try lock.withLock {
            _getRecentEventsCallCount += 1
            if _shouldFailQuery {
                throw mockError(3, "Mock query error")
            }
            return Array(_storedEvents.suffix(limit))
        }
    }

    public func queryEventsForUser(_ distinctId: String, limit: Int) async throws -> [StoredEvent] {
        try lock.withLock {
            _getEventsForUserCallCount += 1
            if _shouldFailQuery {
                throw mockError(3, "Mock query error")
            }
            let userEvents = _storedEvents.filter { $0.distinctId == distinctId }
            return Array(userEvents.suffix(limit))
        }
    }

    public func getEventCount() async throws -> Int {
        try lock.withLock {
            _getEventCountCallCount += 1
            if _shouldFailQuery {
                throw mockError(3, "Mock query error")
            }
            return _storedEvents.count
        }
    }

    public func readOrInitializeHistoryCoverage(startingAt: Date) async throws -> Date {
        try lock.withLock {
            if _shouldFailQuery { throw mockError(3, "Mock coverage query error") }
            if let existing = _historyCoverageStart { return existing }
            let normalized = Self.coverageDate(startingAt)
            _historyCoverageStart = normalized
            return normalized
        }
    }

    public func historyCoverageStartingAt() async throws -> Date {
        try lock.withLock {
            if _shouldFailQuery { throw mockError(3, "Mock coverage query error") }
            guard let startingAt = _historyCoverageStart else {
                throw mockError(3, "Mock coverage is not initialized")
            }
            return startingAt
        }
    }

    public func advanceHistoryCoverage(to startingAt: Date) async throws -> Date {
        lock.withLock {
            let normalized = Self.coverageDate(startingAt)
            let advanced = max(_historyCoverageStart ?? normalized, normalized)
            _historyCoverageStart = advanced
            return advanced
        }
    }

    public func pruneHistory(
        keeping: Int,
        olderThan: Date
    ) async throws -> EventHistoryPruneResult {
        try lock.withLock {
            if _shouldFailQuery { throw mockError(3, "Mock coverage query error") }
            guard keeping >= 0 else { throw mockError(7, "Negative retention cap") }
            guard var coverage = _historyCoverageStart else {
                throw mockError(3, "Mock coverage is not initialized")
            }

            let agedIds = Set(_storedEvents
                .filter {
                    $0.timestamp < olderThan
                        && !_pendingIds.contains($0.id)
                        && _originsByEventId[$0.id, default: .device] != .server
                }
                .map(\.id))
            _storedEvents.removeAll { agedIds.contains($0.id) }
            agedIds.forEach { _originsByEventId.removeValue(forKey: $0) }
            if !agedIds.isEmpty { coverage = max(coverage, Self.coverageDate(olderThan)) }

            let overCap = max(0, _storedEvents.count - keeping)
            let countCandidates = _storedEvents
                .filter {
                    !_pendingIds.contains($0.id)
                        && _originsByEventId[$0.id, default: .device] != .server
                }
                .sorted {
                    if $0.timestamp == $1.timestamp { return $0.id < $1.id }
                    return $0.timestamp < $1.timestamp
                }
                .prefix(overCap)
            let countIds = Set(countCandidates.map(\.id))
            if let newestDeleted = countCandidates.map(\.timestamp).max() {
                coverage = max(
                    coverage,
                    Self.coverageDate(newestDeleted.addingTimeInterval(0.001))
                )
            }
            _storedEvents.removeAll { countIds.contains($0.id) }
            countIds.forEach { _originsByEventId.removeValue(forKey: $0) }
            _pendingIds.subtract(countIds)
            _historyCoverageStart = coverage
            return EventHistoryPruneResult(
                countDeleted: countIds.count,
                ageDeleted: agedIds.count,
                coverageStartingAt: coverage
            )
        }
    }

    private static func coverageDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded(.up) / 1_000)
    }

    public func close() async {
        lock.withLock {
            _closeCallCount += 1
            _isClosed = true
        }
    }

    // MARK: - Event Query Methods

    public func hasEvent(name: String, distinctId: String, since: Date?) async throws -> Bool {
        try lock.withLock {
            if _shouldFailQuery || _shouldFailIRQuery {
                throw mockError(3, "Mock query error")
            }
            let userEvents = _storedEvents.filter { $0.distinctId == distinctId && $0.name == name }
            if let since = since {
                return userEvents.contains { $0.timestamp >= since }
            }
            return !userEvents.isEmpty
        }
    }

    public func countEvents(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Int {
        try lock.withLock {
            if _shouldFailQuery || _shouldFailIRQuery {
                throw mockError(3, "Mock query error")
            }
            var userEvents = _storedEvents.filter { $0.distinctId == distinctId && $0.name == name }
            if let since = since {
                userEvents = userEvents.filter { $0.timestamp >= since }
            }
            if let until = until {
                userEvents = userEvents.filter { $0.timestamp <= until }
            }
            return userEvents.count
        }
    }

    public func getLastEventTime(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Date? {
        try lock.withLock {
            if _shouldFailQuery || _shouldFailIRQuery {
                throw mockError(3, "Mock query error")
            }
            var userEvents = _storedEvents.filter { $0.distinctId == distinctId && $0.name == name }
            if let since = since {
                userEvents = userEvents.filter { $0.timestamp >= since }
            }
            if let until = until {
                userEvents = userEvents.filter { $0.timestamp <= until }
            }
            return userEvents.max(by: { $0.timestamp < $1.timestamp })?.timestamp
        }
    }

    public func queryEventsForUser(
        _ distinctId: String, name: String, since: Date?, until: Date?,
        ascending: Bool, limit: Int
    ) async throws -> [StoredEvent] {
        try lock.withLock {
            if _shouldFailQuery || _shouldFailIRQuery {
                throw mockError(3, "Mock IR query error")
            }
            var filtered = _storedEvents.filter { $0.distinctId == distinctId && $0.name == name }
            if let since { filtered = filtered.filter { $0.timestamp >= since } }
            if let until { filtered = filtered.filter { $0.timestamp <= until } }
            filtered.sort { ascending ? $0.timestamp < $1.timestamp : $0.timestamp > $1.timestamp }
            return Array(filtered.prefix(limit))
        }
    }

    public func getFirstEventTime(name: String, distinctId: String, since: Date?, until: Date?) async throws -> Date? {
        try await queryEventsForUser(distinctId, name: name, since: since, until: until, ascending: true, limit: 1).first?.timestamp
    }

    // MARK: - Durable delivery

    public func queryPendingDelivery(limit: Int) async throws -> [StoredEvent] {
        let delay = lock.withLock { _pendingDeliveryQueryDelay }
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        return lock.withLock {
            let pending = _storedEvents
                .filter { _pendingIds.contains($0.id) }
                .sorted { $0.timestamp < $1.timestamp }
            return Array(pending.prefix(limit))
        }
    }

    public func getPendingDeliveryCount() async throws -> Int {
        lock.withLock { _pendingIds.count }
    }

    public func markDelivered(ids: [String]) async throws {
        try lock.withLock {
            if _shouldFailMarkDelivered {
                throw mockError(6, "Mock mark-delivered error")
            }
            _deliveredIds.append(contentsOf: ids)
            for id in ids { _pendingIds.remove(id) }
        }
    }

    public func reassignEvents(from fromUserId: String, to toUserId: String) async throws -> Int {
        try lock.withLock {
            _reassignEventsCallCount += 1
            if _shouldFailQuery {
                throw mockError(5, "Mock reassign error")
            }
            var reassignedCount = 0
            for i in 0..<_storedEvents.count {
                if _storedEvents[i].distinctId == fromUserId {
                    let oldEvent = _storedEvents[i]
                    _storedEvents[i] = StoredEvent(
                        id: oldEvent.id,
                        name: oldEvent.name,
                        properties: oldEvent.properties,
                        timestamp: oldEvent.timestamp,
                        distinctId: toUserId
                    )
                    reassignedCount += 1
                }
            }
            return reassignedCount
        }
    }

    // MARK: - Test Helpers

    public func resetMock() {
        let suspended = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            let suspended = Array(_suspendedInsertContinuations.values)
                + Array(_suspendedStableCaptureAfterCommitContinuations.values)
            _storedEvents.removeAll()
            _originsByEventId.removeAll()
            _pendingIds.removeAll()
            _deliveredIds.removeAll()
            _stableDroppedAt.removeAll()
            _historyCoverageStart = nil
            _journeyOwnershipFences.removeAll()
            _unresolvedJourneyOwnershipResponses.removeAll()
            _isInitialized = false
            _isClosed = false
            _pendingInsertDelayNanoseconds = 0
            _suspendNextInsert = false
            _suspendedInsertIds.removeAll()
            _suspendedInsertContinuations.removeAll()
            _suspendedStableCaptureAfterCommitIds.removeAll()
            _suspendedStableCaptureAfterCommitContinuations.removeAll()
            _waitingStableCaptureAfterCommitIds.removeAll()
            _nextCommitSequence = 0
            _initializeFailure = .none
            _shouldFailStore = false
            _shouldFailQuery = false
            _shouldFailIRQuery = false
            _shouldFailOwnershipFenceRecord = false
            _shouldFailUnresolvedJourneyOwnershipResponseRecord = false
            _initializeCallCount = 0
            _storeEventCallCount = 0
            _getRecentEventsCallCount = 0
            _getEventsForUserCallCount = 0
            _getEventCountCallCount = 0
            _closeCallCount = 0
            _journeyOwnershipFenceRecordCallCount = 0
            _journeyOwnershipFenceWriteCount = 0
            return suspended
        }
        suspended.forEach { $0.resume() }
    }

    public func addTestEvent(name: String, distinctId: String = "test_user", properties: [String: Any] = [:], timestamp: Date = Date()) {
        lock.withLock {
            let event = try! StoredEvent(
                id: UUID.v7().uuidString,
                name: name,
                properties: properties,
                timestamp: timestamp,
                distinctId: distinctId
            )
            _storedEvents.append(event)
            _originsByEventId[event.id] = .device
        }
    }
}

import Foundation
@testable import Nuxie

/// Mock implementation of IdentityService for testing.
///
/// Thread safety: EventLog reads identity from nonisolated `track` callers,
/// its capture worker, and enrichment tasks while tests mutate it mid-test
/// (identify/reset scenarios), so every access is lock-guarded.
public final class MockIdentityService: IdentityServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let identityPublicationLock = NSRecursiveLock()
    private let distinctIdReadSuspended = DispatchSemaphore(value: 0)
    private let distinctIdReadResume = DispatchSemaphore(value: 0)
    private var _distinctId = "test-user"
    private var _anonymousId = "test-anonymous-id"
    private var _userProperties: [String: Any] = [:]
    private var _isUserIdentified = true
    private var _identityFenceGeneration: UInt64 = 0
    private var _distinctIdAfterNextFencedWork: String?
    private var _shouldSuspendNextDistinctIdRead = false
    private var _distinctIdReadsBeforeSuspendingAfterSnapshot: Int?

    public init() {}

    public func getDistinctId() -> String {
        let read: (shouldSuspend: Bool, snapshot: String?) = lock.withLock {
            if let readsBeforeSuspension = _distinctIdReadsBeforeSuspendingAfterSnapshot {
                if readsBeforeSuspension == 0 {
                    _distinctIdReadsBeforeSuspendingAfterSnapshot = nil
                    return (shouldSuspend: true, snapshot: _distinctId)
                }
                _distinctIdReadsBeforeSuspendingAfterSnapshot = readsBeforeSuspension - 1
            }
            let shouldSuspend = _shouldSuspendNextDistinctIdRead
            _shouldSuspendNextDistinctIdRead = false
            return (shouldSuspend: shouldSuspend, snapshot: nil)
        }
        if read.shouldSuspend {
            distinctIdReadSuspended.signal()
            distinctIdReadResume.wait()
        }
        if let snapshot = read.snapshot { return snapshot }
        return lock.withLock { _distinctId }
    }

    public func suspendNextDistinctIdRead() {
        lock.withLock { _shouldSuspendNextDistinctIdRead = true }
    }

    func suspendDistinctIdReadAfterSnapshot(skipping reads: Int) {
        lock.withLock { _distinctIdReadsBeforeSuspendingAfterSnapshot = reads }
    }

    public func waitForSuspendedDistinctIdRead() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [distinctIdReadSuspended] in
                distinctIdReadSuspended.wait()
                continuation.resume()
            }
        }
    }

    public func resumeSuspendedDistinctIdRead() {
        distinctIdReadResume.signal()
    }

    /// Races an identity change against the suspended identity decision. The
    /// result is true only when the change acquired the identity lock before
    /// the guarded work was committed.
    func raceDistinctIdChange(_ distinctId: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                if lock.try() {
                    _distinctId = distinctId
                    _isUserIdentified = true
                    _identityFenceGeneration &+= 1
                    lock.unlock()
                    distinctIdReadResume.signal()
                    continuation.resume(returning: true)
                    return
                }

                distinctIdReadResume.signal()
                lock.withLock {
                    _distinctId = distinctId
                    _isUserIdentified = true
                    _identityFenceGeneration &+= 1
                }
                continuation.resume(returning: false)
            }
        }
    }

    public func getRawDistinctId() -> String? {
        lock.withLock { _isUserIdentified ? _distinctId : nil }
    }

    public func getAnonymousId() -> String {
        lock.withLock { _anonymousId }
    }

    public var isIdentified: Bool {
        lock.withLock { _isUserIdentified }
    }

    public func setDistinctId(_ distinctId: String) {
        identityPublicationLock.withLock {
            lock.withLock {
                if !_isUserIdentified || _distinctId != distinctId {
                    _identityFenceGeneration &+= 1
                }
                _distinctId = distinctId
                _isUserIdentified = true
            }
        }
    }

    public func reset(keepAnonymousId: Bool) {
        onGuardedUserPropertiesWrite = nil
        identityPublicationLock.withLock {
            lock.withLock {
                let previousDistinctId = _distinctId
                let wasIdentified = _isUserIdentified
                if !keepAnonymousId {
                    _anonymousId = UUID.v7().uuidString
                }
                _distinctId = _anonymousId
                _userProperties.removeAll()
                _isUserIdentified = false
                if wasIdentified || _distinctId != previousDistinctId {
                    _identityFenceGeneration &+= 1
                }
            }
        }
    }

    @MainActor
    public func mutateIdentity(
        _ mutation: IdentityMutation,
        publishing publication: (IdentityTransition) -> Void
    ) -> IdentityTransition? {
        identityPublicationLock.withLock {
            let captured = lock.withLock {
                let previous = identitySnapshotLocked()
                switch mutation {
                case .identify(let distinctId):
                    if !_isUserIdentified || _distinctId != distinctId {
                        _identityFenceGeneration &+= 1
                    }
                    _distinctId = distinctId
                    _isUserIdentified = true
                case .reset(let keepAnonymousId):
                    let previousDistinctId = _distinctId
                    let wasIdentified = _isUserIdentified
                    if !keepAnonymousId {
                        _anonymousId = UUID.v7().uuidString
                    }
                    _distinctId = _anonymousId
                    _userProperties.removeAll()
                    _isUserIdentified = false
                    if wasIdentified || _distinctId != previousDistinctId {
                        _identityFenceGeneration &+= 1
                    }
                }
                let transition = IdentityTransition(
                    previous: previous,
                    current: identitySnapshotLocked()
                )
                return (
                    transition,
                    IdentityFenceToken(
                        distinctId: transition.current.distinctId,
                        generation: _identityFenceGeneration
                    )
                )
            }

            publication(captured.0)

            let isStillCurrent = lock.withLock {
                _distinctId == captured.1.distinctId
                    && _identityFenceGeneration == captured.1.generation
            }
            return isStillCurrent ? captured.0 : nil
        }
    }

    public func clearUserCache(distinctId: String?) {
        // No-op for tests
    }

    public func getUserProperties() -> [String: Any] {
        lock.withLock { _userProperties }
    }

    public func setUserProperties(_ properties: [String: Any]) {
        lock.withLock {
            for (key, value) in properties {
                _userProperties[key] = value
            }
        }
    }

    /// Runs after a successful guarded property write, outside the lock.
    /// Lets tests inject an externally concurrent mutation (for example a
    /// runtime-settings locale flip) into the window between a service's
    /// property write and its next admission re-check.
    public var onGuardedUserPropertiesWrite: (@Sendable () -> Void)? {
        get { lock.withLock { _onGuardedUserPropertiesWrite } }
        set { lock.withLock { _onGuardedUserPropertiesWrite = newValue } }
    }
    private var _onGuardedUserPropertiesWrite: (@Sendable () -> Void)?

    @discardableResult
    public func setUserProperties(
        _ properties: [String: Any],
        ifCurrentDistinctIdMatches expectedDistinctId: String
    ) -> Bool {
        let hook = lock.withLock { () -> (@Sendable () -> Void)?? in
            guard _distinctId == expectedDistinctId else { return .none }
            for (key, value) in properties {
                _userProperties[key] = value
            }
            return .some(_onGuardedUserPropertiesWrite)
        }
        guard let hook else { return false }
        hook?()
        return true
    }

    public func performIfCurrentDistinctIdMatches<T>(
        _ expectedDistinctId: String,
        _ work: (IdentitySnapshot) throws -> T
    ) rethrows -> T? {
        try lock.withLock {
            guard _distinctId == expectedDistinctId else { return nil }
            if let readsBeforeSuspension = _distinctIdReadsBeforeSuspendingAfterSnapshot {
                if readsBeforeSuspension == 0 {
                    _distinctIdReadsBeforeSuspendingAfterSnapshot = nil
                    distinctIdReadSuspended.signal()
                    distinctIdReadResume.wait()
                } else {
                    _distinctIdReadsBeforeSuspendingAfterSnapshot = readsBeforeSuspension - 1
                }
            }
            return try work(IdentitySnapshot(
                distinctId: _distinctId,
                userId: _isUserIdentified ? _distinctId : nil,
                anonymousId: _anonymousId,
                isIdentified: _isUserIdentified
            ))
        }
    }

    public func performWithCurrentIdentityFence<T>(
        _ expectedDistinctId: String,
        _ work: (IdentitySnapshot) throws -> T
    ) rethrows -> IdentityFenced<T>? {
        let captured = lock.withLock { () -> (IdentitySnapshot, IdentityFenceToken)? in
            guard _distinctId == expectedDistinctId else { return nil }
            let generation = _identityFenceGeneration
            return (
                identitySnapshotLocked(),
                IdentityFenceToken(
                    distinctId: expectedDistinctId,
                    generation: generation
                )
            )
        }
        guard let captured else { return nil }
        let value = try work(captured.0)
        lock.withLock {
            if let nextDistinctId = _distinctIdAfterNextFencedWork {
                _distinctIdAfterNextFencedWork = nil
                _distinctId = nextDistinctId
                _isUserIdentified = true
                _identityFenceGeneration &+= 1
            }
        }
        return IdentityFenced(value: value, token: captured.1)
    }

    public func performIfCurrentIdentityFenceToken<T>(
        _ token: IdentityFenceToken,
        _ publication: () throws -> T
    ) rethrows -> T? {
        try identityPublicationLock.withLock {
            let isCurrent = lock.withLock {
                _distinctId == token.distinctId
                    && _identityFenceGeneration == token.generation
            }
            guard isCurrent else { return nil }
            let value = try publication()
            let isStillCurrent = lock.withLock {
                _distinctId == token.distinctId
                    && _identityFenceGeneration == token.generation
            }
            return isStillCurrent ? value : nil
        }
    }

    @MainActor
    @discardableResult
    public func publishIfCurrentIdentityFenceToken(
        _ token: IdentityFenceToken,
        _ publication: () -> Void
    ) -> Bool {
        performIfCurrentIdentityFenceToken(token, publication) != nil
    }

    public func setOnceUserProperties(_ properties: [String: Any]) {
        lock.withLock {
            for (key, value) in properties {
                if _userProperties[key] == nil {
                    _userProperties[key] = value
                }
            }
        }
    }

    public func userProperty(for key: String) async -> Any? {
        lock.withLock { _userProperties[key] }
    }

    // Test helpers
    public func reset() {
        reset(keepAnonymousId: false)
        lock.withLock { _userProperties.removeAll() }
    }

    public func setUserProperty(_ key: String, value: Any) {
        lock.withLock { _userProperties[key] = value }
    }

    public func setIsIdentified(_ identified: Bool) {
        identityPublicationLock.withLock {
            lock.withLock {
                if _isUserIdentified != identified {
                    _identityFenceGeneration &+= 1
                }
                _isUserIdentified = identified
            }
        }
    }

    private func identitySnapshotLocked() -> IdentitySnapshot {
        IdentitySnapshot(
            distinctId: _distinctId,
            userId: _isUserIdentified ? _distinctId : nil,
            anonymousId: _anonymousId,
            isIdentified: _isUserIdentified
        )
    }

    public func setAnonymousId(_ id: String) {
        identityPublicationLock.withLock {
            lock.withLock {
                _anonymousId = id
                // If user is not identified, update distinctId to match anonymous ID
                if !_isUserIdentified {
                    if _distinctId != id {
                        _identityFenceGeneration &+= 1
                    }
                    _distinctId = id
                }
            }
        }
    }

    func changeDistinctIdAfterNextFencedWork(to distinctId: String) {
        lock.withLock {
            _distinctIdAfterNextFencedWork = distinctId
        }
    }
}

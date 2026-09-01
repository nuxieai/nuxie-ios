import CryptoKit
import Foundation

struct IdentitySnapshot {
  let distinctId: String
  let userId: String?
  let anonymousId: String
  let isIdentified: Bool
}

extension IdentitySnapshot: Codable, Equatable, Sendable {}

struct IdentityFenceToken: Equatable, Sendable {
  let distinctId: String
  let generation: UInt64
}

struct IdentityFenced<Value> {
  let value: Value
  let token: IdentityFenceToken
}

enum IdentityMutation: Equatable, Sendable {
  case identify(String)
  case reset(keepAnonymousId: Bool)
}

struct IdentityTransition: Equatable, Sendable {
  let previous: IdentitySnapshot
  let current: IdentitySnapshot
}

/// Protocol for managing user identity state
protocol IdentityServiceProtocol: Sendable {
  /// Get the current distinct ID (returns distinct ID if identified, anonymous ID if not)
  func getDistinctId() -> String

  /// Get the raw distinct ID (for identified users only)
  func getRawDistinctId() -> String?

  /// Get the anonymous ID (always available)
  func getAnonymousId() -> String

  /// Check if the user is currently identified
  var isIdentified: Bool { get }

  /// Set distinct ID (identify user)
  func setDistinctId(_ distinctId: String)

  /// Clear distinct ID and optionally anonymous ID (reset)
  func reset(keepAnonymousId: Bool)

  /// Linearizes identity mutation with its synchronous publication. The
  /// publication must admit every durable transition effect before invoking
  /// a reentrant callback. A nil result means only that a nested mutation
  /// superseded this transition as current; its admitted work still stands.
  @MainActor
  func mutateIdentity(
    _ mutation: IdentityMutation,
    publishing publication: (IdentityTransition) -> Void
  ) -> IdentityTransition?

  /// Clear cache for a specific user
  func clearUserCache(distinctId: String?)

  // MARK: - User Properties

  /// Get current user properties
  func getUserProperties() -> [String: Any]

  /// Set user properties (overwrites existing)
  func setUserProperties(_ properties: [String: Any])

  /// Atomically apply properties only while `expectedDistinctId` is still
  /// current. Journey actions use this to avoid crossing an identify/reset
  /// boundary between validation and mutation.
  @discardableResult
  func setUserProperties(
    _ properties: [String: Any],
    ifCurrentDistinctIdMatches expectedDistinctId: String
  ) -> Bool

  /// Atomically performs a synchronous mutation only while the expected
  /// identity is current. The work receives that same locked identity snapshot,
  /// and is linearly ordered with identify/reset.
  func performIfCurrentDistinctIdMatches<T>(
    _ expectedDistinctId: String,
    _ work: (IdentitySnapshot) throws -> T
  ) rethrows -> T?

  func performWithCurrentIdentityFence<T>(
    _ expectedDistinctId: String,
    _ work: (IdentitySnapshot) throws -> T
  ) rethrows -> IdentityFenced<T>?

  /// Performs one synchronous publication while the captured identity fence
  /// remains current. Unlike the UI publication convenience below, this seam
  /// is actor-agnostic so durable stores can linearize a commit with identity
  /// mutation.
  func performIfCurrentIdentityFenceToken<T>(
    _ token: IdentityFenceToken,
    _ publication: () throws -> T
  ) rethrows -> T?

  @MainActor
  @discardableResult
  func publishIfCurrentIdentityFenceToken(
    _ token: IdentityFenceToken,
    _ publication: () -> Void
  ) -> Bool

  /// Set user properties only if they don't exist
  func setOnceUserProperties(_ properties: [String: Any])

  // MARK: - IR Evaluation Support

  /// Get user property by key (for IR evaluation)
  func userProperty(for key: String) async -> Any?
}

/// Thread-safe, synchronous identity store persisted in Application Support.
/// Disk I/O is serialized on a private queue; reads/writes served from an in-memory snapshot.
// @unchecked Sendable: the in-memory snapshot is serialized on `queue`.
final class IdentityService: IdentityServiceProtocol, @unchecked Sendable {

  // MARK: - In-memory snapshot (protected by queue)
  private var distinctId: String?
  private var anonymousId: String?
  private var userPropertiesById: [String: [String: Any]] = [:]  // Properties per user ID
  private var identityFenceGeneration: UInt64 = 0

  // MARK: - Infra
  private let queue = DispatchQueue(label: "com.nuxie.identity", qos: .utility)
  /// Serializes identity mutation with the short check-and-publication window.
  /// Recursive acquisition lets a synchronous publication subscriber identify
  /// or reset without re-entering `queue` while it is held.
  private let identityPublicationLock = NSRecursiveLock()
  private let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
  }()
  private let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()
  private let fileURL: URL

  public init(customStoragePath: URL? = nil) {
    // Determine the base directory
    let baseDir: URL
    if let customPath = customStoragePath {
      // Use custom path with nuxie subdirectory
      baseDir = customPath.appendingPathComponent("nuxie", isDirectory: true)
    } else {
      // Use default Application Support/nuxie directory
      let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
      )
      .first!
      baseDir = appSupport.appendingPathComponent("nuxie", isDirectory: true)
    }

    // Create directory if needed
    try? FileManager.default.createDirectory(
      at: baseDir, withIntermediateDirectories: true, attributes: nil)

    // Set the file URL
    self.fileURL = baseDir.appendingPathComponent("identity.json")

    // Load snapshot synchronously once
    queue.sync {
      loadFromDiskLocked()
      // If no anonymous ID present, create one & persist
      if anonymousId == nil {
        anonymousId = IdentityService.generateAnonymousId()
        persistLocked()
      }
    }
  }

  // MARK: - Public API (synchronous)

  public func getDistinctId() -> String {
    queue.sync {
      distinctId
        ?? (anonymousId ?? IdentityService.generateAnonymousIdAndPersistIfNeeded(self))
    }
  }

  public func getRawDistinctId() -> String? {
    queue.sync { distinctId }
  }

  public var isIdentified: Bool {
    queue.sync { distinctId != nil }
  }

  public func getAnonymousId() -> String {
    queue.sync {
      if let anon = anonymousId { return anon }
      let newAnon = IdentityService.generateAnonymousId()
      anonymousId = newAnon
      persistLocked()
      return newAnon
    }
  }

  public func setDistinctId(_ distinctId: String) {
    identityPublicationLock.withLock {
      queue.sync {
        _ = applyIdentityMutationLocked(.identify(distinctId))
      }
    }
  }

  public func reset(keepAnonymousId: Bool = true) {
    identityPublicationLock.withLock {
      queue.sync {
        _ = applyIdentityMutationLocked(.reset(keepAnonymousId: keepAnonymousId))
      }
    }
  }

  @MainActor
  public func mutateIdentity(
    _ mutation: IdentityMutation,
    publishing publication: (IdentityTransition) -> Void
  ) -> IdentityTransition? {
    // Lock order is publication lock -> identity queue. The queue is released
    // before publication, so Combine/delegate callbacks may safely reenter on
    // this thread through the recursive publication lock.
    identityPublicationLock.withLock {
      let captured = queue.sync {
        let transition = applyIdentityMutationLocked(mutation)
        return (
          transition,
          IdentityFenceToken(
            distinctId: transition.current.distinctId,
            generation: identityFenceGeneration
          )
        )
      }

      publication(captured.0)

      let isStillCurrent = queue.sync {
        getDistinctIdLocked() == captured.1.distinctId
          && identityFenceGeneration == captured.1.generation
      }
      return isStillCurrent ? captured.0 : nil
    }
  }

  public func getUserProperties() -> [String: Any] {
    getUserProperties(for: nil)
  }

  public func getUserProperties(for id: String?) -> [String: Any] {
    queue.sync {
      let key = id ?? getDistinctIdLocked()
      return userPropertiesById[key] ?? [:]
    }
  }

  public func setUserProperties(_ properties: [String: Any]) {
    setUserProperties(properties, for: nil)
  }

  @discardableResult
  public func setUserProperties(
    _ properties: [String: Any],
    ifCurrentDistinctIdMatches expectedDistinctId: String
  ) -> Bool {
    queue.sync {
      guard getDistinctIdLocked() == expectedDistinctId else { return false }
      var currentProps = userPropertiesById[expectedDistinctId] ?? [:]
      for (key, value) in properties { currentProps[key] = value }
      userPropertiesById[expectedDistinctId] = currentProps
      persistLocked()
      LogDebug(
        "Set \(properties.count) user properties for \(NuxieLogger.shared.logDistinctID(expectedDistinctId))"
      )
      return true
    }
  }

  public func performIfCurrentDistinctIdMatches<T>(
    _ expectedDistinctId: String,
    _ work: (IdentitySnapshot) throws -> T
  ) rethrows -> T? {
    try queue.sync {
      guard getDistinctIdLocked() == expectedDistinctId else { return nil }
      return try work(identitySnapshotLocked())
    }
  }

  public func performWithCurrentIdentityFence<T>(
    _ expectedDistinctId: String,
    _ work: (IdentitySnapshot) throws -> T
  ) rethrows -> IdentityFenced<T>? {
    let captured = queue.sync { () -> (IdentitySnapshot, IdentityFenceToken)? in
      guard getDistinctIdLocked() == expectedDistinctId else { return nil }
      return (
        identitySnapshotLocked(),
        IdentityFenceToken(
          distinctId: expectedDistinctId,
          generation: identityFenceGeneration
        )
      )
    }
    guard let captured else { return nil }
    return try IdentityFenced(
      value: work(captured.0),
      token: captured.1
    )
  }

  public func performIfCurrentIdentityFenceToken<T>(
    _ token: IdentityFenceToken,
    _ publication: () throws -> T
  ) rethrows -> T? {
    try identityPublicationLock.withLock {
      let isCurrent = queue.sync {
        getDistinctIdLocked() == token.distinctId
          && identityFenceGeneration == token.generation
      }
      guard isCurrent else { return nil }
      let value = try publication()
      let isStillCurrent = queue.sync {
        getDistinctIdLocked() == token.distinctId
          && identityFenceGeneration == token.generation
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

  public func setUserProperties(_ properties: [String: Any], for id: String?) {
    queue.sync {
      let key = id ?? getDistinctIdLocked()
      var currentProps = userPropertiesById[key] ?? [:]
      for (k, v) in properties { currentProps[k] = v }
      userPropertiesById[key] = currentProps
      persistLocked()
      LogDebug(
        "Set \(properties.count) user properties for \(NuxieLogger.shared.logDistinctID(key))")
    }
  }

  public func setOnceUserProperties(_ properties: [String: Any]) {
    setOnceUserProperties(properties, for: nil)
  }

  public func setOnceUserProperties(_ properties: [String: Any], for id: String?) {
    queue.sync {
      let key = id ?? getDistinctIdLocked()
      var currentProps = userPropertiesById[key] ?? [:]
      var setCount = 0
      for (k, v) in properties where currentProps[k] == nil {
        currentProps[k] = v
        setCount += 1
      }
      if setCount > 0 {
        userPropertiesById[key] = currentProps
        persistLocked()
      }
      LogDebug(
        "Set \(setCount) new user properties for \(NuxieLogger.shared.logDistinctID(key)) (\(properties.count - setCount) existed)"
      )
    }
  }

  public func clearUserCache(distinctId: String?) {
    LogDebug(
      "IdentityService clearUserCache called for \(NuxieLogger.shared.logDistinctID(distinctId)) (noop)"
    )
  }

  // MARK: - IRIdentity Conformance

  /// Get user property by key (for IR evaluation)
  public func userProperty(for key: String) async -> Any? {
    return queue.sync {
      let currentId = getDistinctIdLocked()
      let props = userPropertiesById[currentId] ?? [:]
      return props[key]
    }
  }

  // MARK: - Locked helpers (must be called on `queue`)

  private func getDistinctIdLocked() -> String {
    // Must be called within queue.sync
    return distinctId
      ?? (anonymousId ?? IdentityService.generateAnonymousIdAndPersistIfNeeded(self))
  }

  private func identitySnapshotLocked() -> IdentitySnapshot {
    let anonymousId = anonymousId
      ?? IdentityService.generateAnonymousIdAndPersistIfNeeded(self)
    return IdentitySnapshot(
      distinctId: distinctId ?? anonymousId,
      userId: distinctId,
      anonymousId: anonymousId,
      isIdentified: distinctId != nil
    )
  }

  /// Applies one identity mutation under `queue`. This helper never invokes a
  /// caller callback; observable publication is owned by `mutateIdentity` only
  /// after the queue has been released.
  private func applyIdentityMutationLocked(
    _ mutation: IdentityMutation
  ) -> IdentityTransition {
    let previous = identitySnapshotLocked()

    switch mutation {
    case .identify(let newDistinctId):
      let wasIdentified = previous.isIdentified
      let previousRawDistinctId = distinctId
      distinctId = newDistinctId
      if !wasIdentified || previous.distinctId != newDistinctId {
        identityFenceGeneration &+= 1
      }

      // Migrate properties only for anonymous -> identified.
      if !wasIdentified, previous.distinctId != newDistinctId {
        let oldProperties = userPropertiesById[previous.distinctId] ?? [:]
        let existingNew = userPropertiesById[newDistinctId] ?? [:]
        let merged = oldProperties.merging(existingNew) { _, new in new }
        userPropertiesById[newDistinctId] = merged
        userPropertiesById.removeValue(forKey: previous.distinctId)
        LogDebug(
          "Migrated \(merged.count) user properties from \(NuxieLogger.shared.logDistinctID(previous.distinctId)) to \(NuxieLogger.shared.logDistinctID(newDistinctId))"
        )
      }

      persistLocked()
      LogInfo(
        "Set distinct ID: \(NuxieLogger.shared.logDistinctID(newDistinctId)) (previous: \(NuxieLogger.shared.logDistinctID(previousRawDistinctId)))"
      )

    case .reset(let keepAnonymousId):
      userPropertiesById.removeValue(forKey: previous.distinctId)
      let previousRawDistinctId = distinctId
      distinctId = nil
      if !keepAnonymousId { anonymousId = nil }
      if anonymousId == nil {
        anonymousId = IdentityService.generateAnonymousId()
      }
      if previous.isIdentified || getDistinctIdLocked() != previous.distinctId {
        identityFenceGeneration &+= 1
      }

      persistLocked()
      LogInfo(
        "Reset identity - distinct ID: \(NuxieLogger.shared.logDistinctID(previousRawDistinctId)) -> nil, anonymous kept: \(keepAnonymousId)"
      )
    }

    return IdentityTransition(
      previous: previous,
      current: identitySnapshotLocked()
    )
  }

  private func loadFromDiskLocked() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      LogDebug("No identity file found; will bootstrap on first access")
      return
    }
    do {
      let data = try Data(contentsOf: fileURL)
      let model = try decoder.decode(IdentityDiskModel.self, from: data)
      self.distinctId = model.distinctId
      self.anonymousId = model.anonymousId
      // Convert from AnyCodable to regular dictionary
      var propsById: [String: [String: Any]] = [:]
      for userId in model.userPropertiesById.keys {
        propsById[userId] = model.getUserPropertiesDict(for: userId)
      }
      self.userPropertiesById = propsById
      LogDebug(
        "Loaded identity from disk; distinct: \(NuxieLogger.shared.logDistinctID(distinctId)), anon: \(NuxieLogger.shared.logDistinctID(anonymousId)), props: \(userPropertiesById.count) users"
      )
    } catch {
      LogWarning("Failed to load identity: \(error). Resetting file.")
      try? FileManager.default.removeItem(at: fileURL)
    }
  }

  private func persistLocked() {
    let distinctId = self.distinctId
    let anonymousId = self.anonymousId

    // Convert userPropertiesById -> [String: [String: AnyCodable]] with Date -> String
    var propsById: [String: [String: AnyCodable]] = [:]
    let iso = ISO8601DateFormatter()
    for (userId, props) in userPropertiesById {
      var codableProps: [String: AnyCodable] = [:]
      for (k, v) in props {
        switch v {
        case let d as Date:
          codableProps[k] = AnyCodable(iso.string(from: d))
        default:
          codableProps[k] = AnyCodable(v)
        }
      }
      propsById[userId] = codableProps
    }

    let model = IdentityDiskModel(
      distinctId: distinctId,
      anonymousId: anonymousId,
      userPropertiesById: propsById
    )
    do {
      let data = try encoder.encode(model)
      try data.write(to: fileURL, options: .atomic)
      #if os(iOS) || os(tvOS) || os(watchOS)
        try? FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: fileURL.path
        )
      #endif
    } catch {
      LogWarning("Failed to persist identity: \(error)")
    }
  }

  // MARK: - Anonymous ID helpers

  private static func generateAnonymousId() -> String {
    // Generate a UUIDv7 with hyphens (36 characters)
    return UUID.v7().uuidString
  }

  /// Generates a new anonymous ID and persists if the service didn't have one yet.
  private static func generateAnonymousIdAndPersistIfNeeded(_ service: IdentityService) -> String {
    if let anon = service.anonymousId { return anon }
    let anon = generateAnonymousId()
    service.anonymousId = anon
    service.persistLocked()
    return anon
  }
}

// MARK: - Persistence payload

private struct IdentityDiskModel: Codable {
  let distinctId: String?
  let anonymousId: String?
  let userPropertiesById: [String: [String: AnyCodable]]  // Properties keyed by user ID

  init(
    distinctId: String?, anonymousId: String?, userPropertiesById: [String: [String: AnyCodable]]
  ) {
    self.distinctId = distinctId
    self.anonymousId = anonymousId
    self.userPropertiesById = userPropertiesById
  }

  func getUserPropertiesDict(for userId: String) -> [String: Any] {
    guard let props = userPropertiesById[userId] else { return [:] }
    var out: [String: Any] = [:]
    for (k, v) in props { out[k] = v.value }
    return out
  }
}

import CryptoKit
import Foundation

/// Protocol for managing user identity state
public protocol IdentityServiceProtocol: Sendable {
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

  /// Clear cache for a specific user
  func clearUserCache(distinctId: String?)

  // MARK: - User Properties

  /// Get current user properties
  func getUserProperties() -> [String: Any]

  /// Set user properties (overwrites existing)
  func setUserProperties(_ properties: [String: Any])

  /// Set user properties only if they don't exist
  func setOnceUserProperties(_ properties: [String: Any])

  // MARK: - IR Evaluation Support

  /// Get user property by key (for IR evaluation)
  func userProperty(for key: String) async -> Any?
}

/// Thread-safe, synchronous identity store persisted in Application Support.
/// Disk I/O is serialized on a private queue; reads/writes served from an in-memory snapshot.
// @unchecked Sendable: the in-memory snapshot is serialized on `queue`.
public final class IdentityService: IdentityServiceProtocol, @unchecked Sendable {

  // MARK: - In-memory snapshot (protected by queue)
  private var distinctId: String?
  private var anonymousId: String?
  private var userPropertiesById: [String: [String: Any]] = [:]  // Properties per user ID

  // MARK: - Infra
  private let queue = DispatchQueue(label: "com.nuxie.identity", qos: .utility)
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
    queue.sync {
      // capture previous effective key and whether we were identified
      let oldEffectiveKey = getDistinctIdLocked()
      let wasIdentified = (self.distinctId != nil)

      let prev = self.distinctId
      self.distinctId = distinctId

      // Migrate props only for anon -> identified
      if !wasIdentified, oldEffectiveKey != distinctId {
        let oldProps = userPropertiesById[oldEffectiveKey] ?? [:]
        let existingNew = userPropertiesById[distinctId] ?? [:]
        // Preserve any explicit props already on the new id
        let merged = oldProps.merging(existingNew) { (_, new) in new }
        userPropertiesById[distinctId] = merged
        // Drop the anon copy to avoid duplication
        userPropertiesById.removeValue(forKey: oldEffectiveKey)
        LogDebug(
          "Migrated \(merged.count) user properties from \(NuxieLogger.shared.logDistinctID(oldEffectiveKey)) to \(NuxieLogger.shared.logDistinctID(distinctId))"
        )
      }

      persistLocked()
      LogInfo(
        "Set distinct ID: \(NuxieLogger.shared.logDistinctID(distinctId)) (previous: \(NuxieLogger.shared.logDistinctID(prev)))"
      )
    }
  }

  public func reset(keepAnonymousId: Bool = true) {
    queue.sync {
      let prevEffectiveKey = getDistinctIdLocked()
      let prev = self.distinctId

      // Clear property bag for the previous identity
      userPropertiesById.removeValue(forKey: prevEffectiveKey)

      // Clear identification
      self.distinctId = nil

      // Handle anonymous id lifecycle
      if !keepAnonymousId { self.anonymousId = nil }
      if self.anonymousId == nil {
        self.anonymousId = IdentityService.generateAnonymousId()
      }

      persistLocked()
      LogInfo(
        "Reset identity - distinct ID: \(NuxieLogger.shared.logDistinctID(prev)) -> nil, anonymous kept: \(keepAnonymousId)"
      )
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

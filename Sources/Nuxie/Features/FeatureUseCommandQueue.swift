import CryptoKit
import Foundation

private final class FeatureRecoveryCancellation {
  private let lock = NSLock()
  private var cancelled = false

  var isCancelled: Bool {
    lock.withLock { cancelled }
  }

  func cancel() {
    lock.withLock { cancelled = true }
  }

  func claim() -> FeatureRecoveryAdmission? {
    lock.withLock {
      guard !cancelled else { return nil }
      return FeatureRecoveryAdmission(cancellation: self)
    }
  }

  fileprivate func admit() throws {
    try lock.withLock {
      guard !cancelled else { throw CancellationError() }
    }
  }

  fileprivate func perform<T>(_ work: () throws -> T) throws -> T {
    try lock.withLock {
      guard !cancelled else { throw CancellationError() }
      return try work()
    }
  }
}

extension FeatureRecoveryCancellation: @unchecked Sendable {}

private final class FeatureRecoveryAdmission: @unchecked Sendable {
  private let cancellation: FeatureRecoveryCancellation

  fileprivate init(cancellation: FeatureRecoveryCancellation) {
    self.cancellation = cancellation
  }

  func admit() throws {
    try cancellation.admit()
  }

  func perform<T>(_ work: () throws -> T) throws -> T {
    try cancellation.perform(work)
  }
}

protocol FeatureRecoveryTaskGating: Sendable {
  func waitForRecoveryTaskAdmission() async
}

private struct FeatureUseCommandFile: Codable {
  static let currentVersion = 1

  let version: Int
  var commands: [FeatureUseCommand]
}

private struct FeatureUseApplicationKey: Hashable, Sendable {
  let distinctId: String
  let featureId: String
  let entityId: String?
}

struct FeatureUseCommand: Codable, Sendable {
  struct DurableResult: Codable, Sendable {
    let response: EventResponse
    var reconciliation: Reconciliation?
    let persistedAt: Date?

    init(
      response: EventResponse,
      reconciliation: Reconciliation?,
      persistedAt: Date? = nil
    ) {
      self.response = response
      self.reconciliation = reconciliation
      self.persistedAt = persistedAt
    }
  }

  struct Reconciliation: Codable, Sendable {
    let mirror: Mirror?
  }

  struct Mirror: Codable, Sendable {
    let name: String
    let forwardingName: String
    let distinctId: String
    let properties: [String: AnyCodable]
    let timestamp: Date

    func event(operationId: String) -> NuxieEvent {
      NuxieEvent(
        id: operationId,
        name: name,
        forwardingName: forwardingName,
        distinctId: distinctId,
        properties: properties.mapValues(\.value),
        timestamp: timestamp
      )
    }
  }

  let operationId: String
  let distinctId: String
  let featureId: String
  let amount: Double
  let entityId: String?
  let setUsage: Bool
  let metadata: [String: AnyCodable]?
  let createdAt: Date
  /// Durable lower bound for when the server could have produced a response
  /// to the first delivery. Retries reuse it when they may surface that cached
  /// response instead of treating the retry receipt time as fresh authority.
  var firstDeliveryAttemptAt: Date? = nil
  var result: DurableResult?

  func matches(
    distinctId: String,
    featureId: String,
    amount: Double,
    entityId: String?,
    setUsage: Bool,
    metadata: [String: AnyCodable]?
  ) -> Bool {
    self.distinctId == distinctId
      && self.featureId == featureId
      && self.amount == amount
      && self.entityId == entityId
      && self.setUsage == setUsage
      && canonicalMetadata(self.metadata) == canonicalMetadata(metadata)
  }

  private func canonicalMetadata(_ value: [String: AnyCodable]?) -> Data? {
    guard let value else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(value)
  }
}

protocol FeatureUseCommandStoring: AnyObject, Sendable {
  func load() throws -> [FeatureUseCommand]
  func save(_ commands: [FeatureUseCommand]) throws
}

/// Atomic v1 command journal. UNIV-2670 is pre-GA, so this creates the final
/// schema directly and deliberately has no migration reader.
final class FeatureUseCommandStore: FeatureUseCommandStoring, @unchecked Sendable {
  private let directory: URL
  private let fileURL: URL

  init(
    customStoragePath: URL?,
    appIdentifier: String,
    environment: Environment
  ) {
    let base = customStoragePath ?? FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    let appIdentifierHash = SHA256.hash(data: Data(appIdentifier.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
    directory = base
      .appendingPathComponent("nuxie", isDirectory: true)
      .appendingPathComponent("feature-commands", isDirectory: true)
      .appendingPathComponent(appIdentifierHash, isDirectory: true)
      .appendingPathComponent(environment.rawValue, isDirectory: true)
    fileURL = directory.appendingPathComponent("feature-use-commands-v1.json")
  }

  func load() throws -> [FeatureUseCommand] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let file = try JSONDecoder().decode(
      FeatureUseCommandFile.self,
      from: Data(contentsOf: fileURL)
    )
    guard file.version == FeatureUseCommandFile.currentVersion else {
      throw FeatureUseCommandError.invalidStoreVersion(file.version)
    }
    return file.commands
  }

  func save(_ commands: [FeatureUseCommand]) throws {
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let file = FeatureUseCommandFile(
      version: FeatureUseCommandFile.currentVersion,
      commands: commands
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(file)
    try data.write(
      to: fileURL,
      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
    )
  }
}

enum FeatureUseCommandError: Error, Equatable {
  case invalidStoreVersion(Int)
  case reconciliationNotDurable
}

/// Durable command queue for ordinary authoritative Feature usage.
///
/// The queue persists the full command before its first `/i/event` send. Its
/// UUIDv7 is both the operation ID and wire idempotency key. A decoded result
/// is persisted before local balance/history reconciliation, whose sinks are
/// idempotent under crash replay.
actor FeatureUseCommandQueue {
  private let api: EventTransport
  private let identity: IdentityServiceProtocol
  private let eventLog: EventLogProtocol
  private let featureInfo: FeatureInfo
  private let dateProvider: DateProviderProtocol
  private let store: FeatureUseCommandStoring
  private let recoveryTaskGate: FeatureRecoveryTaskGating?

  private var commands: [FeatureUseCommand]?
  private var inFlight: [String: Task<FeatureUsageResult, Error>] = [:]
  private var recoveryOwnedOperationIds: Set<String> = []
  private var foregroundJoinedRecoveryIds: Set<String> = []
  private var reconcilingApplicationKeys: Set<FeatureUseApplicationKey> = []
  private var isClosed = false

  init(
    api: EventTransport,
    identity: IdentityServiceProtocol,
    eventLog: EventLogProtocol,
    featureInfo: FeatureInfo,
    dateProvider: DateProviderProtocol,
    store: FeatureUseCommandStoring,
    recoveryTaskGate: FeatureRecoveryTaskGating? = nil
  ) {
    self.api = api
    self.identity = identity
    self.eventLog = eventLog
    self.featureInfo = featureInfo
    self.dateProvider = dateProvider
    self.store = store
    self.recoveryTaskGate = recoveryTaskGate
  }

  func use(
    distinctId: String,
    featureId: String,
    amount: Double,
    entityId: String?,
    setUsage: Bool,
    metadata: sending [String: Any]?
  ) async throws -> FeatureUsageResult {
    guard !isClosed else { throw CancellationError() }
    try loadIfNeeded()
    guard identity.getDistinctId() == distinctId else {
      throw CancellationError()
    }
    let encodedMetadata = metadata?.mapValues(AnyCodable.init)

    let command: FeatureUseCommand
    if let existing = commands?.first(where: { candidate in
      // An overlapping identical public call is a new consumption. A durable
      // command recovered from an earlier attempt remains joinable while its
      // relaunch recovery is in flight.
      candidate.result == nil
        && (!inFlight.keys.contains(candidate.operationId)
        || (recoveryOwnedOperationIds.contains(candidate.operationId)
          && !foregroundJoinedRecoveryIds.contains(candidate.operationId)))
        && candidate.matches(
        distinctId: distinctId,
        featureId: featureId,
        amount: amount,
        entityId: entityId,
        setUsage: setUsage,
        metadata: encodedMetadata
        )
    }) {
      command = existing
    } else {
      command = FeatureUseCommand(
        operationId: UUID.v7().uuidString,
        distinctId: distinctId,
        featureId: featureId,
        amount: amount,
        entityId: entityId,
        setUsage: setUsage,
        metadata: encodedMetadata,
        createdAt: dateProvider.now(),
        result: nil
      )
      var updated = commands ?? []
      updated.append(command)
      let admitted = try identity.performIfCurrentDistinctIdMatches(distinctId) {
        try store.save(updated)
        return true
      } ?? false
      guard admitted else { throw CancellationError() }
      commands = updated
    }

    if recoveryOwnedOperationIds.contains(command.operationId),
       inFlight[command.operationId] != nil {
      foregroundJoinedRecoveryIds.insert(command.operationId)
    }
    return try await execute(operationId: command.operationId)
  }

  /// Retries every durable command in capture order. Retryable errors leave
  /// the command intact; terminal command failures are durably retired.
  func recover() async {
    let cancellation = FeatureRecoveryCancellation()
    await withTaskCancellationHandler {
      await recover(cancellation: cancellation)
    } onCancel: {
      cancellation.cancel()
    }
  }

  private func recover(cancellation: FeatureRecoveryCancellation) async {
    guard !Task.isCancelled, !cancellation.isCancelled, !isClosed else { return }
    do {
      try loadIfNeeded()
    } catch {
      LogError("Feature command store unavailable: \(error)")
      return
    }

    for operationId in (commands ?? []).map(\.operationId) {
      guard !Task.isCancelled, !cancellation.isCancelled, !isClosed else { return }
      guard let admission = cancellation.claim() else { return }
      recoveryOwnedOperationIds.insert(operationId)
      defer {
        recoveryOwnedOperationIds.remove(operationId)
        foregroundJoinedRecoveryIds.remove(operationId)
      }
      do {
        _ = try await execute(
          operationId: operationId,
          recoveryAdmission: admission
        )
      } catch is CancellationError {
        if Task.isCancelled || cancellation.isCancelled || isClosed { return }
        // Identity-change reconciliation removes the old command and reports
        // cancellation to its original caller. It must not strand the ordered
        // tail for the currently active identity.
        continue
      } catch {
        let disposition = deliveryDisposition(for: error)
        if disposition == .terminalPoison || disposition == .split {
          LogWarning("Feature command \(operationId) retired after terminal rejection: \(error)")
        } else {
          LogWarning("Feature command \(operationId) remains pending: \(error)")
        }
      }
    }
  }

  func pendingCount() throws -> Int {
    try loadIfNeeded()
    return commands?.count ?? 0
  }

  func close() {
    isClosed = true
    let tasks = Array(inFlight.values)
    inFlight.removeAll()
    tasks.forEach { $0.cancel() }
  }

  private func loadIfNeeded() throws {
    if commands == nil {
      commands = try store.load().sorted {
        if $0.createdAt == $1.createdAt {
          return $0.operationId < $1.operationId
        }
        return $0.createdAt < $1.createdAt
      }
    }
  }

  private func execute(
    operationId: String,
    recoveryAdmission: FeatureRecoveryAdmission? = nil
  ) async throws -> FeatureUsageResult {
    if let existing = inFlight[operationId] {
      return try await existing.value
    }

    let task = Task { [weak self] () throws -> FeatureUsageResult in
      guard let self else { throw CancellationError() }
      if recoveryAdmission != nil {
        await self.recoveryTaskGate?.waitForRecoveryTaskAdmission()
      }
      return try await self.attempt(
        operationId: operationId,
        recoveryAdmission: recoveryAdmission
      )
    }
    inFlight[operationId] = task
    do {
      let result = try await task.value
      inFlight.removeValue(forKey: operationId)
      return result
    } catch {
      inFlight.removeValue(forKey: operationId)
      throw error
    }
  }

  private func attempt(
    operationId: String,
    recoveryAdmission: FeatureRecoveryAdmission?
  ) async throws -> FeatureUsageResult {
    guard !isClosed else { throw CancellationError() }
    try admitRecoverySideEffect(
      operationId: operationId,
      admission: recoveryAdmission
    )
    guard var command = commands?.first(where: { $0.operationId == operationId }) else {
      throw CancellationError()
    }

    if command.result == nil {
      let isFirstDeliveryAttempt = command.firstDeliveryAttemptAt == nil
      if isFirstDeliveryAttempt {
        try performRecoveryDurableWrite(
          operationId: operationId,
          admission: recoveryAdmission
        ) {
          command.firstDeliveryAttemptAt = dateProvider.now()
          try replaceAndPersist(command)
        }
      }
      let response: EventResponse
      do {
        try admitRecoverySideEffect(
          operationId: operationId,
          admission: recoveryAdmission
        )
        response = try await api.trackEvent(
          transportEvent(for: command, name: SystemEventNames.featureUsed)
        )
      } catch {
        let disposition = deliveryDisposition(for: error)
        try performRecoveryDurableWrite(
          operationId: operationId,
          admission: recoveryAdmission
        ) {
          if disposition == .terminalPoison || disposition == .split {
            try removeAndPersist(operationId: operationId)
          }
        }
        throw error
      }
      try performRecoveryDurableWrite(
        operationId: operationId,
        admission: recoveryAdmission
      ) {
        command.result = .init(
          response: response,
          reconciliation: nil,
          persistedAt: isFirstDeliveryAttempt
            ? dateProvider.now()
            : command.firstDeliveryAttemptAt
        )
        try replaceAndPersist(command)
      }
    }

    guard var durableResult = command.result else {
      throw NuxieNetworkError.invalidResponse
    }

    if isAccepted(durableResult.response), durableResult.reconciliation == nil {
      let mirror = await acceptedMirror(for: command, response: durableResult.response)
      try performRecoveryDurableWrite(
        operationId: operationId,
        admission: recoveryAdmission
      ) {
        durableResult.reconciliation = .init(mirror: mirror)
        command.result = durableResult
        try replaceAndPersist(command)
      }
    }

    let result = makeUsageResult(command: command, response: durableResult.response)
    try await reconcileAvailableCommands(
      for: applicationKey(for: command),
      reportingFailureFor: operationId,
      recoveryAdmission: recoveryAdmission
    )
    guard identity.getDistinctId() == command.distinctId else {
      throw CancellationError()
    }
    return result
  }

  private func applyBalanceIfFresh(
    command: FeatureUseCommand,
    durableResult: FeatureUseCommand.DurableResult,
    recoveryAdmission: FeatureRecoveryAdmission?
  ) async throws {
    guard identity.getDistinctId() == command.distinctId,
          let remaining = durableResult.response.usage?.remaining else { return }
    try admitRecoverySideEffect(
      operationId: command.operationId,
      admission: recoveryAdmission
    )
    let featureId = command.featureId
    let responsePersistedAt = durableResult.persistedAt
    _ = await MainActor.run {
      featureInfo.applyCommandBalanceIfFresh(
        featureId,
        balance: remaining,
        responsePersistedAt: responsePersistedAt
      )
    }
  }

  private func reconcileAvailableCommands(
    for key: FeatureUseApplicationKey,
    reportingFailureFor operationId: String,
    recoveryAdmission: FeatureRecoveryAdmission?
  ) async throws {
    guard reconcilingApplicationKeys.insert(key).inserted else { return }
    defer { reconcilingApplicationKeys.remove(key) }

    while let command = commands?.first(where: { applicationKey(for: $0) == key }) {
      guard let durableResult = command.result,
            !isAccepted(durableResult.response)
              || durableResult.reconciliation != nil
      else { return }

      do {
        try await reconcile(
          command: command,
          durableResult: durableResult,
          recoveryAdmission: recoveryAdmission
        )
      } catch {
        if command.operationId == operationId { throw error }
        LogWarning(
          "Feature command \(command.operationId) remains pending reconciliation: \(error)"
        )
        return
      }
    }
  }

  private func reconcile(
    command: FeatureUseCommand,
    durableResult: FeatureUseCommand.DurableResult,
    recoveryAdmission: FeatureRecoveryAdmission?
  ) async throws {
    if isAccepted(durableResult.response) {
      try await applyBalanceIfFresh(
        command: command,
        durableResult: durableResult,
        recoveryAdmission: recoveryAdmission
      )

      if let mirror = durableResult.reconciliation?.mirror {
        try admitRecoverySideEffect(
          operationId: command.operationId,
          admission: recoveryAdmission
        )
        let isDurable = await eventLog.storePreparedEventInHistory(
          mirror.event(operationId: command.operationId)
        )
        // This prepared mirror is the local-history copy of SystemEventNames.featureUsed.
        try admitRecoverySideEffect(
          operationId: command.operationId,
          admission: recoveryAdmission
        )
        guard isDurable else {
          throw FeatureUseCommandError.reconciliationNotDurable
        }
      }
    }

    try performRecoveryDurableWrite(
      operationId: command.operationId,
      admission: recoveryAdmission
    ) {
      try removeAndPersist(operationId: command.operationId)
    }
  }

  private func applicationKey(for command: FeatureUseCommand) -> FeatureUseApplicationKey {
    FeatureUseApplicationKey(
      distinctId: command.distinctId,
      featureId: command.featureId,
      entityId: command.entityId
    )
  }

  private func deliveryDisposition(for error: Error) -> EventDeliveryDisposition {
    if (error as? NuxieNetworkError)?.httpStatusCode == 404 {
      // `/i/event` uses 404 specifically for a missing Feature. The command has
      // no authority to apply and must not become valid through later replay.
      return .terminalPoison
    }
    return EventDeliveryPolicy.disposition(for: error)
  }

  private func admitRecoverySideEffect(
    operationId: String,
    admission: FeatureRecoveryAdmission?
  ) throws {
    guard !isClosed else { throw CancellationError() }
    guard !foregroundJoinedRecoveryIds.contains(operationId) else { return }
    try admission?.admit()
  }

  private func performRecoveryDurableWrite<T>(
    operationId: String,
    admission: FeatureRecoveryAdmission?,
    _ write: () throws -> T
  ) throws -> T {
    guard !isClosed else { throw CancellationError() }
    guard !foregroundJoinedRecoveryIds.contains(operationId), let admission else {
      return try write()
    }
    return try admission.perform(write)
  }

  private func transportEvent(
    for command: FeatureUseCommand,
    name: String
  ) -> NuxieEvent {
    var properties: [String: Any] = [
      "feature_extId": command.featureId,
      "value": command.amount,
    ]
    if command.setUsage { properties["setUsage"] = true }
    if let entityId = command.entityId { properties["entityId"] = entityId }
    if let metadata = command.metadata {
      properties["metadata"] = metadata.mapValues(\.value)
    }
    return NuxieEvent(
      id: command.operationId,
      name: name,
      distinctId: command.distinctId,
      properties: properties,
      timestamp: command.createdAt
    )
  }

  private func acceptedMirror(
    for command: FeatureUseCommand,
    response: EventResponse
  ) async -> FeatureUseCommand.Mirror? {
    guard isAccepted(response) else { return nil }
    var properties: [String: Any] = [
      "feature_id": command.featureId,
      "amount": command.amount,
      "$distinct_id": command.distinctId,
    ]
    if let entityId = command.entityId { properties["entity_id"] = entityId }
    if let metadata = command.metadata {
      properties["metadata"] = metadata.mapValues(\.value)
    }
    let enriched = await eventLog.prepareTriggerProperties(properties)
    let original = NuxieEvent(
      id: command.operationId,
      name: SystemEventNames.featureUsed,
      distinctId: command.distinctId,
      properties: enriched,
      timestamp: command.createdAt
    )
    guard let transformed = await eventLog.applyBeforeSend(to: original) else {
      return nil
    }
    var transformedProperties = transformed.properties
    transformedProperties["$distinct_id"] = command.distinctId
    return FeatureUseCommand.Mirror(
      name: transformed.name,
      forwardingName: SystemEventNames.featureUsed,
      distinctId: command.distinctId,
      properties: transformedProperties.mapValues(AnyCodable.init),
      timestamp: command.createdAt
    )
  }

  private func replaceAndPersist(_ command: FeatureUseCommand) throws {
    guard var updated = commands,
          let index = updated.firstIndex(where: { $0.operationId == command.operationId })
    else { throw CancellationError() }
    updated[index] = command
    try store.save(updated)
    commands = updated
  }

  private func removeAndPersist(operationId: String) throws {
    guard var updated = commands else { throw CancellationError() }
    updated.removeAll { $0.operationId == operationId }
    try store.save(updated)
    commands = updated
  }

  private func isAccepted(_ response: EventResponse) -> Bool {
    response.status == "ok" || response.status == "success"
  }

  private func makeUsageResult(
    command: FeatureUseCommand,
    response: EventResponse
  ) -> FeatureUsageResult {
    FeatureUsageResult(
      success: isAccepted(response),
      featureId: command.featureId,
      amountUsed: command.amount,
      message: response.message,
      usage: response.usage.map {
        FeatureUsageResult.UsageInfo(
          current: $0.current,
          limit: $0.limit,
          remaining: $0.remaining
        )
      }
    )
  }
}

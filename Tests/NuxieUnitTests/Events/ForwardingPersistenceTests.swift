import Foundation
import XCTest

@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private actor ForwardingRecorder {
  private var events: [DurableForwardingEvent] = []
  private var routedNames: [String] = []

  func record(_ event: DurableForwardingEvent) { events.append(event) }
  func recordRoute(_ event: NuxieEvent) { routedNames.append(event.name) }
  func snapshot() -> [DurableForwardingEvent] { events }
  func routes() -> [String] { routedNames }
}

private final class ForwardingAdmissionGate: @unchecked Sendable {
  private let lock = NSLock()
  private var enabled = false

  func isEnabled() -> Bool { lock.withLock { enabled } }
  func enable() { lock.withLock { enabled = true } }
}

@MainActor
private final class PublicForwardingDelegate {
  private let acceptedNames: Set<String>
  private var activities: [NuxieActivityInfo] = []
  private var mainThreadDeliveries: [Bool] = []

  init(acceptedNames: Set<String>) {
    self.acceptedNames = acceptedNames
  }

  func nuxieDidEmit(_ info: NuxieActivityInfo) {
    guard acceptedNames.contains(info.name) else { return }
    activities.append(info)
    mainThreadDeliveries.append(Thread.isMainThread)
  }

  func snapshot() -> (activities: [NuxieActivityInfo], mainThreadDeliveries: [Bool]) {
    (activities, mainThreadDeliveries)
  }
}

extension PublicForwardingDelegate: NuxieDelegate {}

final class ForwardingPersistenceTests: XCTestCase {
  func testForwardingFollowsDurabilityOrderWhenPersistenceLanesInterleave() async throws {
    let store = MockEventStore()
    store.suspendInsert(id: "slow-first-admission")
    let log = makeUnconfiguredLog(store: store)
    let recorder = ForwardingRecorder()
    await log.subscribeForwarding { event in await recorder.record(event) }
    try await log.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))

    let slowAdmission = Task {
      await log.storePreparedEventInHistory(NuxieEvent(
        id: "slow-first-admission",
        name: SystemEventNames.appOpened,
        distinctId: "customer-1",
        timestamp: Date(timeIntervalSince1970: 1)
      ))
    }
    try await waitForStoreCallCount(1, store: store)

    let stableCapture = await log.captureSystemEvent(
      SystemEventNames.appBackgrounded,
      properties: nil,
      eventId: "fast-second-admission",
      distinctId: "customer-1"
    )
    XCTAssertEqual(stableCapture?.event.id, "fast-second-admission")
    store.resumeInsert(id: "slow-first-admission")
    _ = await slowAdmission.value
    await log.drain()

    let durableIds = store.storedEvents.map(\.id)
    let forwardedIds = await recorder.snapshot().map(\.event.id)
    XCTAssertEqual(durableIds, ["fast-second-admission", "slow-first-admission"])
    XCTAssertEqual(forwardedIds, durableIds)
    await log.close()
  }

  func testDisabledCaptureDoesNotBlockOrReplayAfterForwardingIsEnabled() async throws {
    let store = MockEventStore()
    store.pendingInsertDelayNanoseconds = 500_000_000
    let log = makeUnconfiguredLog(store: store)
    let gate = ForwardingAdmissionGate()
    let recorder = ForwardingRecorder()
    await log.subscribeForwarding(
      when: { gate.isEnabled() },
      handler: { event in await recorder.record(event) }
    )
    try await log.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))

    let disabledCapture = Task {
      await log.storePreparedEventInHistory(NuxieEvent(
        id: "disabled-capture",
        name: SystemEventNames.appOpened,
        distinctId: "customer-1",
        timestamp: Date(timeIntervalSince1970: 1)
      ))
    }
    try await waitForStoreCallCount(1, store: store)

    gate.enable()
    store.pendingInsertDelayNanoseconds = 0
    await log.storePreparedEventInHistory(NuxieEvent(
      id: "enabled-capture",
      name: SystemEventNames.appBackgrounded,
      distinctId: "customer-1",
      timestamp: Date(timeIntervalSince1970: 2)
    ))
    await log.drain()

    var forwardedIds = await recorder.snapshot().map(\.event.id)
    XCTAssertEqual(forwardedIds, ["enabled-capture"])

    _ = await disabledCapture.value
    await log.drain()
    forwardedIds = await recorder.snapshot().map(\.event.id)
    XCTAssertEqual(forwardedIds, ["enabled-capture"])
    await log.close()
  }

  func testDeviceCaptureUsesCapturedTimestampAsReceivedAt() async throws {
    let (log, _) = try await makeLog()
    let recorder = ForwardingRecorder()
    await log.subscribeForwarding { event in await recorder.record(event) }
    let capturedAt = Date(timeIntervalSince1970: 123)

    await log.storePreparedEventInHistory(NuxieEvent(
      id: "device-capture",
      name: SystemEventNames.appOpened,
      distinctId: "customer-1",
      timestamp: capturedAt
    ))
    await log.drain()

    let receivedAt = await recorder.snapshot().first?.receivedAt
    XCTAssertEqual(receivedAt, capturedAt)
    await log.close()
  }

  func testConvertedServerFactUsesConversionAtAsTimestampAndArrivalAsReceivedAt() async throws {
    let arrival = Date(timeIntervalSince1970: 456)
    let store = MockEventStore()
    let log = EventLog(
      identity: MockIdentityService(),
      dateProvider: MockDateProvider(initialDate: arrival),
      apiClient: MockNuxieApiForQueue(),
      store: store
    )
    let recorder = ForwardingRecorder()
    await log.subscribeForwarding { event in await recorder.record(event) }
    try await log.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))
    let convertedAt = Date(timeIntervalSince1970: 123)
    let envelopeAt = Date(timeIntervalSince1970: 124)

    await log.commitServerFacts([
      JourneyDownFact(
        id: "server-fact",
        event: .converted,
        timestamp: envelopeAt,
        properties: JourneyConvertedProperties(
          journeyId: "journey-1",
          experienceId: "experience-1",
          experienceVersion: "version-1",
          at: convertedAt,
          sourceFactRef: "source-1"
        )
      ),
    ], distinctId: "customer-1")
    await log.drain()

    let forwardedSnapshot = await recorder.snapshot()
    let forwarded = try XCTUnwrap(forwardedSnapshot.first)
    XCTAssertEqual(forwarded.event.timestamp, convertedAt)
    XCTAssertEqual(forwarded.receivedAt, arrival)
    await log.close()
  }

  func testScriptedJourneyReachesPublicDelegateInDurabilityOrderOnMainActor() async throws {
    let expectedNames = [
      "experience_shown",
      "experiment_exposure",
      "purchase_completed",
      "purchase_synced",
      "experience_dismissed",
      "journey_ended",
    ]
    let storageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("nuxie-forwarding-script-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: storageURL) }

    let sdk = NuxieSDK.shared
    await sdk.shutdown()
    let delegate = await MainActor.run {
      PublicForwardingDelegate(acceptedNames: Set(expectedNames))
    }
    await MainActor.run { sdk.delegate = delegate }
    let configuration = NuxieConfiguration(apiKey: "test-api-key")
    configuration.testingOverrides.customStoragePath = storageURL
    configuration.testingOverrides.flushAt = 100
    configuration.testingOverrides.suppressBackgroundWork = true
    var overrides = NuxieCoreOverrides()
    overrides.api = MockNuxieApi()
    try sdk.setup(with: configuration, overrides: overrides)

    let core = try XCTUnwrap(sdk.core)
    core.identity.setDistinctId("customer-1")
    let refProperties: [String: Any] = [
      "experience_id": "experience-1",
      "experience_version": "version-1",
      "journey_id": "journey-1",
    ]
    // Exercise the same nearest service seams used by the real producers:
    // presentation and exposure emitters enqueue on EventLog, StoreKit uses
    // the stable SystemEventSink capture APIs, and journey exit uses the
    // synchronous platform-fact lane.
    core.eventLog.track(
      JourneyEvents.experienceShown,
      properties: refProperties,
      userProperties: nil,
      userPropertiesSetOnce: nil
    )
    await core.eventLog.drain()

    core.eventLog.track(
      JourneyEvents.experimentExposure,
      properties: refProperties.merging([
        "experiment_key": "experiment-1", "variant_key": "variant-1", "is_holdout": false,
      ]) { _, new in new },
      userProperties: nil,
      userPropertiesSetOnce: nil
    )
    await core.eventLog.drain()

    let purchaseCompletedCaptured = await core.systemEvents.captureOnly(
      .init(
        name: SystemEventNames.purchaseCompleted,
        properties: [
          "product_id": "product-1", "store_product_id": "com.example.product",
          "experience_id": "experience-1", "test_store": false,
        ],
        eventId: "scripted-purchase-completed",
        distinctId: "customer-1"
      )
    )
    XCTAssertTrue(purchaseCompletedCaptured)
    let purchaseSyncedCaptured = await core.systemEvents.capture(
      .init(
        name: SystemEventNames.purchaseSynced,
        properties: [
          "transaction_id": "transaction-1", "original_transaction_id": "original-1",
          "product_id": "product-1", "experience_id": "experience-1",
          "journey_id": "journey-1",
        ],
        eventId: "scripted-purchase-synced",
        distinctId: "customer-1"
      )
    )
    // captureSystemEvent's Bool also reflects journey routing, which this
    // minimal core cannot satisfy; durable capture and forwarding are what
    // this test pins, and the delegate snapshot below asserts both.
    _ = purchaseSyncedCaptured

    core.eventLog.track(
      JourneyEvents.experienceDismissed,
      properties: refProperties.merging(["reason": "user"]) { _, new in new },
      userProperties: nil,
      userPropertiesSetOnce: nil
    )
    await core.eventLog.drain()

    _ = try await core.eventLog.trackWithResponse(
      JourneyEvents.journeyExited,
      properties: refProperties.merging(["reason": "completed"]) { _, new in new },
      flushStrategy: .eventLog
    )
    await core.eventLog.drain()

    let snapshot = await MainActor.run {
      delegate.snapshot()
    }
    XCTAssertEqual(snapshot.activities.map(\.name), expectedNames)
    XCTAssertEqual(
      snapshot.mainThreadDeliveries,
      Array(repeating: true, count: expectedNames.count)
    )

    await sdk.shutdown()
  }

  func testDuplicateAndCollisionAnnounceOnlyTheFirstDurableRow() async throws {
    let (log, store) = try await makeLog()
    let recorder = ForwardingRecorder()
    await log.subscribeForwarding { event in await recorder.record(event) }
    let event = NuxieEvent(
      id: "stable-id",
      name: SystemEventNames.appOpened,
      distinctId: "customer-1",
      properties: [:],
      timestamp: Date(timeIntervalSince1970: 10)
    )

    await log.storePreparedEventInHistory(event)
    await log.storePreparedEventInHistory(event)
    await log.storePreparedEventInHistory(NuxieEvent(
      id: event.id,
      name: SystemEventNames.appBackgrounded,
      distinctId: event.distinctId,
      properties: [:],
      timestamp: event.timestamp
    ))
    await log.drain()

    let forwardedNames = await recorder.snapshot().map(\.event.name)
    XCTAssertEqual(forwardedNames, [SystemEventNames.appOpened])
    XCTAssertEqual(store.storedEvents.map(\.name), [SystemEventNames.appOpened])
    await log.close()
  }

  func testPendingReplayDoesNotForwardAgain() async throws {
    let store = MockEventStore()
    _ = try await store.insert(
      StoredEvent(
        id: "already-durable",
        name: SystemEventNames.appOpened,
        timestamp: Date(timeIntervalSince1970: 1),
        distinctId: "customer-1"
      ),
      deliveryState: .pending
    )
    let recorder = ForwardingRecorder()
    let log = makeUnconfiguredLog(store: store)
    await log.subscribeForwarding { event in await recorder.record(event) }
    try await log.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))
    await log.drain()

    let forwarded = await recorder.snapshot()
    XCTAssertTrue(forwarded.isEmpty)
    await log.close()
  }

  func testStorageFailureStillRoutesButNeverForwards() async throws {
    let store = MockEventStore()
    store.shouldFailStore = true
    let recorder = ForwardingRecorder()
    let log = makeUnconfiguredLog(store: store)
    await log.subscribeCommitted { event in await recorder.recordRoute(event) }
    await log.subscribeForwarding { event in await recorder.record(event) }
    try await log.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))

    log.track("host_event")
    await log.drain()

    let routedNames = await recorder.routes()
    let forwarded = await recorder.snapshot()
    XCTAssertEqual(routedNames, ["host_event"])
    XCTAssertTrue(forwarded.isEmpty)
    await log.close()
  }

  func testTriggerLaneForwardsWithoutEnteringOrdinaryRouting() async throws {
    let (log, _) = try await makeLog()
    let recorder = ForwardingRecorder()
    await log.subscribeCommitted { event in await recorder.recordRoute(event) }
    await log.subscribeForwarding { event in await recorder.record(event) }

    _ = try await log.trackForTrigger("host_trigger", properties: nil)
    await log.drain()

    let routedNames = await recorder.routes()
    let forwardedNames = await recorder.snapshot().map(\.event.forwardingName)
    XCTAssertTrue(routedNames.isEmpty)
    XCTAssertEqual(forwardedNames, ["host_trigger"])
    await log.close()
  }

  func testMirroredCaptureForwardsWithoutReenteringOrdinaryRouting() async throws {
    let (log, _) = try await makeLog()
    let recorder = ForwardingRecorder()
    await log.subscribeCommitted { event in await recorder.recordRoute(event) }
    await log.subscribeForwarding { event in await recorder.record(event) }

    log.trackWithoutRouting(
      SystemEventNames.screenShown,
      properties: [
        "screen_id": "screen-1",
        "journey_id": "journey-1",
        "experience_id": "experience-1",
        "experience_version": "version-1",
      ],
      distinctIdOverride: "customer-1"
    )
    await log.drain()

    let routes = await recorder.routes()
    let forwardedNames = await recorder.snapshot().map(\.event.forwardingName)
    XCTAssertTrue(routes.isEmpty)
    XCTAssertEqual(forwardedNames, [SystemEventNames.screenShown])
    await log.close()
  }

  func testBeforeSendDropSuppressesPersistenceAndRenameKeepsCurationIdentity() async throws {
    let store = MockEventStore()
    let recorder = ForwardingRecorder()
    let log = makeUnconfiguredLog(store: store)
    await log.subscribeForwarding { event in await recorder.record(event) }
    let configuration = NuxieConfiguration(apiKey: "test-api-key")
    configuration.beforeSend = { event in
      if event.name == SystemEventNames.appOpened { return nil }
      return NuxieEvent(
        id: event.id,
        name: "renamed_by_host",
        distinctId: event.distinctId,
        properties: event.properties,
        timestamp: event.timestamp
      )
    }
    try await log.configure(configuration: configuration)

    log.track(SystemEventNames.appOpened)
    log.track(SystemEventNames.appBackgrounded)
    await log.drain()

    let forwarded = await recorder.snapshot()
    XCTAssertEqual(store.storedEvents.map(\.name), ["renamed_by_host"])
    XCTAssertEqual(forwarded.map(\.event.name), ["renamed_by_host"])
    XCTAssertEqual(forwarded.map(\.event.forwardingName), [SystemEventNames.appBackgrounded])
    XCTAssertEqual(
      forwarded.compactMap {
        ActivityCuration.activity(
          internalName: $0.event.forwardingName,
          properties: $0.event.properties
        )?.wireName
      },
      ["app_backgrounded"]
    )
    await log.close()
  }

  func testEveryPersistenceLaneUsesAnEnumeratedDurabilityPrimitive() throws {
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent("Sources/Nuxie/Events/EventLog.swift"),
      encoding: .utf8
    )

    let ordinaryLanes = [
      "  func trackWithResponse(\n    _ event: String,\n    properties: sending [String: Any]? = nil,\n    flushStrategy:",
      "  public func trackForTrigger(\n    _ event: String,\n    properties: sending [String: Any]? = nil,\n    persistToHistory:",
      "  public func commitPreparedTriggerEvent(\n    _ event: NuxieEvent",
      "  public func storePreparedEventInHistory(_ event: NuxieEvent) async",
      "  public func commitServerFacts(_ facts: [JourneyDownFact], distinctId: String) async",
      "  private func commit(\n    _ event: NuxieEvent,\n    routeToSubscribers: Bool,\n    subscriberAdmissions:",
    ]
    for signature in ordinaryLanes {
      let body = try functionBody(in: source, startingWith: signature)
      XCTAssertEqual(
        body.components(separatedBy: "try await persist(").count - 1,
        1,
        "Persistence lane bypassed persist: \(signature)"
      )
    }

    let stableLane = try functionBody(
      in: source,
      startingWith: "  private func captureStableSystemEvent("
    )
    XCTAssertEqual(
      stableLane.components(separatedBy: "store.commitStableCapture(").count - 1,
      1
    )
    let stableBatchLane = try functionBody(
      in: source,
      startingWith: "  func captureAndRouteSystemEventBatch(\n    _ items: [RoutedStableSystemEventBatchItem],\n    admission: any StableEventCaptureBatchCommitAdmission\n  ) async -> [String: DurableTriggerCapture]? {"
    )
    XCTAssertEqual(
      stableBatchLane.components(separatedBy: "store.commitStableCaptureBatch(").count - 1,
      1
    )
    XCTAssertEqual(
      stableBatchLane.components(separatedBy: "store.queryStableCapture(").count - 1,
      1
    )
    XCTAssertEqual(source.components(separatedBy: "store.insert(").count - 1, 1)
    XCTAssertEqual(source.components(separatedBy: "store.commitStableCapture(").count - 1, 1)
    XCTAssertEqual(source.components(separatedBy: "store.commitStableCaptureBatch(").count - 1, 1)
    let persistBody = try functionBody(in: source, startingWith: "  private func persist(")
    XCTAssertEqual(persistBody.components(separatedBy: "store.insert(").count - 1, 1)

    let storeCallPattern = try NSRegularExpression(
      pattern: #"store\.([A-Za-z_][A-Za-z0-9_]*)\("#
    )
    let sourceRange = NSRange(source.startIndex..., in: source)
    let actualStoreCalls = Dictionary(
      grouping: storeCallPattern.matches(in: source, range: sourceRange).compactMap { match in
        Range(match.range(at: 1), in: source).map { String(source[$0]) }
      },
      by: { $0 }
    ).mapValues(\.count)
    let expectedStoreCalls = [
      "advanceHistoryCoverage": 1,
      "clearUnresolvedJourneyOwnershipResponse": 1,
      "close": 1,
      "commitStableCapture": 1,
      "commitStableCaptureBatch": 1,
      "countEvents": 2,
      "deleteStableDropsOlderThan": 1,
      "getEventCount": 1,
      "getFirstEventTime": 1,
      "getLastEventTime": 2,
      "getPendingDeliveryCount": 2,
      "hasEvent": 1,
      "hasJourneyOwnershipLoss": 1,
      "hasUnresolvedJourneyOwnershipResponse": 2,
      "historyCoverageStartingAt": 1,
      "initialize": 1,
      "insert": 1,
      "markDelivered": 1,
      "pruneHistory": 1,
      "queryEventsForUser": 4,
      "queryPendingDelivery": 1,
      "queryRecentEvents": 1,
      "queryStableCapture": 2,
      "queryUnresolvedJourneyOwnershipResponse": 2,
      "readOrInitializeHistoryCoverage": 1,
      "reassignEvents": 1,
      "recordJourneyOwnershipLoss": 1,
      "recordUnresolvedJourneyOwnershipResponse": 1,
    ]
    XCTAssertEqual(
      actualStoreCalls,
      expectedStoreCalls,
      "Every EventLog store API call must be classified here; an unknown call may bypass durability"
    )
  }

  private func makeLog() async throws -> (EventLog, MockEventStore) {
    let store = MockEventStore()
    let log = makeUnconfiguredLog(store: store)
    try await log.configure(configuration: NuxieConfiguration(apiKey: "test-api-key"))
    return (log, store)
  }

  private func makeUnconfiguredLog(store: MockEventStore) -> EventLog {
    EventLog(
      identity: MockIdentityService(),
      dateProvider: MockDateProvider(),
      apiClient: MockNuxieApiForQueue(),
      store: store
    )
  }

  private func waitForStoreCallCount(
    _ expected: Int,
    store: MockEventStore
  ) async throws {
    for _ in 0..<1_000 {
      if store.storeEventCallCount >= expected { return }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Timed out waiting for \(expected) store calls")
  }

  private func functionBody(
    in source: String,
    startingWith signature: String
  ) throws -> Substring {
    let signatureRange = try XCTUnwrap(source.range(of: signature), signature)
    let openBrace = try XCTUnwrap(
      source[signatureRange.lowerBound...].firstIndex(of: "{"),
      signature
    )
    var depth = 0
    for index in source.indices[openBrace...] {
      switch source[index] {
      case "{":
        depth += 1
      case "}":
        depth -= 1
        if depth == 0 { return source[openBrace...index] }
      default:
        break
      }
    }
    throw NSError(
      domain: "ForwardingPersistenceTests",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Unterminated function: \(signature)"]
    )
  }

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

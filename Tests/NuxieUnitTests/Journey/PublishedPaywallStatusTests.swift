import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class PublishedPaywallStatusTests: JourneyTestCase {
    @MainActor
    func testEmptyBuyKeepsPublishedRecipeAndAcceptsRetry() async throws {
        for variant in ["empty", "omitted", "authored"] {
            let harness = try await open(variant)
            harness.controller.select("")
            harness.continuation.finished = expectation(description: "empty Buy finished")
            let accepted = await harness.controller.buy()
            XCTAssertEqual(accepted, true)
            await fulfillment(of: [harness.continuation.finished], timeout: 3)
            XCTAssertTrue(harness.presenter.isExperiencePresented, variant)
            let runs = try await harness.journal.runs()
            XCTAssertNil(runs.first?.completion, variant)
            let purchase = try XCTUnwrap(harness.leg.steps.first { $0.action?["type"] == .string("purchase") })
            XCTAssertNil(runs.first?.effectReceipts[purchase.id], "Retry must not retain a receipt")
            let errorStatus = try await harness.controller.status("purchase")
            XCTAssertEqual(errorStatus, "error")
            harness.controller.select("golden:monthly")
            harness.store.purchaseResult = .cancelled
            harness.sink.terminal = expectation(description: "retry terminal")
            let retried = await harness.controller.buy()
            XCTAssertEqual(retried, true, variant)
            await fulfillment(of: [harness.sink.terminal], timeout: 3)
            XCTAssertEqual(harness.store.purchaseCallCount, 1, variant)
            await harness.journeys.shutdown()
            try await harness.controller.screen.close()
        }
    }

    @MainActor
    func testSynchronousBuyFailureSaveErrorAbandonsInsteadOfBlockingLaterBuy() async throws {
        let failures = JourneyJournalPersistenceFailures()
        let harness = try await open("empty", persistenceFailures: failures)
        harness.controller.select("")
        harness.controller.beforeFailureFeedback = { failures.failNext(1) }
        harness.continuation.finished = expectation(description: "failed save handled")
        let accepted = await harness.controller.buy()
        XCTAssertEqual(accepted, true)
        await fulfillment(of: [harness.continuation.finished], timeout: 3)
        let runs = try await harness.journal.runs()
        XCTAssertFalse(runs.contains { $0.completion == nil && !$0.effectReceipts.isEmpty })
        XCTAssertFalse(harness.presenter.isExperiencePresented)
        await harness.journeys.shutdown()
        try await harness.controller.screen.close()
    }

    @MainActor
    func testPurchaseAndRestoreProjectStoreLifecycleIntoRealEngine() async throws {
        let harness = try await open("empty")
        let store = harness.store
        harness.controller.select("golden:monthly")
        for (result, expected) in [(PurchaseResult.failed(StoreKitError.networkUnavailable), "error"), (.cancelled, "cancelled"), (.purchased, "success")] {
            harness.sink.terminal = expectation(description: expected)
            harness.continuation.finished = expectation(description: "purchase dispatched")
            store.purchaseResult = result
            store.hold = true
            store.started = expectation(description: "store entered")
            let accepted = await harness.controller.buy()
            XCTAssertEqual(accepted, true)
            await fulfillment(of: [store.started, harness.continuation.finished], timeout: 3)
            let running = try await harness.controller.status("purchase")
            XCTAssertEqual(running, "running")
            let errorCode = try await harness.controller.field("purchase", "errorCode")
            XCTAssertEqual(errorCode, "")
            store.release()
            await fulfillment(of: [harness.sink.terminal], timeout: 3)
            let settled = try await harness.controller.status("purchase")
            XCTAssertEqual(settled, expected)
            let terminalError = try await harness.controller.field("purchase", "errorCode")
            XCTAssertEqual(terminalError, expected == "error" ? StoreKitError.networkUnavailable.localizedDescription : "")
            if expected != "success" { XCTAssertTrue(harness.presenter.isExperiencePresented) }
        }
        await harness.journeys.shutdown()
        try await harness.controller.screen.close()
        for (result, expected) in [(RestoreResult.failed(StoreKitError.networkUnavailable), "error"), (.noPurchases, "not_found"), (.restored, "success")] {
            let restore = try await open("empty")
            restore.continuation.finished = expectation(description: "restore dispatched")
            restore.store.restoreResult = result
            restore.store.hold = true
            restore.store.started = expectation(description: "restore entered")
            let accepted = await restore.controller.buy(event: "restore")
            XCTAssertEqual(accepted, true)
            await fulfillment(of: [restore.store.started, restore.continuation.finished], timeout: 3)
            let running = try await restore.controller.status("restore")
            XCTAssertEqual(running, "running")
            restore.store.release()
            await fulfillment(of: [restore.sink.terminal], timeout: 3)
            let settled = try await restore.controller.status("restore")
            XCTAssertEqual(settled, expected)
            let terminalError = try await restore.controller.field("restore", "errorCode")
            XCTAssertEqual(terminalError, expected == "error" ? StoreKitError.networkUnavailable.localizedDescription : "")
            await restore.journeys.shutdown()
            try await restore.controller.screen.close()
        }
    }

    @MainActor
    private func open(_ variant: String, persistenceFailures: JourneyJournalPersistenceFailures? = nil) async throws -> PaywallHarness {
        let directory = temporaryDirectory()
        addTeardownBlock { self.removeTemporaryDirectoryIfPresent(directory) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/runtime/paywall-status")
        let leg = try JSONDecoder().decode(Journey.self, from: Data(contentsOf: fixture.appendingPathComponent("\(variant)-leg.json")))
        let values = try JSONDecoder().decode([JourneyViewModelValue].self, from: Data(contentsOf: fixture.appendingPathComponent("view-model-values.json")))
        var productDocument = releaseProductDocument(id: "monthly", storeProductId: "com.example.pro", featureIds: [])
        if case .object(var fields) = productDocument { fields["type"] = .string("consumable"); productDocument = .object(fields) }
        let snapshot = replacing(try await authenticatedRenderedSnapshot(JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry")),
            offers: [], products: [productDocument], entryStepId: leg.entryStepId, steps: leg.steps, routes: leg.routes, screens: leg.screens,
            viewModelValues: try JSONDecoder().decode([[String: JourneyReleaseJSONValue]].self, from: JSONEncoder().encode(values)))
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let identity = MockIdentityService(); identity.setDistinctId("customer")
        let events = MockEventLog(); events.identity = identity
        let store = PaywallStore()
        let configuration = NuxieConfiguration(apiKey: "paywall-test"); configuration.purchaseDelegate = store
        let sink = PaywallOutcomeSink()
        let products = ProductService(productProvider: MockStoreKitProductProvider())
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let api = MockNuxieApi()
        let features = FeatureService(api: api, identity: identity, profile: MockProfileService(),
            dateProvider: MockDateProvider(), featureInfo: FeatureInfo(), cacheTTL: 60)
        let box = LateBound<TransactionService>()
        let observer = TransactionObserver(api: api, features: features, identity: identity, settings: settings,
            eventSink: sink, transactionServiceProvider: { box.get() },
            evidenceStore: TransactionEvidenceStore(customStoragePath: directory),
            activeStoreOriginalTransactionIDs: { [] }, unfinishedRecoveryTransactions: { [] },
            currentEntitlementRecoveryTransactions: { [] })
        addTeardownBlock { await observer.stopListening() }
        let transactions = TransactionService(productService: products, transactionObserver: observer,
            pendingPurchaseStore: InMemoryPendingPurchaseStore(), dateProvider: MockDateProvider(),
            settings: settings, eventSink: sink, identityService: identity)
        box.set(transactions)
        let native = MockStoreProduct(id: "com.example.pro", displayName: "Plan", price: 1, displayPrice: "$1", productType: .consumable)
        var product = StoreProduct(productId: "monthly", storeProductId: "com.example.pro", placementId: "golden:monthly", name: "Plan", description: "Plan", price: "$1", period: nil, productType: .consumable, appStoreProduct: native)
        product.purchaseContext = PurchaseCommercialContext(
            release: .init(identity: release.descriptor.identity, descriptorSHA256: release.descriptorSHA256),
            placementId: "golden:monthly", productId: "monthly", storeProductId: "com.example.pro", displayPrice: "$1", price: 1)
        let payload = try await statePayload(defaultViewModelName: "Runtime", values: values,
            scene: Data(contentsOf: fixture.appendingPathComponent("screen.riv")), artboardName: "Paywall", width: 320, height: 150)
        let screen = try await ExperienceInteractiveScreen.open(payload: payload, pixelWidth: 320, pixelHeight: 150)
        let definition = try ExperienceDefinition(journeyDescriptor: release.descriptor)
        let experience = Experience(id: "paywall", versionId: release.descriptor.identity.experienceVersionId, buildId: "test", artifactContentHash: nil,
            authenticatedReleaseID: nil, behaviorPresentation: .standard, behaviorPresentationScreens: ["state-screen": .init(width: 320, height: 150)],
            assetBaseURL: URL(string: "https://test.invalid/")!, journey: .init(screens: definition.screens, viewModelValues: values), definition: definition, products: [product])
        let controller = PaywallEngineController(mockExperienceVersionId: experience.versionId, mockScreenId: "state-screen", mockExperience: experience,
            transactionService: transactions, productService: products, systemEventSink: sink)
        controller.screen = screen
        let experiences = MockExperienceService(); experiences.defaultMockViewController = controller
        let presenter = ExperiencePresentationService(windowProvider: MockWindowProvider(), experiences: experiences, eventLog: events, identity: identity)
        let continuation = PaywallContinuationSignal()
        let journeys = makeService(identity: identity, events: events, directory: directory, presenter: presenter,
            journalBeforePersist: { try persistenceFailures?.beforePersist() },
            onPresentationContinuationFinished: { continuation.notify() })
        sink.route = { request in
            await journeys.handleEvent(NuxieEvent(id: request.eventId, name: request.name, distinctId: request.distinctId, properties: request.properties ?? [:]))
            return true
        }
        await journeys.initialize()
        await journeys.profileDidCommit(snapshot, distinctId: "customer")
        XCTAssertTrue(presenter.isExperiencePresented)
        await controller.runtimeDelegate?.experienceViewController(controller, didChangeScreen: "state-screen")
        controller.journeyID = try XCTUnwrap(presenter.presentedJourneyId)
        return .init(leg: leg, controller: controller, presenter: presenter, journeys: journeys, store: store, sink: sink, continuation: continuation,
            journal: try JourneyRunJournal(directory: directory, distinctId: "customer"))
    }
}

@MainActor
private struct PaywallHarness {
    let leg: Journey
    let controller: PaywallEngineController
    let presenter: ExperiencePresentationService
    let journeys: JourneyService
    let store: PaywallStore
    let sink: PaywallOutcomeSink
    let continuation: PaywallContinuationSignal
    let journal: JourneyRunJournal
}

// Only the window shell and engine command drain are supplied by the test.
// Purchase, restore, action resolution and Journey presentation are production code.
@MainActor
private final class PaywallEngineController: MockExperienceViewController {
    var screen: ExperienceInteractiveScreen!
    var journeyID = ""
    var sequence: UInt64 = 0
    private var feedback: [JourneyViewModelValue] = []
    var beforeFailureFeedback: (() -> Void)?
    override func applyViewModelValue(path: VmPathRef, value: Any, screenId: String? = nil, instanceId: String? = nil) {
        if path.path == "paywall/purchase/status", value as? String == "error" { beforeFailureFeedback?() }
        feedback.append(.init(viewModelName: path.viewModelName ?? "Runtime", instanceId: instanceId, path: path.path, value: AnyCodable(value)))
    }
    override func prepareForDismissal(reason: CloseReason? = nil) async {
        // The test window has no native screen dismissal lifecycle.
    }
    func select(_ placement: String) {
        runtimeDelegate?.experienceViewController(self, didEmitViewModelChange: .init(path: .init(path: "paywall/selectedPlacementId"), value: placement,
            source: "runtime", screenId: "state-screen", instanceId: "root-sdk-id", isTrigger: false))
    }
    func buy(event: String = "purchase") async -> Bool? {
        defer { sequence += 1 }
        let batch = ScreenEmissionBatch(journeyId: journeyID, executionOwnershipEpoch: 0, lifecycleGeneration: 0, presentationEpoch: 1,
            batchSequence: sequence, previousCommittedBatchSequence: sequence == 0 ? nil : sequence - 1, invocationId: "tap-\(sequence)",
            source: .init(screenId: "state-screen", actionId: "buy", componentId: nil, instanceId: nil),
            emissions: [.init(id: UUID.v7().uuidString, sequence: sequence, occurredAt: "2026-08-29T12:00:00Z", name: event, payload: [:])])
        return await runtimeDelegate?.experienceViewController(self, didEmitScreenEmissionBatch: batch, frameSources: nil)
    }
    func status(_ operation: String) async throws -> String? { try await field(operation, "status") }
    func field(_ operation: String, _ field: String) async throws -> String? {
        let pending = feedback; feedback.removeAll()
        for command in try ExperienceInteractiveStateCompiler.signedValues(pending) { _ = try await screen.applyStateCommand(.value(command)) }
        let snapshot = try await screen.snapshot()
        let value = snapshot.values.first { $0.name == field && $0.ownerInstanceID == snapshot.values.first(where: { $0.name == operation })?.value.referencedID }?.value
        if field == "status", case .integer(let index)? = value {
            let labels = operation == "purchase" ? ["idle", "running", "success", "error", "cancelled"] : ["idle", "running", "success", "error", "not_found"]
            return Int(index) < labels.count ? labels[Int(index)] : nil
        }
        return value?.text
    }
}

private extension ExperienceInteractiveViewModelValue {
    var referencedID: UInt64? { if case .referencedInstance(let id) = self { return id }; return nil }
    var text: String? {
        if case .bytes(let value) = self { return String(data: value, encoding: .utf8) }
        return nil
    }
}

private final class PaywallOutcomeSink: SystemEventSink, @unchecked Sendable {
    var terminal = XCTestExpectation(description: "terminal")
    var route: (@Sendable (StableSystemEventCaptureRequest) async -> Bool)?
    func emit(_ name: String, properties: [String: Any]?) {}
    func capture(_ request: StableSystemEventCaptureRequest) async -> Bool {
        let accepted = await route?(request) ?? false
        terminal.fulfill()
        return accepted
    }
    func captureOnly(_ request: StableSystemEventCaptureRequest) async -> Bool { true }
}

private final class PaywallStore: NuxiePurchaseDelegate, @unchecked Sendable {
    private let lock = NSLock()
    var purchaseResult: PurchaseResult = .cancelled
    var restoreResult: RestoreResult = .noPurchases
    var started = XCTestExpectation(description: "store entered")
    var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var purchaseCallCount = 0
    func purchase(product: StoreProduct) async -> PurchaseResult {
        lock.withLock { purchaseCallCount += 1 }
        await pause()
        return purchaseResult
    }
    func restorePurchases() async -> RestoreResult {
        await pause()
        return restoreResult
    }
    private func pause() async {
        if hold {
            await withCheckedContinuation { pending in
                lock.withLock { continuation = pending }
                started.fulfill()
            }
        } else { started.fulfill() }
    }
    func release() {
        let pending = lock.withLock { let pending = continuation; continuation = nil; return pending }
        pending?.resume()
    }
}

private final class PaywallContinuationSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var expected = XCTestExpectation(description: "continuation finished")
    private var notified = false
    var finished: XCTestExpectation {
        get { lock.withLock { expected } }
        set { lock.withLock { expected = newValue; notified = false } }
    }
    func notify() {
        let pending: XCTestExpectation? = lock.withLock {
            guard !notified else { return nil }
            notified = true
            return expected
        }
        pending?.fulfill()
    }
}

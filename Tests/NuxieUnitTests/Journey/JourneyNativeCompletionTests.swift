#if canImport(UIKit)
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class JourneyNativeCompletionTests: JourneyTestCase {
    @MainActor
    func testVerifiedNativeCheckoutAfterCancelRoutesCompletionAndAuthoredDismiss() async throws {
        let directory = temporaryDirectory()
        let base = try await authenticatedRenderedSnapshot(JourneyPlaneProfileTestFixture.load(entryKey: "renderedEntry"))
        let action: [String: JourneyReleaseJSONValue] = ["type": .string("purchase"), "placementId": .string("golden:monthly")]
        var snapshot = replacing(base, entryStepId: "present", steps: [
            .init(kind: .action, id: "present", action: ["type": .string("navigate"), "screenId": .string("screen_welcome")], outlets: [:], outcome: nil),
            .init(kind: .action, id: "commerce", action: action,
                outlets: ["completed": "dismiss"], outcome: nil),
            .init(kind: .action, id: "dismiss", action: ["type": .string("dismiss")], outlets: [:], outcome: nil),
        ], routes: [.init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: "buy", entryStepId: "commerce")])
        let leg = try XCTUnwrap(snapshot.releasesByDigest.values.first).descriptor.leg
        snapshot = replacing(snapshot,
            offers: [.init(screenId: "screen_welcome", placementIds: ["golden:monthly"],
                alreadyEntitledStepId: "skip", unknownStepId: "skip")],
            products: [releaseProductDocument(id: "monthly", storeProductId: "com.example.pro", featureIds: ["premium"])],
            steps: leg.steps + [.init(kind: .complete, id: "skip", action: nil, outlets: nil, outcome: "skipped")],
            routes: leg.routes + [
                .init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: Journey.Offer.alreadyEntitledEvent, entryStepId: "skip"),
                .init(host: .init(kind: .screen, screenId: "screen_welcome"), eventName: Journey.Offer.accessUnknownEvent, entryStepId: "skip"),
            ])
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let store = SQLiteEventStore()
        let api = MockNuxieApi()
        let events = EventLog(identity: identity, dateProvider: MockDateProvider(), apiClient: api, store: store)
        let sink = EventLogSystemEventSink(events: events)
        let adapter = MockNativeStoreKitPurchaseAdapter()
        adapter.configureCancelled()
        let settings = NuxieRuntimeSettings(localeIdentifier: nil, purchaseDelegate: nil, purchaseHandlingMode: .full)
        let features = NativeCompletionFeatureService()
        let evidence = NativeCompletionEvidenceStore(directory: directory)
        let serviceBox = LateBound<TransactionService>()
        let observer = TransactionObserver(api: api, features: features, identity: identity,
            settings: settings, eventSink: sink, transactionServiceProvider: { serviceBox.get() },
            evidenceStore: evidence, unfinishedRecoveryTransactions: { [] },
            currentEntitlementRecoveryTransactions: { [] })
        let transactions = TransactionService(productService: ProductService(), transactionObserver: observer,
            pendingPurchaseStore: PendingPurchaseStore(customStoragePath: directory),
            dateProvider: MockDateProvider(), settings: settings, eventSink: sink,
            identityService: identity, nativePurchaseAdapter: adapter, featureService: features)
        serviceBox.set(transactions)
        var product = StoreProduct(productId: "monthly", storeProductId: "com.example.pro",
            placementId: "golden:monthly", name: "Monthly", price: "$9.99", period: nil)
        product.purchaseContext = PurchaseCommercialContext(
            release: AuthenticatedJourneyReleaseID(identity: release.descriptor.identity,
                descriptorSHA256: release.descriptorSHA256),
            placementId: "golden:monthly", productId: "monthly", storeProductId: "com.example.pro",
            displayPrice: "$9.99", price: 9.99)
        // The adapter owns StoreKit in this unit proof. Let the controller admit
        // that supplied catalog product without asking the App Store daemon.
        product.isTestStoreProduct = true
        let controller = NativeCompletionController(mockExperienceVersionId: release.descriptor.identity.experienceVersionId,
            mockScreenId: "screen_welcome", eventLog: events, products: [product],
            transactionService: transactions, systemEventSink: sink)
        let experiences = MockExperienceService()
        experiences.defaultMockViewController = controller
        let presentations = ExperiencePresentationService(windowProvider: MockWindowProvider(),
            experiences: experiences, eventLog: events, identity: identity)
        let journeys = JourneyService(identity: identity, events: events,
            dateProvider: MockDateProvider(), sleepProvider: MockSleepProvider(), journalDirectory: directory,
            storageScope: .testFixture, featureAccess: { _ in .notFound },
            dispatcher: JourneyEffectDispatcher(identity: identity, events: events), presenter: presentations,
            pinnedReleaseAuthenticator: { _, _ in throw JourneyJournalError.invalidState },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed), currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!)
        addTeardownBlock {
            await observer.stopListening()
            await journeys.shutdown()
            await events.close()
            try? FileManager.default.removeItem(at: directory)
        }
        let admission = events.reserveCommittedAdmission { journeys.eventAdmissionGeneration() }
        await events.subscribeAcknowledgingCommitted(reservation: admission) { event, generation in
            await journeys.handleEvent(event, admittedProfileGeneration: generation)
        }
        let configuration = NuxieConfiguration(apiKey: "native-completion-test")
        configuration.testingOverrides.suppressBackgroundWork = true
        configuration.testingOverrides.customStoragePath = directory
        try await events.configure(configuration: configuration)
        await journeys.initialize()
        await journeys.profileDidCommit(snapshot, distinctId: "customer")
        let journeyID = try XCTUnwrap(presentations.presentedJourneyId)
        await controller.runtimeDelegate?.experienceViewController(controller, didChangeScreen: "screen_welcome")
        func subscribe(sequence: Int) async {
            let batch = ScreenEmissionBatch(journeyId: journeyID, executionOwnershipEpoch: 0,
                lifecycleGeneration: 0, presentationEpoch: 1, batchSequence: UInt64(sequence),
                previousCommittedBatchSequence: sequence == 0 ? nil : UInt64(sequence - 1),
                invocationId: "native-checkout-\(sequence)",
                source: .init(screenId: "screen_welcome", actionId: "buy", componentId: nil, instanceId: nil),
                emissions: [.init(id: sequence == 0 ? "00000000-0000-7000-8000-000000000911" : "00000000-0000-7000-8000-000000000912",
                    sequence: UInt64(sequence), occurredAt: "2026-08-29T12:00:00Z", name: "buy", payload: [:])])
            let dispatched = expectation(description: "Native screen action dispatched")
            await events.subscribeCommitted(where: { $0.name == "native-buy-\(sequence)" }) { _ in
                let accepted = await controller.runtimeDelegate?.experienceViewController(controller,
                    didEmitScreenEmissionBatch: batch, frameSources: nil)
                XCTAssertEqual(accepted, true)
                dispatched.fulfill()
            }
            events.track("native-buy-\(sequence)")
            await fulfillment(of: [dispatched], timeout: 2)
        }
        await subscribe(sequence: 0)
        for _ in 0..<200 {
            if try await store.queryRecentEvents().contains(where: { $0.name == SystemEventNames.purchaseCancelled }) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await events.drain()
        let cancelledEvents = try await store.queryRecentEvents().filter { $0.name == SystemEventNames.purchaseCancelled }
        XCTAssertEqual(cancelledEvents.count, 1)
        XCTAssertTrue(presentations.isExperiencePresented)
        adapter.configureVerifiedPurchase(productId: "com.example.pro")
        await subscribe(sequence: 1)
        for _ in 0..<200 {
            if evidence.delivered != nil && !presentations.isExperiencePresented { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let retainedEvents = try await store.queryRecentEvents()
        let completed = retainedEvents.filter { $0.name == JourneyEvents.journeyCompleted }
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.getPropertiesDict()["outcome"] as? String, "completed")
        XCTAssertEqual(completed.first?.getPropertiesDict()["journey_id"] as? String, journeyID)
        XCTAssertFalse(presentations.isExperiencePresented)
        XCTAssertEqual(adapter.purchasedProducts.count, 2)
        XCTAssertEqual(controller.correlations.count, 2)
        XCTAssertEqual(cancelledEvents.first?.id, controller.correlations.first?.eventId)
        XCTAssertNotEqual(controller.correlations.first?.eventId, controller.correlations.last?.eventId)
        XCTAssertEqual(adapter.finishCallCount, 1)
        let purchaseEvents = retainedEvents.filter { $0.name == SystemEventNames.purchaseCompleted }
        XCTAssertEqual(purchaseEvents.count, 1)
        XCTAssertEqual(purchaseEvents.first?.id, controller.correlations.last?.eventId)
        let delivered = try XCTUnwrap(evidence.delivered)
        XCTAssertEqual(delivered.checkoutCompletionEventId, controller.correlations.last?.eventId)
        XCTAssertNotNil(delivered.completionDeliveredAt)
    }
}

@MainActor
private final class NativeCompletionController: MockExperienceViewController {
    private(set) var correlations: [CommerceOutcomeCorrelation] = []
    override func performPurchase(placementId: String, outcomeCorrelation: CommerceOutcomeCorrelation?) {
        if let outcomeCorrelation { correlations.append(outcomeCorrelation) }
        super.performPurchase(placementId: placementId, outcomeCorrelation: outcomeCorrelation)
    }
    override func prepareForDismissal(reason: CloseReason? = nil) async {
        await runtimeDelegate?.experienceViewController(self, didDismissScreen: "screen_welcome",
            revealingScreenId: nil, method: reason.map { ExperienceScreenDismissalMethod.value(for: $0) } ?? "experience")
    }
}

private final class NativeCompletionEvidenceStore: TransactionEvidenceStoreProtocol, @unchecked Sendable {
    private let disk: TransactionEvidenceStore
    private let lock = NSLock()
    private var deliveredRow: StoredTransactionEvidence?
    init(directory: URL) { disk = TransactionEvidenceStore(customStoragePath: directory) }
    var delivered: StoredTransactionEvidence? { lock.withLock { deliveredRow } }
    func load() -> StoreReadResult<[String: StoredTransactionEvidence]> { disk.load() }
    func save(_ entries: [String: StoredTransactionEvidence]) -> Bool {
        guard disk.save(entries) else { return false }
        if let delivered = entries.values.first(where: { $0.completionDeliveredAt != nil }) {
            lock.withLock { deliveredRow = delivered }
        }
        return true
    }
}

private actor NativeCompletionFeatureService {
    func getCached(featureId: String, entityId: String?) async -> FeatureAccess? {
        _ = featureId
        _ = entityId
        return nil
    }

    func getAllCached() async -> [String: FeatureAccess] { [:] }

    func check(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?
    ) async throws -> FeatureCheckResult {
        _ = featureId
        _ = requiredBalance
        _ = entityId
        throw NuxieNetworkError.invalidResponse
    }

    func checkWithCache(
        featureId: String,
        requiredBalance: Double?,
        entityId: String?,
        forceRefresh: Bool
    ) async throws -> FeatureAccess {
        _ = featureId
        _ = requiredBalance
        _ = entityId
        _ = forceRefresh
        return .notFound
    }

    func clearCache() async {}
    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {}
    func syncFeatureInfo() async {}
    func updateFromPurchase(_ features: [PurchaseFeature], distinctId: String) async {}
}

extension NativeCompletionFeatureService: FeatureServiceProtocol {}

#endif

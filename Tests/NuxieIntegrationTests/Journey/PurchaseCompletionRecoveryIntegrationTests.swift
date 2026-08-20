import Foundation
import Nimble
import Quick

@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class StartupPurchaseSyncAPI: PurchaseSynchronizing, Sendable {
    func syncTransaction(
        transactionJwt _: String,
        distinctId: String
    ) async throws -> PurchaseResponse {
        PurchaseResponse(
            success: true,
            customerId: distinctId,
            features: nil,
            error: nil
        )
    }
}

final class PurchaseCompletionRecoveryIntegrationTests: AsyncSpec {
    override class func spec() {
        describe("durable purchase completion routing") {
            var eventLog: EventLog!

            afterEach {
                await eventLog?.close()
            }

            it("retains a cold capture until the real JourneyService catalog is available") {
                let distinctId = "cold-customer"
                let mocks = MockFactory.shared
                mocks.identityService.setDistinctId(distinctId)
                mocks.profileService.effectiveExperienceReferences = nil
                mocks.profileService.activeExperienceReferences = nil

                let journeyStore = MockJourneyStore()
                let journeys = mocks.makeJourneyService(journeyStore: journeyStore)
                let unavailable = await journeys.handleCapturedEventForTrigger(
                    NuxieEvent(
                        id: "cold-direct-purchase-completion",
                        name: "$purchase_completed",
                        distinctId: distinctId
                    )
                )
                expect(unavailable).to(beNil())

                let captureStore = MockEventStore()
                eventLog = EventLog(
                    identity: mocks.identityService,
                    sessions: MockSessionService(),
                    dateProvider: mocks.dateProvider,
                    apiClient: mocks.nuxieApi,
                    store: captureStore
                )
                try await eventLog.configure(
                    configuration: NuxieConfiguration(apiKey: "test-api-key")
                )

                let featureInfo = FeatureInfo()
                let features = FeatureService(
                    api: mocks.nuxieApi,
                    identity: mocks.identityService,
                    profile: mocks.profileService,
                    dateProvider: mocks.dateProvider,
                    featureInfo: featureInfo,
                    cacheTTL: 300
                )
                let trigger = TriggerService(
                    eventLog: eventLog,
                    journeys: journeys,
                    features: features,
                    experiencePresentation: mocks.experiencePresentationService,
                    featureInfo: featureInfo,
                    triggerBroker: mocks.triggerBroker,
                    sleepProvider: mocks.sleepProvider,
                    dateProvider: mocks.dateProvider
                )
                let eventId = "purchase-completed:cold-transaction"

                let coldAttempt = await trigger.captureSystemEvent(
                    "$purchase_completed",
                    properties: ["transaction_id": "cold-transaction"],
                    eventId: eventId,
                    distinctId: distinctId
                )

                expect(coldAttempt) == false
                expect(captureStore.storedEvents.map(\.id)) == [eventId]
                expect(captureStore.pendingIds).to(contain(eventId))
                expect(journeyStore.hasHandledEvent(id: eventId)) == false

                mocks.profileService.effectiveExperienceReferences = []
                mocks.profileService.activeExperienceReferences = []
                let recoveredAttempt = await trigger.captureSystemEvent(
                    "$purchase_completed",
                    properties: ["transaction_id": "cold-transaction"],
                    eventId: eventId,
                    distinctId: distinctId
                )

                expect(recoveredAttempt) == true
                expect(captureStore.storedEvents.map(\.id)) == [eventId]
                expect(journeyStore.hasHandledEvent(id: eventId)) == true

                let receiptFailureEventId = "purchase-completed:receipt-failure"
                journeyStore.shouldThrowOnHandledEventRecord = true
                let receiptFailure = await trigger.captureSystemEvent(
                    "$purchase_completed",
                    properties: ["transaction_id": "receipt-failure"],
                    eventId: receiptFailureEventId,
                    distinctId: distinctId
                )

                expect(receiptFailure) == false
                expect(journeyStore.hasHandledEvent(id: receiptFailureEventId)) == false
                expect(captureStore.storedEvents.map(\.id)) == [
                    eventId,
                    receiptFailureEventId,
                ]

                // The successful retry must commit the receipt for the
                // already-routed event without routing through the catalog a
                // second time. Making the catalog unavailable proves that
                // this is a receipt retry, not a replay of Journey effects.
                mocks.profileService.effectiveExperienceReferences = nil
                journeyStore.shouldThrowOnHandledEventRecord = false
                let receiptRecovered = await trigger.captureSystemEvent(
                    "$purchase_completed",
                    properties: ["transaction_id": "receipt-failure"],
                    eventId: receiptFailureEventId,
                    distinctId: distinctId
                )

                expect(receiptRecovered) == true
                expect(journeyStore.hasHandledEvent(id: receiptFailureEventId)) == true
                expect(captureStore.storedEvents.map(\.id)) == [
                    eventId,
                    receiptFailureEventId,
                ]
            }

            it("acknowledges a terminal beforeSend drop without Journey routing or delivery") {
                let distinctId = "dropped-customer"
                let eventId = "purchase-completed:terminally-dropped"
                let mocks = MockFactory.shared
                mocks.identityService.setDistinctId(distinctId)
                mocks.profileService.effectiveExperienceReferences = []
                mocks.profileService.activeExperienceReferences = []
                let journeyStore = MockJourneyStore()
                let journeys = mocks.makeJourneyService(journeyStore: journeyStore)
                let captureStore = MockEventStore()
                eventLog = EventLog(
                    identity: mocks.identityService,
                    sessions: MockSessionService(),
                    dateProvider: mocks.dateProvider,
                    apiClient: mocks.nuxieApi,
                    store: captureStore
                )
                let configuration = NuxieConfiguration(apiKey: "test-api-key")
                configuration.beforeSend = { event in
                    event.name == "$purchase_completed" ? nil : event
                }
                try await eventLog.configure(configuration: configuration)
                let featureInfo = FeatureInfo()
                let trigger = TriggerService(
                    eventLog: eventLog,
                    journeys: journeys,
                    features: FeatureService(
                        api: mocks.nuxieApi,
                        identity: mocks.identityService,
                        profile: mocks.profileService,
                        dateProvider: mocks.dateProvider,
                        featureInfo: featureInfo,
                        cacheTTL: 300
                    ),
                    experiencePresentation: mocks.experiencePresentationService,
                    featureInfo: featureInfo,
                    triggerBroker: mocks.triggerBroker,
                    sleepProvider: mocks.sleepProvider,
                    dateProvider: mocks.dateProvider
                )

                let acknowledged = await trigger.captureSystemEvent(
                    "$purchase_completed",
                    properties: ["transaction_id": "terminally-dropped"],
                    eventId: eventId,
                    distinctId: distinctId
                )

                expect(acknowledged) == true
                expect(journeyStore.hasHandledEvent(id: eventId)) == false
                expect(captureStore.storedEvents).to(beEmpty())
                expect(captureStore.pendingIds).to(beEmpty())
                expect(captureStore.stableDroppedIds) == Set([eventId])
            }

            it("keeps durable routing unavailable while any catalog package fails to load") {
                let distinctId = "partial-catalog-customer"
                let eventId = "partial-catalog-completion"
                let mocks = MockFactory.shared
                mocks.identityService.setDistinctId(distinctId)
                mocks.profileService.effectiveExperienceReferences = [
                    ExperienceReference(
                        experienceId: "experience-1",
                        versionId: "missing-version"
                    ),
                ]
                mocks.profileService.activeExperienceReferences = []
                mocks.experienceService.failureError = URLError(.notConnectedToInternet)

                let journeyStore = MockJourneyStore()
                let journeys = mocks.makeJourneyService(journeyStore: journeyStore)
                let unavailable = await journeys.handleCapturedEventForTrigger(
                    NuxieEvent(
                        id: eventId,
                        name: "$purchase_completed",
                        distinctId: distinctId
                    )
                )

                expect(unavailable).to(beNil())
                expect(journeyStore.hasHandledEvent(id: eventId)) == false

                // An authenticated empty catalog is authoritative and may
                // safely acknowledge that no Journey matched.
                mocks.profileService.effectiveExperienceReferences = []
                mocks.experienceService.failureError = nil
                let authoritativeEmpty = await journeys.handleCapturedEventForTrigger(
                    NuxieEvent(
                        id: eventId,
                        name: "$purchase_completed",
                        distinctId: distinctId
                    )
                )

                expect(authoritativeEmpty).to(beEmpty())
                expect(journeyStore.hasHandledEvent(id: eventId)) == true
            }

            it("routes only an active checkout and keeps cold recovery capture-only") {
                let distinctId = "active-checkout-customer"
                let mocks = MockFactory.shared
                mocks.identityService.setDistinctId(distinctId)
                mocks.profileService.effectiveExperienceReferences = []
                mocks.profileService.activeExperienceReferences = []

                let journeyStore = MockJourneyStore()
                let journeys = mocks.makeJourneyService(journeyStore: journeyStore)
                let captureStore = MockEventStore()
                let configuredEventLog = EventLog(
                    identity: mocks.identityService,
                    sessions: MockSessionService(),
                    dateProvider: mocks.dateProvider,
                    apiClient: mocks.nuxieApi,
                    store: captureStore
                )
                eventLog = configuredEventLog
                try await configuredEventLog.configure(
                    configuration: NuxieConfiguration(apiKey: "test-api-key")
                )
                let featureInfo = FeatureInfo()
                let features = FeatureService(
                    api: mocks.nuxieApi,
                    identity: mocks.identityService,
                    profile: mocks.profileService,
                    dateProvider: mocks.dateProvider,
                    featureInfo: featureInfo,
                    cacheTTL: 300
                )
                @Sendable func makeTrigger(
                    _ journeyService: JourneyService
                ) -> TriggerService {
                    TriggerService(
                        eventLog: configuredEventLog,
                        journeys: journeyService,
                        features: features,
                        experiencePresentation: mocks.experiencePresentationService,
                        featureInfo: featureInfo,
                        triggerBroker: mocks.triggerBroker,
                        sleepProvider: mocks.sleepProvider,
                        dateProvider: mocks.dateProvider
                    )
                }
                let sink = TriggerSystemEventSink {
                    makeTrigger(journeys)
                }
                let activeEventId = "purchase-completed:active-checkout"
                let activeCaptured = await sink.capture(
                    "$purchase_completed",
                    properties: ["transaction_id": "active-checkout"],
                    eventId: activeEventId,
                    distinctId: distinctId
                )

                expect(activeCaptured) == true
                expect(journeyStore.hasHandledEvent(id: activeEventId)) == true

                let coldEventId = "purchase-completed:cold-recovery"
                let coldCaptured = await sink.captureOnly(
                    "$purchase_completed",
                    properties: ["transaction_id": "cold-recovery"],
                    eventId: coldEventId,
                    distinctId: distinctId
                )

                expect(coldCaptured) == true
                expect(journeyStore.hasHandledEvent(id: coldEventId)) == false

                // Model a process death after the active Journey effects but
                // before evidence acknowledgement. Relaunch recovery captures
                // the stable analytics event but never resurrects the ended
                // paywall's Journey in a fresh JourneyService.
                let relaunchedJourneyStore = MockJourneyStore()
                let relaunchedJourneys = mocks.makeJourneyService(
                    journeyStore: relaunchedJourneyStore
                )
                let relaunchedSink = TriggerSystemEventSink {
                    makeTrigger(relaunchedJourneys)
                }
                let recovered = await relaunchedSink.captureOnly(
                    "$purchase_completed",
                    properties: ["transaction_id": "active-checkout"],
                    eventId: activeEventId,
                    distinctId: distinctId
                )

                expect(recovered) == true
                expect(relaunchedJourneyStore.hasHandledEvent(id: activeEventId)) == false
                expect(captureStore.storedEvents.filter {
                    $0.id == activeEventId
                }).to(haveCount(1))
            }

            it("captures cold startup recovery without resurrecting Journey routing") {
                let distinctId = "startup-customer"
                let transactionId = "startup-transaction"
                let mocks = MockFactory.shared
                mocks.identityService.setDistinctId(distinctId)
                mocks.profileService.effectiveExperienceReferences = nil
                mocks.profileService.activeExperienceReferences = nil

                let journeyStore = MockJourneyStore()
                let journeys = mocks.makeJourneyService(journeyStore: journeyStore)
                let captureStore = MockEventStore()
                eventLog = EventLog(
                    identity: mocks.identityService,
                    sessions: MockSessionService(),
                    dateProvider: mocks.dateProvider,
                    apiClient: mocks.nuxieApi,
                    store: captureStore
                )
                try await eventLog.configure(
                    configuration: NuxieConfiguration(apiKey: "test-api-key")
                )
                let featureInfo = FeatureInfo()
                let features = FeatureService(
                    api: mocks.nuxieApi,
                    identity: mocks.identityService,
                    profile: mocks.profileService,
                    dateProvider: mocks.dateProvider,
                    featureInfo: featureInfo,
                    cacheTTL: 300
                )
                let trigger = TriggerService(
                    eventLog: eventLog,
                    journeys: journeys,
                    features: features,
                    experiencePresentation: mocks.experiencePresentationService,
                    featureInfo: featureInfo,
                    triggerBroker: mocks.triggerBroker,
                    sleepProvider: mocks.sleepProvider,
                    dateProvider: mocks.dateProvider
                )
                let eventSink = TriggerSystemEventSink { trigger }
                let scope = PurchaseStorageScope(
                    appIdentifierHash: "startup-app",
                    environment: "production",
                    storeEnvironment: .appStore
                )
                let context = PurchaseCommercialContext(
                    release: AuthenticatedExperienceReleaseID(
                        identity: ExperienceReleaseIdentity(
                            appId: "app-1",
                            environment: "live",
                            experienceId: "experience-1",
                            experienceVersionId: "version-1",
                            buildId: "build-1",
                            versionNumber: 1,
                            publishedAt: "2026-08-19T00:00:00Z",
                            publishedAtSeq: 1
                        ),
                        descriptorSHA256: String(repeating: "a", count: 64)
                    ),
                    placementId: "placement-1",
                    productId: "product-1",
                    storeProductId: "store-product-1",
                    displayPrice: "$9.99",
                    price: 9.99
                )
                let evidenceStore = InMemoryTransactionEvidenceStore()
                let evidence = StoredTransactionEvidence(
                    scope: scope,
                    transactionJws: "startup-jws",
                    transactionId: transactionId,
                    originalTransactionId: "startup-original",
                    productId: context.storeProductId,
                    distinctId: distinctId,
                    recordedAt: mocks.dateProvider.now(),
                    localEntitlementGrants: [],
                    isRevoked: false,
                    commercialContext: context
                )
                expect(evidenceStore.save([transactionId: evidence])) == true

                let settings = NuxieRuntimeSettings(
                    configuration: NuxieConfiguration(apiKey: "test-api-key")
                )
                let serviceBox = LateBound<TransactionService>()
                let observer = TransactionObserver(
                    api: StartupPurchaseSyncAPI(),
                    features: features,
                    identity: mocks.identityService,
                    settings: settings,
                    eventSink: eventSink,
                    transactionServiceProvider: { serviceBox.get() },
                    evidenceStore: evidenceStore,
                    localAccessStore: InMemoryLocalPurchaseAccessStore(),
                    purchaseStorageScope: scope,
                    dateProvider: mocks.dateProvider,
                    activeStoreOriginalTransactionIDs: { [] }
                )
                let transactionService = TransactionService(
                    productService: mocks.productService,
                    transactionObserver: observer,
                    pendingPurchaseStore: InMemoryPendingPurchaseStore(),
                    dateProvider: mocks.dateProvider,
                    settings: settings,
                    eventSink: eventSink,
                    purchaseStorageScope: scope,
                    identityService: mocks.identityService,
                    featureService: features
                )
                serviceBox.set(transactionService)

                await observer.retryStoredEvidence()
                let eventId = (["purchase-completed"] + scope.storageComponents
                    + [transactionId]).joined(separator: ":")
                expect(evidenceStore.load()).to(beEmpty())
                expect(captureStore.storedEvents.filter { $0.id == eventId }.map(\.id))
                    == [eventId]
                expect(journeyStore.hasHandledEvent(id: eventId)) == false

                // The profile-ready request is still serialized through the
                // recovery pump, but cold commercial completion is already
                // capture-only and must never route the terminated paywall.
                mocks.profileService.effectiveExperienceReferences = []
                mocks.profileService.activeExperienceReferences = []
                await NuxieSDK.recoverAfterProfilePrefetch(
                    journeys: journeys,
                    transactionObserver: observer
                )

                expect(evidenceStore.load()).to(beEmpty())
                expect(captureStore.storedEvents.filter { $0.id == eventId }.map(\.id))
                    == [eventId]
                expect(journeyStore.hasHandledEvent(id: eventId)) == false
            }
        }
    }
}

import Combine
import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private struct RecordedIdentityChange: Equatable {
    let from: String
    let to: String
}

private actor IdentityChangeJourneyRecorder: JourneyServiceProtocol {
    private var identityChanges: [RecordedIdentityChange] = []

    func startJourney(
        for experience: Experience,
        distinctId: String,
        originEventId: String?
    ) async -> Journey? { nil }

    func resumeJourney(_ journey: Journey) async {}
    func handleEvent(_ event: NuxieEvent) async {}
    func handleEventForTrigger(_ event: NuxieEvent) async -> [JourneyTriggerResult] { [] }
    func registerDetachedPresentationOwner(distinctId: String) async {}
    func getActiveJourneys(for distinctId: String) async -> [Journey] { [] }
    func checkExpiredTimers() async {}
    func initialize() async {}
    func onAppWillEnterForeground() async {}
    func onAppBecameActive() async {}
    func onAppDidEnterBackground() async {}
    func shutdown() async {}

    func handleUserChange(from oldDistinctId: String, to newDistinctId: String) async {
        identityChanges.append(RecordedIdentityChange(from: oldDistinctId, to: newDistinctId))
    }

    func recordedIdentityChanges() -> [RecordedIdentityChange] {
        identityChanges
    }
}

final class IdentityPublicationTests: XCTestCase {
    func testReentrantIdentifyRetainsEachTransitionLocalDurableEffect() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()

        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdk-identity-publication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: storage,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            await sdk.shutdown()
            try? FileManager.default.removeItem(at: storage)
        }

        let identity = IdentityService(customStoragePath: storage)
        let anonymousId = identity.getDistinctId()
        let info = FeatureInfo()
        let eventLog = MockEventLog()
        eventLog.identity = identity
        let journeys = IdentityChangeJourneyRecorder()

        let configuration = NuxieConfiguration(apiKey: "identity-publication-test")
        configuration.testingOverrides.customStoragePath = storage
        configuration.testingOverrides.suppressBackgroundWork = true
        var overrides = NuxieCoreOverrides()
        overrides.api = MockNuxieApi()
        overrides.identity = identity
        overrides.eventLog = eventLog
        overrides.featureInfo = info
        overrides.journeys = journeys
        overrides.profile = MockProfileService()
        overrides.transactionObserver = MockTransactionObserver()
        try sdk.setup(with: configuration, overrides: overrides)
        await sdk.waitForStartupTasks()

        eventLog.track("anonymous-before-identify")

        await MainActor.run {
            info.replaceOptimisticProjection(
                evidence: [
                    OptimisticPurchaseEvidence(
                        transactionId: "transaction-b",
                        distinctId: "customer-b",
                        backendSynced: false,
                        revoked: false
                    ),
                    OptimisticPurchaseEvidence(
                        transactionId: "transaction-c",
                        distinctId: "customer-c",
                        backendSynced: false,
                        revoked: false
                    ),
                ],
                descriptorAllowances: [
                    "transaction-b": [OptimisticEntitlementAllowance(
                        featureId: "customer-b-feature",
                        kind: .boolean,
                        unlimited: false,
                        allowance: nil
                    )],
                    "transaction-c": [OptimisticEntitlementAllowance(
                        featureId: "customer-c-feature",
                        kind: .boolean,
                        unlimited: false,
                        allowance: nil
                    )],
                ],
                distinctId: anonymousId
            )

            var shouldReenter = true
            let cancellable = info.$all.dropFirst().sink { features in
                guard shouldReenter,
                      features["customer-b-feature"]?.allowed == true else {
                    return
                }
                shouldReenter = false
                sdk.identify("customer-c")
            }

            sdk.identify("customer-b")
            withExtendedLifetime(cancellable) {}
        }

        await sdk.core?.userTransitions.drain()

        XCTAssertEqual(identity.getDistinctId(), "customer-c")
        let recordedIdentityChanges = await journeys.recordedIdentityChanges()
        XCTAssertEqual(
            recordedIdentityChanges,
            [
                RecordedIdentityChange(from: anonymousId, to: "customer-b"),
                RecordedIdentityChange(from: "customer-b", to: "customer-c"),
            ],
            "journey and presentation cleanup must receive each true previous identity"
        )

        let identifyEvents = eventLog.routedEvents.filter {
            $0.name == SystemEventNames.identify
        }
        XCTAssertEqual(identifyEvents.map(\.distinctId), ["customer-b", "customer-c"])
        XCTAssertEqual(identifyEvents.first?.properties["distinct_id"] as? String, "customer-b")
        XCTAssertEqual(
            identifyEvents.first?.properties["$anon_distinct_id"] as? String,
            anonymousId
        )
        XCTAssertEqual(identifyEvents.last?.properties["distinct_id"] as? String, "customer-c")
        XCTAssertNil(identifyEvents.last?.properties["$anon_distinct_id"])

        let migratedAnonymousEvent = eventLog.routedEvents.first {
            $0.name == "anonymous-before-identify"
        }
        XCTAssertEqual(
            migratedAnonymousEvent?.distinctId,
            "customer-b",
            "only the anonymous-to-identified transition migrates prior events"
        )
    }

    func testReentrantIdentityMutationMarksOuterTransitionSuperseded() async {
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("identity-publication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) }

        let identity = IdentityService(customStoragePath: storage)
        let committedOuterTransition = await MainActor.run {
            let info = FeatureInfo()
            identity.setDistinctId("customer-a")
            info.beginOptimisticProjectionPublication(
                epoch: UUID(),
                distinctId: "customer-a"
            )
            info.admitProfileSnapshot([:], admittedAt: Date())
            info.replaceOptimisticProjection(
                evidence: [
                    OptimisticPurchaseEvidence(
                        transactionId: "transaction-b",
                        distinctId: "customer-b",
                        backendSynced: false,
                        revoked: false
                    ),
                    OptimisticPurchaseEvidence(
                        transactionId: "transaction-c",
                        distinctId: "customer-c",
                        backendSynced: false,
                        revoked: false
                    ),
                ],
                descriptorAllowances: [
                    "transaction-b": [OptimisticEntitlementAllowance(
                        featureId: "customer-b-feature",
                        kind: .boolean,
                        unlimited: false,
                        allowance: nil
                    )],
                    "transaction-c": [OptimisticEntitlementAllowance(
                        featureId: "customer-c-feature",
                        kind: .boolean,
                        unlimited: false,
                        allowance: nil
                    )],
                ],
                distinctId: "customer-a"
            )

            var shouldReenter = true
            let cancellable = info.$all.dropFirst().sink { features in
                guard shouldReenter,
                      features["customer-b-feature"]?.allowed == true else {
                    return
                }
                shouldReenter = false
                let inner = identity.mutateIdentity(
                    .identify("customer-c"),
                    publishing: { transition in
                        info.setProjectionDistinctId(transition.current.distinctId)
                    }
                )
                XCTAssertEqual(inner?.current.distinctId, "customer-c")
            }

            let outer = identity.mutateIdentity(
                .identify("customer-b"),
                publishing: { transition in
                    info.setProjectionDistinctId(transition.current.distinctId)
                }
            )

            withExtendedLifetime(cancellable) {
                XCTAssertEqual(identity.getDistinctId(), "customer-c")
                XCTAssertFalse(info.isAllowed("customer-b-feature"))
                XCTAssertTrue(info.isAllowed("customer-c-feature"))
                XCTAssertEqual(info.state, .unknown)
            }
            return outer != nil
        }

        XCTAssertFalse(
            committedOuterTransition,
            "the outer transition must not be treated as current after nested publication"
        )
    }
}

import Foundation
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class NuxieDelegateDeliveryTests: XCTestCase {
    func testTrackWithResponseJourneyCapturesReachDelegateInOrderExactlyOnce() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        await MainActor.run { sdk.delegate = nil }

        let store = MockEventStore()
        let log = EventLog(
            identity: MockIdentityService(),
            sessions: MockSessionService(),
            dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(),
            store: store
        )
        let mocks = MockFactory.shared
        await mocks.resetAll()
        var overrides = mocks.unitTestOverrides()
        overrides.eventLog = log

        let recorder = await MainActor.run { ForwardingDelegateRecorder() }
        await MainActor.run { sdk.delegate = recorder }
        try sdk.setup(
            with: NuxieConfiguration(apiKey: "test-api-key"),
            overrides: overrides
        )
        await log.drain()

        let enrollment: [String: Any] = [
            "journey_id": "journey-1",
            "experience_id": "experience-1",
            "experience_version": "v1",
        ]
        _ = try await log.trackWithResponse(
            JourneyEvents.journeyEnrolled,
            properties: enrollment,
            flushStrategy: .none
        )
        _ = try await log.trackWithResponse(
            JourneyEvents.journeyMilestone,
            properties: ["journey_id": "journey-1", "milestone_id": "milestone-1"],
            flushStrategy: .none
        )
        _ = try await log.trackWithResponse(
            JourneyEvents.journeyExited,
            properties: ["journey_id": "journey-1", "reason": "dismissed"],
            flushStrategy: .none
        )
        await log.drain()

        let snapshot = await MainActor.run { recorder.snapshot() }
        let journeyActivityNames = snapshot.activityNames.filter {
            ["journey_started", "milestone_reached", "journey_ended"].contains($0)
        }
        XCTAssertEqual(journeyActivityNames, [
            "journey_started",
            "milestone_reached",
            "journey_ended",
        ])

        await MainActor.run { sdk.delegate = nil }
        await sdk.shutdown()
    }

    func testForwardingAndAppActionCallbacksUseMainActorAndExactSDKInstance() async {
        let sdk = NuxieSDK.shared
        let recorder = await MainActor.run { ForwardingDelegateRecorder() }
        await MainActor.run { sdk.delegate = recorder }

        let ref = ExperienceRef(
            experienceId: "exp-1",
            experienceVersion: "v1",
            journeyId: "journey-1"
        )
        await sdk.deliverActivity(NuxieActivityInfo(
            id: "event-1",
            timestamp: Date(timeIntervalSince1970: 1),
            receivedAt: Date(timeIntervalSince1970: 1),
            activity: .experienceShown(ref)
        ))
        await sdk.deliverAppAction(AppAction(
            name: "export",
            payload: ["format": .string("pdf")],
            experience: ref
        ))

        let snapshot = await MainActor.run { recorder.snapshot() }
        XCTAssertEqual(snapshot.activityNames, ["experience_shown"])
        XCTAssertEqual(snapshot.appActionNames, ["export"])
        XCTAssertTrue(snapshot.wasOnMainThread)
        XCTAssertTrue(snapshot.callbackSDK === sdk)
        await MainActor.run { sdk.delegate = nil }
    }

    func testCompositionDoesNotReplayCaptureToDelegateAttachedWhileRoutingIsBacklogged() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        await MainActor.run { sdk.delegate = nil }

        let store = MockEventStore()
        let identity = MockIdentityService()
        identity.setDistinctId("user-1")
        let log = EventLog(
            identity: identity,
            sessions: MockSessionService(),
            dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(),
            store: store
        )
        let routeGate = DelegateRouteGate()
        await log.subscribeCommitted(
            where: { $0.name == "route_blocker" }
        ) { _ in
            await routeGate.suspendUntilReleased()
        }

        let mocks = MockFactory.shared
        await mocks.resetAll()
        var overrides = mocks.unitTestOverrides()
        overrides.eventLog = log
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        try sdk.setup(with: configuration, overrides: overrides)
        await log.drain()

        log.track(
            "route_blocker",
            properties: nil,
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        await routeGate.waitUntilSuspended()
        log.track(
            SystemEventNames.appOpened,
            properties: nil,
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
        await log.drainCapturedEvents()

        let recorder = await MainActor.run { ForwardingDelegateRecorder() }
        await MainActor.run { sdk.delegate = recorder }
        await routeGate.release()
        await log.drain()

        let snapshot = await MainActor.run { recorder.snapshot() }
        XCTAssertTrue(snapshot.activityNames.isEmpty)
        await MainActor.run { sdk.delegate = nil }
        await sdk.shutdown()
    }

    func testLateDelegateReceivesJourneySummariesAfterEarlierContextCapture() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        await MainActor.run { sdk.delegate = nil }

        let store = MockEventStore()
        let log = EventLog(
            identity: MockIdentityService(),
            sessions: MockSessionService(),
            dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(),
            store: store
        )
        let mocks = MockFactory.shared
        await mocks.resetAll()
        var overrides = mocks.unitTestOverrides()
        overrides.eventLog = log
        try sdk.setup(
            with: NuxieConfiguration(apiKey: "test-api-key"),
            overrides: overrides
        )
        await log.drain()

        _ = try await log.trackWithResponse(
            JourneyEvents.journeyEnrolled,
            properties: [
                "journey_id": "journey-1",
                "experience_id": "experience-1",
                "experience_version": "v1",
            ],
            flushStrategy: .none
        )
        await log.drain()

        let recorder = await MainActor.run { ForwardingDelegateRecorder() }
        await MainActor.run { sdk.delegate = recorder }
        _ = try await log.trackWithResponse(
            JourneyEvents.journeyMilestone,
            properties: ["journey_id": "journey-1", "milestone_id": "milestone-1"],
            flushStrategy: .none
        )
        _ = try await log.trackWithResponse(
            JourneyEvents.journeyExited,
            properties: ["journey_id": "journey-1", "reason": "dismissed"],
            flushStrategy: .none
        )
        await log.drain()

        let snapshot = await MainActor.run { recorder.snapshot() }
        XCTAssertEqual(snapshot.activityNames, ["milestone_reached", "journey_ended"])

        await MainActor.run { sdk.delegate = nil }
        await sdk.shutdown()
    }

    func testBeforeSendDropSuppressesDirectJourneyActivityWithoutChangingDurableJourneyFact() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        await MainActor.run { sdk.delegate = nil }

        let store = MockEventStore()
        let log = EventLog(
            identity: MockIdentityService(),
            sessions: MockSessionService(),
            dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(),
            store: store
        )
        let mocks = MockFactory.shared
        await mocks.resetAll()
        var overrides = mocks.unitTestOverrides()
        overrides.eventLog = log
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.beforeSend = { event in
            event.name == JourneyEvents.journeyEnrolled ? nil : event
        }
        let recorder = await MainActor.run { ForwardingDelegateRecorder() }
        await MainActor.run { sdk.delegate = recorder }
        try sdk.setup(with: configuration, overrides: overrides)
        await log.drain()

        _ = try await log.trackWithResponse(
            JourneyEvents.journeyEnrolled,
            properties: [
                "journey_id": "journey-1",
                "experience_id": "experience-1",
                "experience_version": "v1",
            ],
            flushStrategy: .none
        )
        await log.drain()

        let snapshot = await MainActor.run { recorder.snapshot() }
        XCTAssertFalse(snapshot.activityNames.contains("journey_started"))
        XCTAssertTrue(store.storedEvents.contains { $0.name == JourneyEvents.journeyEnrolled })

        await MainActor.run { sdk.delegate = nil }
        await sdk.shutdown()
    }

    func testRejectedFeatureUseDoesNotPersistOrForwardActivity() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        await MainActor.run { sdk.delegate = nil }

        let mocks = MockFactory.shared
        await mocks.resetAll()
        let store = MockEventStore()
        let log = EventLog(
            identity: mocks.identityService,
            sessions: MockSessionService(),
            dateProvider: mocks.dateProvider,
            apiClient: mocks.nuxieApi,
            store: store
        )
        var overrides = mocks.unitTestOverrides()
        overrides.eventLog = log
        await mocks.nuxieApi.configureTrackEventResponse(status: "error")
        let recorder = await MainActor.run { ForwardingDelegateRecorder() }
        await MainActor.run { sdk.delegate = recorder }
        try sdk.setup(
            with: NuxieConfiguration(apiKey: "test-api-key"),
            overrides: overrides
        )
        await log.drain()

        let result = try await sdk.useFeatureAndWait("credits")
        await log.drain()

        let snapshot = await MainActor.run { recorder.snapshot() }
        XCTAssertFalse(result.success)
        XCTAssertFalse(snapshot.activityNames.contains("feature_used"))
        XCTAssertFalse(store.storedEvents.contains { $0.name == SystemEventNames.featureUsed })

        await MainActor.run { sdk.delegate = nil }
        await sdk.shutdown()
    }
}

private actor DelegateRouteGate {
    private var isSuspended = false
    private var isReleased = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspendUntilReleased() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !isReleased else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !isSuspended else { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@MainActor
private final class ForwardingDelegateRecorder: NuxieDelegate {
    private var activityNames: [String] = []
    private var appActionNames: [String] = []
    private var wasOnMainThread = true
    private weak var callbackSDK: NuxieSDK?

    func nuxieDidEmit(_ info: NuxieActivityInfo) {
        wasOnMainThread = wasOnMainThread && Thread.isMainThread
        activityNames.append(info.name)
    }

    func nuxie(_ sdk: NuxieSDK, didRequestAppAction action: AppAction) {
        wasOnMainThread = wasOnMainThread && Thread.isMainThread
        callbackSDK = sdk
        appActionNames.append(action.name)
    }

    func snapshot() -> (
        activityNames: [String],
        appActionNames: [String],
        wasOnMainThread: Bool,
        callbackSDK: NuxieSDK?
    ) {
        (activityNames, appActionNames, wasOnMainThread, callbackSDK)
    }
}

import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class SupersedingProfileAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var readCount: Int {
        lock.withLock { reads }
    }

    func isCurrent() -> Bool {
        lock.withLock {
            reads += 1
            return reads == 1
        }
    }
}

final class DeviceLegJournalPersistenceFailures: @unchecked Sendable {
    private enum InjectedFailure: Error {
        case persist
    }

    private let lock = NSLock()
    private var remaining = 0

    func failNext(_ count: Int) {
        lock.withLock { remaining = max(count, 0) }
    }

    func beforePersist() throws {
        let shouldFail = lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        if shouldFail {
            throw InjectedFailure.persist
        }
    }
}

final class DeviceLegBeforeSendCallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var callCount: Int { lock.withLock { count } }

    func record() {
        lock.withLock { count += 1 }
    }
}

struct RenderedDeviceLegTestContext {
    let directory: URL
    let snapshot: DeviceLegProfileCatalog.Snapshot
    let identity: MockIdentityService
    let events: MockEventLog
    let presenter: RecordingDeviceLegPresenter
    let service: DeviceLegService
    let journal: DeviceLegRunJournal
}

struct RenderedDeviceLegHarness {
    let directory: URL
    let events: MockEventLog
    let presenter: RecordingDeviceLegPresenter
    let service: DeviceLegService
    let request: DeviceLegPresentationRequest
    let journal: DeviceLegRunJournal
}

actor DeviceLegNthRoutedCaptureGate {
    private let eventName: String
    private let suspendedCall: Int
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?

    init(eventName: String, suspendedCall: Int) {
        self.eventName = eventName
        self.suspendedCall = suspendedCall
    }

    func intercept(event: String) async {
        guard event == eventName else { return }
        count += 1
        guard count == suspendedCall else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func observationCount() -> Int { count }
    func isSuspended() -> Bool { continuation != nil }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

final class DeviceLegCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool { lock.withLock { completed } }

    func finish() {
        lock.withLock { completed = true }
    }
}

class DeviceLegTestCase: XCTestCase {}

extension DeviceLegTestCase {
    func releaseProductDocument(
        id: String,
        storeProductId: String,
        featureIds: [String]
    ) -> ExperienceReleaseJSONValue {
        .object([
            "id": .string(id),
            "type": .string("subscription"),
            "store": .object([
                "platform": .string("apple_app_store"),
                "productId": .string(storeProductId),
                "productType": .string("autoRenewable"),
            ]),
            "preview": .object([
                "name": .string(id),
                "description": .string(id),
                "price": .string("$1.00"),
                "period": .string("month"),
                "periodCount": .number(1),
                "periodLabel": .string("month"),
                "hasTrial": .bool(false),
                "trialLabel": .string(""),
                "introOfferLabel": .string(""),
                "renewalLabel": .string("$1.00/month"),
            ]),
            "entitlements": .array(featureIds.map { featureId in
                .object([
                    "id": .string(featureId),
                    "featureId": .string(featureId),
                    "purchaseUsageFeatureIds": .array([]),
                ])
            }),
        ])
    }

    func authenticatedSnapshot(
        _ fixture: DeviceLegPlaneProfileTestFixture,
        supportedRuntime: ExperienceReleaseSupportedRuntime = ExperienceReleaseRuntime.current
    ) async throws -> DeviceLegProfileCatalog.Snapshot {
        let catalog = DeviceLegProfileCatalog(
            authorizationKeys: [ExperiencePackageAuthorizationKey(
                keyID: "TEST_ONLY_DEV_KEYPAIR",
                ed25519PublicKeyBytes: fixture.publicKey
            )],
            supportedRuntime: supportedRuntime,
            highWaterStore: InMemoryExperienceReleaseHighWaterStore()
        )
        let prepared = try await catalog.prepare(
            fixture.profile,
            authority: fixture.deliveryAuthority
        )
        _ = try await catalog.commit(prepared, distinctId: "customer")
        let snapshot = await catalog.snapshot(distinctId: "customer")
        return try XCTUnwrap(snapshot)
    }

    func authenticatedRenderedSnapshot(
        _ fixture: DeviceLegPlaneProfileTestFixture
    ) async throws -> DeviceLegProfileCatalog.Snapshot {
        let entry = try XCTUnwrap(fixture.profile.releases.first)
        let descriptorBytes = try XCTUnwrap(Data(
            base64Encoded: entry.envelope.descriptorBytesBase64
        ))
        let descriptor = try XCTUnwrap(
            JSONSerialization.jsonObject(with: descriptorBytes)
                as? [String: Any]
        )
        let requirements = try XCTUnwrap(
            descriptor["requirements"] as? [String: Any]
        )
        let luau = try XCTUnwrap(requirements["luau"] as? [String: Any])
        let scene = try XCTUnwrap(
            requirements["sceneFormat"] as? [String: Any]
        )
        let timezone = try XCTUnwrap(
            requirements["timezoneData"] as? [String: Any]
        )
        let supportedRuntime = ExperienceReleaseSupportedRuntime(
            currentSdkVersion: try XCTUnwrap(
                requirements["minimumSdkVersion"] as? String
            ),
            supportedRuntimeRevisions: [try XCTUnwrap(
                requirements["runtimeRevision"] as? String
            )],
            supportedLuauRevisions: [
                try XCTUnwrap(luau["revision"] as? String): Set(
                    try XCTUnwrap(luau["bytecodeVersions"] as? [Int])
                ),
            ],
            sceneFormat: .init(
                major: try XCTUnwrap(scene["major"] as? Int),
                minor: try XCTUnwrap(scene["minor"] as? Int)
            ),
            timezoneDataRevision: try XCTUnwrap(
                timezone["revision"] as? String
            ),
            timezoneDataSHA256: try XCTUnwrap(
                timezone["sha256"] as? String
            ),
            supportedCapabilities: Set(try XCTUnwrap(
                requirements["requiredCapabilities"] as? [String]
            ))
        )
        return try await authenticatedSnapshot(
            fixture,
            supportedRuntime: supportedRuntime
        )
    }

    func makeRenderedDeviceLegHarness(
        _ preparedTriggerBeforeSend:
            (@Sendable (NuxieEvent) -> NuxieEvent?)? = nil
    ) async throws -> RenderedDeviceLegHarness {
        let context = try await makeRenderedDeviceLegTestContext(
            preparedTriggerBeforeSend: preparedTriggerBeforeSend
        )
        do {
            await context.service.profileDidCommit(
                context.snapshot,
                distinctId: "customer"
            )
            let presentedRequest = await MainActor.run {
                context.presenter.request
            }
            let request = try XCTUnwrap(presentedRequest)
            return RenderedDeviceLegHarness(
                directory: context.directory,
                events: context.events,
                presenter: context.presenter,
                service: context.service,
                request: request,
                journal: context.journal
            )
        } catch {
            removeTemporaryDirectoryIfPresent(context.directory)
            throw error
        }
    }

    func makeRenderedDeviceLegTestContext(
        snapshot: DeviceLegProfileCatalog.Snapshot? = nil,
        presenterAvailable: Bool = true,
        preparedTriggerBeforeSend:
            (@Sendable (NuxieEvent) -> NuxieEvent?)? = nil
    ) async throws -> RenderedDeviceLegTestContext {
        let directory = temporaryDirectory()
        do {
            let resolvedSnapshot: DeviceLegProfileCatalog.Snapshot
            if let snapshot {
                resolvedSnapshot = snapshot
            } else {
                let fixture = try DeviceLegPlaneProfileTestFixture.load(
                    entryKey: "renderedEntry"
                )
                resolvedSnapshot = try await authenticatedRenderedSnapshot(
                    fixture
                )
            }
            let identity = MockIdentityService()
            identity.setDistinctId("customer")
            let events = MockEventLog()
            events.identity = identity
            events.preparedTriggerBeforeSend = preparedTriggerBeforeSend
            let presenter = await MainActor.run {
                let value = RecordingDeviceLegPresenter()
                value.available = presenterAvailable
                return value
            }
            let service = makeService(
                identity: identity,
                events: events,
                directory: directory,
                presenter: presenter
            )
            await service.initialize()
            let journal = try DeviceLegRunJournal(
                directory: directory,
                distinctId: "customer"
            )
            return RenderedDeviceLegTestContext(
                directory: directory,
                snapshot: resolvedSnapshot,
                identity: identity,
                events: events,
                presenter: presenter,
                service: service,
                journal: journal
            )
        } catch {
            removeTemporaryDirectoryIfPresent(directory)
            throw error
        }
    }

    func renderedNavigationSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot
    ) -> DeviceLegProfileCatalog.Snapshot {
        replacing(
            snapshot,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "show_details",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_details"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: "continue",
                entryStepId: "show_details"
            )],
            screens: [
                .init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: []
                ),
                .init(
                    id: "screen_details",
                    defaultViewModelName: "DetailsModel",
                    defaultInstanceId: "details",
                    responseCaptures: []
                ),
            ]
        )
    }

    func renderedExperimentSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        assignment: DeviceLegFactTable.Assignment?
    ) -> DeviceLegProfileCatalog.Snapshot {
        var assignments: ExactJSONObject<DeviceLegFactTable.Assignment?> = [:]
        if let assignment {
            assignments["experiment_checkout"] = assignment
        }
        let facts = DeviceLegFactTable(
            properties: snapshot.profile.facts.properties,
            memberships: snapshot.profile.facts.memberships,
            assignments: assignments
        )
        return replacing(
            snapshot,
            entryStepId: "experiment",
            steps: [
                .init(
                    kind: .action,
                    id: "experiment",
                    action: [
                        "type": .string("experiment"),
                        "experimentId": .string("experiment_checkout"),
                        "variants": .array([
                            .object(["id": .string("variant_a")]),
                            .object(["id": .string("variant_b")]),
                        ]),
                    ],
                    outlets: [
                        "variant_a": "present_a",
                        "variant_b": "present_b",
                    ],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "present_a",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "present_b",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            factReferences: .init(
                propertyKeys: [],
                segmentIds: [],
                experimentIds: ["experiment_checkout"]
            ),
            facts: facts
        )
    }

    func renderedVisibleExperimentSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        assignment: DeviceLegFactTable.Assignment?,
        targetScreenId: String = "screen_details"
    ) -> DeviceLegProfileCatalog.Snapshot {
        var assignments: ExactJSONObject<DeviceLegFactTable.Assignment?> = [:]
        if let assignment {
            assignments["experiment_checkout"] = assignment
        }
        let facts = DeviceLegFactTable(
            properties: snapshot.profile.facts.properties,
            memberships: snapshot.profile.facts.memberships,
            assignments: assignments
        )
        return replacing(
            snapshot,
            entryStepId: "present",
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "experiment",
                    action: [
                        "type": .string("experiment"),
                        "experimentId": .string("experiment_checkout"),
                        "variants": .array([
                            .object(["id": .string("variant_a")]),
                            .object(["id": .string("variant_b")]),
                        ]),
                    ],
                    outlets: [
                        "variant_a": "present_variant",
                        "variant_b": "present_variant",
                    ],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "present_variant",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string(targetScreenId),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: "continue",
                entryStepId: "experiment"
            )],
            screens: [
                .init(
                    id: "screen_welcome",
                    defaultViewModelName: "WelcomeModel",
                    defaultInstanceId: "welcome",
                    responseCaptures: []
                ),
                .init(
                    id: "screen_details",
                    defaultViewModelName: "DetailsModel",
                    defaultInstanceId: "details",
                    responseCaptures: []
                ),
            ],
            factReferences: .init(
                propertyKeys: [],
                segmentIds: [],
                experimentIds: ["experiment_checkout"]
            ),
            facts: facts
        )
    }

    func renderedDismissalCompletionSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        eventName: String = SystemEventNames.screenDismissed
    ) -> DeviceLegProfileCatalog.Snapshot {
        replacing(
            snapshot,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "dismissed",
                    action: nil,
                    outlets: nil,
                    outcome: "screen_dismissed"
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: eventName,
                entryStepId: "dismissed"
            )],
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: []
            )]
        )
    }

    func renderedEventPropertyBranchSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        eventName: String
    ) -> DeviceLegProfileCatalog.Snapshot {
        replacing(
            snapshot,
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "branch_on_event",
                    action: [
                        "type": .string("condition"),
                        "branches": .array([.object([
                            "id": .string("allowed"),
                            "condition": .object([
                                "type": .string("Truthy"),
                                "value": .object([
                                    "type": .string("Event.Field"),
                                    "key": .string("allow"),
                                ]),
                            ]),
                        ])]),
                    ],
                    outlets: [
                        "allowed": "accepted",
                        "default": "rejected",
                    ],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "accepted",
                    action: nil,
                    outlets: nil,
                    outcome: "transformed"
                ),
                .init(
                    kind: .complete,
                    id: "rejected",
                    action: nil,
                    outlets: nil,
                    outcome: "original"
                ),
            ],
            routes: [.init(
                host: .init(kind: .screen, screenId: "screen_welcome"),
                eventName: eventName,
                entryStepId: "branch_on_event"
            )],
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: []
            )]
        )
    }

    func renderedResponseWaitSnapshot(
        _ snapshot: DeviceLegProfileCatalog.Snapshot
    ) -> DeviceLegProfileCatalog.Snapshot {
        let responseField: [String: ExperienceReleaseJSONValue] = [
            "key": .string("consent"),
            "type": .string("boolean"),
            "required": .bool(false),
        ]
        return replacing(
            snapshot,
            inputs: .init(
                eventFields: [],
                responseFields: [responseField]
            ),
            completionOutputs: [
                "responded": .init(
                    eventFields: [],
                    responseFields: [responseField]
                ),
                "timeout": .init(
                    eventFields: [],
                    responseFields: [responseField]
                ),
            ],
            steps: [
                .init(
                    kind: .action,
                    id: "present",
                    action: [
                        "type": .string("navigate"),
                        "screenId": .string("screen_welcome"),
                    ],
                    outlets: [:],
                    outcome: nil
                ),
                .init(
                    kind: .action,
                    id: "wait",
                    action: [
                        "type": .string("wait_until"),
                        "trigger": .object([
                            "kind": .string("response_change")
                        ]),
                        "condition": .object([
                            "type": .string("Truthy"),
                            "value": .object([
                                "type": .string("Response.Field"),
                                "key": .string("consent"),
                            ]),
                        ]),
                        "maxTimeMs": .number(10_000),
                    ],
                    outlets: [
                        "satisfied": "done",
                        "timeout": "timed_out",
                    ],
                    outcome: nil
                ),
                .init(
                    kind: .complete,
                    id: "done",
                    action: nil,
                    outlets: nil,
                    outcome: "responded"
                ),
                .init(
                    kind: .complete,
                    id: "timed_out",
                    action: nil,
                    outlets: nil,
                    outcome: "timeout"
                ),
            ],
            routes: [.init(
                host: .init(
                    kind: .screen,
                    screenId: "screen_welcome"
                ),
                eventName: "continue",
                entryStepId: "wait"
            )],
            screens: [.init(
                id: "screen_welcome",
                defaultViewModelName: "WelcomeModel",
                defaultInstanceId: "welcome",
                responseCaptures: ["consent"]
            )]
        )
    }

    func presentationBatch(
        request: DeviceLegPresentationRequest,
        presentationEpoch: UInt64 = 1,
        batchSequence: UInt64 = 0,
        previousCommittedBatchSequence: UInt64? = nil,
        sourceComponentId: String? = nil,
        sourceInstanceId: String? = nil,
        invocationId: String,
        emissions: [ScreenEmission]
    ) -> ScreenEmissionBatch {
        ScreenEmissionBatch(
            journeyId: request.owner.journeyId,
            executionOwnershipEpoch: 0,
            lifecycleGeneration: 0,
            presentationEpoch: presentationEpoch,
            batchSequence: batchSequence,
            previousCommittedBatchSequence: previousCommittedBatchSequence,
            invocationId: invocationId,
            source: .init(
                screenId: request.screenId,
                actionId: "continue",
                componentId: sourceComponentId,
                instanceId: sourceInstanceId
            ),
            emissions: emissions
        )
    }

    func assertDurableEventCommitIsRejected(
        action: [String: ExperienceReleaseJSONValue],
        effectId: String,
        revocation: DeviceLegCommitRevocation
    ) async throws {
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = try await authenticatedSnapshot(fixture)
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let release = try XCTUnwrap(snapshot.releasesByDigest[
            arm.reference.descriptorSha256
        ])
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let identityFence = try XCTUnwrap(identity.performWithCurrentIdentityFence(
            "customer",
            { _ in () }
        ))
        let executionFence = DeviceLegProfileFence()
        let executionFenceToken = executionFence.token()
        let store = MockEventStore()
        let log = EventLog(
            identity: identity,
            dateProvider: MockDateProvider(),
            apiClient: MockNuxieApi(),
            store: store
        )
        let configuration = NuxieConfiguration(apiKey: "test-api-key")
        configuration.testingOverrides.flushAt = 100
        try await log.configure(configuration: configuration)
        let historyCoverageBeforeCapture = try await store
            .historyCoverageStartingAt()
        store.suspendStableCaptureBeforeCommit(id: effectId)
        let dispatcher = DeviceLegEffectDispatcher(
            identity: identity,
            events: log
        )
        let dispatch = Task {
            await dispatcher.dispatch(.init(
                runId: "journey:0",
                journeyId: "journey",
                generation: 0,
                reference: arm.reference,
                release: release,
                stepId: "effect",
                action: action,
                context: .init(event: [:], responses: [:]),
                effectId: effectId,
                distinctId: "customer",
                identityFence: identityFence.token,
                executionFence: executionFence,
                executionFenceToken: executionFenceToken
            ))
        }
        for _ in 0..<1_000
        where !store.isStableCaptureBeforeCommitWaiting(id: effectId) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard store.isStableCaptureBeforeCommitWaiting(id: effectId) else {
            store.resumeStableCaptureBeforeCommit(id: effectId)
            _ = await dispatch.value
            await log.close()
            return XCTFail("Expected stable capture to pause before commit")
        }

        switch revocation {
        case .execution:
            _ = executionFence.advance()
        case .identity:
            identity.setDistinctId("replacement-customer")
        }
        store.resumeStableCaptureBeforeCommit(id: effectId)
        let result = await dispatch.value
        let historyCoverageAfterCapture = try await store
            .historyCoverageStartingAt()
        await log.close()

        XCTAssertEqual(result, .failed)
        XCTAssertFalse(store.storedEvents.contains { $0.id == effectId })
        XCTAssertEqual(
            historyCoverageAfterCapture,
            historyCoverageBeforeCapture,
            "Expected fence rejection must not manufacture a history gap"
        )
    }

    func makeService(
        identity: MockIdentityService,
        events: MockEventLog,
        directory: URL,
        dateProvider: DateProviderProtocol = MockDateProvider(),
        featureAccess: @escaping DeviceLegService.FeatureAccessLookup = { _ in nil },
        storeEntitlements: @escaping DeviceLegService.StoreEntitlementLookup = { [] },
        dispatcher: (any DeviceLegDispatching)? = nil,
        presenter: (any DeviceLegPresenting)? = nil,
        pinnedReleaseAuthenticator: @escaping DeviceLegService.PinnedReleaseAuthenticator = {
            _, _ in throw DeviceLegJournalError.invalidState
        },
        journalBeforePersist: (@Sendable () throws -> Void)? = nil
    ) -> DeviceLegService {
        DeviceLegService(
            identity: identity,
            events: events,
            dateProvider: dateProvider,
            sleepProvider: MockSleepProvider(),
            journalDirectory: directory,
            featureAccess: featureAccess,
            storeEntitlements: storeEntitlements,
            dispatcher: dispatcher ?? DeviceLegEffectDispatcher(
                identity: identity,
                events: events
            ),
            presenter: presenter,
            pinnedReleaseAuthenticator: pinnedReleaseAuthenticator,
            timezones: SignedTimezoneBundle.installed!,
            currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!,
            journalBeforePersist: journalBeforePersist
        )
    }

    func removingDeliveredReleases(
        from snapshot: DeviceLegProfileCatalog.Snapshot
    ) -> DeviceLegProfileCatalog.Snapshot {
        .init(
            profile: .init(
                schemaVersion: snapshot.profile.schemaVersion,
                status: snapshot.profile.status,
                delivery: snapshot.profile.delivery,
                features: snapshot.profile.features,
                facts: snapshot.profile.facts,
                armedLegs: [],
                releases: []
            ),
            releasesByDigest: [:]
        )
    }

    func replacing(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        entry: DeviceLegEntryCondition? = nil,
        reentry: DeviceLeg.Reentry? = nil,
        entitlementGate: DeviceLeg.EntitlementGate? = nil,
        products: [ExperienceReleaseJSONValue]? = nil,
        inputs: DeviceLeg.Boundary? = nil,
        completionOutputs: [String: DeviceLeg.Boundary]? = nil,
        entryStepId: String? = nil,
        steps: [DeviceLeg.Step]? = nil,
        routes: [DeviceLeg.Route]? = nil,
        screens: [DeviceLeg.Screen]? = nil,
        factReferences: DeviceLegFactReferences? = nil,
        facts: DeviceLegFactTable? = nil,
        viewModelValues: [[String: ExperienceReleaseJSONValue]]? = nil,
        armContext: ArmedDeviceLeg.Context? = nil
    ) -> DeviceLegProfileCatalog.Snapshot {
        let originalArm = snapshot.profile.armedLegs[0]
        let originalRelease = snapshot.releasesByDigest[
            originalArm.reference.descriptorSha256
        ]!
        let originalDescriptor = originalRelease.descriptor
        let originalLeg = originalDescriptor.leg
        let nextEntry = entry ?? originalArm.entryCondition
        let nextLeg = DeviceLeg(
            schemaVersion: originalLeg.schemaVersion,
            id: originalLeg.id,
            entryCondition: nextEntry,
            entryStepId: entryStepId ?? originalLeg.entryStepId,
            steps: steps ?? originalLeg.steps,
            routes: routes ?? originalLeg.routes,
            screens: screens ?? originalLeg.screens,
            reentry: reentry ?? originalLeg.reentry,
            entitlementGate: entitlementGate ?? originalLeg.entitlementGate,
            facts: factReferences ?? originalLeg.facts,
            inputs: inputs ?? originalLeg.inputs,
            outputs: originalLeg.outputs,
            completionOutputs: completionOutputs ?? originalLeg.completionOutputs
        )
        let descriptor = DeviceLegReleaseDescriptor(
            schemaVersion: originalDescriptor.schemaVersion,
            identity: originalDescriptor.identity,
            metadata: originalDescriptor.metadata,
            presentation: originalDescriptor.presentation,
            leg: nextLeg,
            products: products ?? originalDescriptor.products,
            placements: originalDescriptor.placements,
            viewModelValues: viewModelValues ?? originalDescriptor.viewModelValues,
            screenBehaviors: originalDescriptor.screenBehaviors,
            render: originalDescriptor.render,
            requirements: originalDescriptor.requirements,
            provenance: originalDescriptor.provenance
        )
        let release = AuthenticatedDeviceLegRelease(
            authenticatedKeyID: originalRelease.authenticatedKeyID,
            exactDescriptorBytes: originalRelease.exactDescriptorBytes,
            descriptorSHA256: originalRelease.descriptorSHA256,
            descriptor: descriptor,
            publishedAtSeqToPromote: originalRelease.publishedAtSeqToPromote
        )
        var releases = snapshot.releasesByDigest
        releases[originalRelease.descriptorSHA256] = release
        let arm = ArmedDeviceLeg(
            reference: originalArm.reference,
            binding: originalArm.binding,
            entryCondition: nextEntry,
            context: armContext ?? originalArm.context
        )
        let profile = JourneyPlaneProfile(
            schemaVersion: snapshot.profile.schemaVersion,
            status: snapshot.profile.status,
            delivery: snapshot.profile.delivery,
            features: snapshot.profile.features,
            facts: facts ?? snapshot.profile.facts,
            armedLegs: [arm],
            releases: snapshot.profile.releases
        )
        return .init(profile: profile, releasesByDigest: releases)
    }

    func replacingRenderedArtifact(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        sceneBytes: Data
    ) throws -> DeviceLegProfileCatalog.Snapshot {
        let originalArm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let originalRelease = try XCTUnwrap(snapshot.releasesByDigest[
            originalArm.reference.descriptorSha256
        ])
        let originalDescriptor = originalRelease.descriptor
        var render = try XCTUnwrap(originalDescriptor.render)
        let sceneSHA256 = SHA256Provider.hexDigest(sceneBytes)
        render["riv"] = .object([
            "contentType": .string("application/vnd.rive"),
            "key": .string("renders/sha256/\(sceneSHA256).riv"),
            "sha256": .string(sceneSHA256),
            "sizeBytes": .number(Double(sceneBytes.count)),
        ])
        render["assets"] = .array([])
        let descriptor = DeviceLegReleaseDescriptor(
            schemaVersion: originalDescriptor.schemaVersion,
            identity: originalDescriptor.identity,
            metadata: originalDescriptor.metadata,
            presentation: originalDescriptor.presentation,
            leg: originalDescriptor.leg,
            products: originalDescriptor.products,
            placements: originalDescriptor.placements,
            viewModelValues: originalDescriptor.viewModelValues,
            screenBehaviors: originalDescriptor.screenBehaviors,
            render: render,
            requirements: originalDescriptor.requirements,
            provenance: originalDescriptor.provenance
        )
        let exactDescriptorBytes = try JSONEncoder().encode(descriptor)
        let descriptorSHA256 = SHA256Provider.hexDigest(exactDescriptorBytes)
        let release = AuthenticatedDeviceLegRelease(
            authenticatedKeyID: originalRelease.authenticatedKeyID,
            exactDescriptorBytes: exactDescriptorBytes,
            descriptorSHA256: descriptorSHA256,
            descriptor: descriptor,
            publishedAtSeqToPromote: originalRelease.publishedAtSeqToPromote
        )
        let arm = ArmedDeviceLeg(
            reference: .init(
                experienceId: originalArm.reference.experienceId,
                versionId: originalArm.reference.versionId,
                legId: originalArm.reference.legId,
                descriptorSha256: descriptorSHA256
            ),
            binding: originalArm.binding,
            entryCondition: originalArm.entryCondition,
            context: originalArm.context
        )
        let profile = JourneyPlaneProfile(
            schemaVersion: snapshot.profile.schemaVersion,
            status: snapshot.profile.status,
            delivery: snapshot.profile.delivery,
            features: snapshot.profile.features,
            facts: snapshot.profile.facts,
            armedLegs: [arm],
            releases: snapshot.profile.releases
        )
        return .init(
            profile: profile,
            releasesByDigest: [descriptorSHA256: release]
        )
    }

    func replacingWithHeadlessArtifacts(
        _ snapshot: DeviceLegProfileCatalog.Snapshot
    ) throws -> DeviceLegProfileCatalog.Snapshot {
        let originalArm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let originalRelease = try XCTUnwrap(snapshot.releasesByDigest[
            originalArm.reference.descriptorSha256
        ])
        let originalDescriptor = originalRelease.descriptor
        let originalLeg = originalDescriptor.leg
        let leg = DeviceLeg(
            schemaVersion: originalLeg.schemaVersion,
            id: originalLeg.id,
            entryCondition: originalLeg.entryCondition,
            entryStepId: originalLeg.entryStepId,
            steps: originalLeg.steps,
            routes: originalLeg.routes,
            screens: [],
            reentry: originalLeg.reentry,
            entitlementGate: originalLeg.entitlementGate,
            facts: originalLeg.facts,
            inputs: originalLeg.inputs,
            outputs: originalLeg.outputs,
            completionOutputs: originalLeg.completionOutputs
        )
        let descriptor = DeviceLegReleaseDescriptor(
            schemaVersion: originalDescriptor.schemaVersion,
            identity: originalDescriptor.identity,
            metadata: originalDescriptor.metadata,
            presentation: originalDescriptor.presentation,
            leg: leg,
            products: originalDescriptor.products,
            placements: originalDescriptor.placements,
            viewModelValues: originalDescriptor.viewModelValues,
            screenBehaviors: [],
            render: nil,
            requirements: originalDescriptor.requirements,
            provenance: originalDescriptor.provenance
        )
        let exactDescriptorBytes = try JSONEncoder().encode(descriptor)
        let descriptorSHA256 = SHA256Provider.hexDigest(exactDescriptorBytes)
        let release = AuthenticatedDeviceLegRelease(
            authenticatedKeyID: originalRelease.authenticatedKeyID,
            exactDescriptorBytes: exactDescriptorBytes,
            descriptorSHA256: descriptorSHA256,
            descriptor: descriptor,
            publishedAtSeqToPromote: originalRelease.publishedAtSeqToPromote
        )
        let arm = ArmedDeviceLeg(
            reference: .init(
                experienceId: originalArm.reference.experienceId,
                versionId: originalArm.reference.versionId,
                legId: originalArm.reference.legId,
                descriptorSha256: descriptorSHA256
            ),
            binding: originalArm.binding,
            entryCondition: originalArm.entryCondition,
            context: originalArm.context
        )
        let profile = JourneyPlaneProfile(
            schemaVersion: snapshot.profile.schemaVersion,
            status: snapshot.profile.status,
            delivery: snapshot.profile.delivery,
            features: snapshot.profile.features,
            facts: snapshot.profile.facts,
            armedLegs: [arm],
            releases: snapshot.profile.releases
        )
        return .init(
            profile: profile,
            releasesByDigest: [descriptorSHA256: release]
        )
    }

    func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func waitForPresentationActions(
        _ expectedCount: Int,
        presenter: RecordingDeviceLegPresenter
    ) async {
        for _ in 0..<100 {
            let count = await MainActor.run {
                presenter.presentationActions.count
            }
            if count >= expectedCount { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func removeTemporaryDirectoryIfPresent(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

final class DeviceLegArtifactRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

enum DeviceLegCommitRevocation {
    case execution
    case identity
}

actor InspectingDeviceLegDispatcher: DeviceLegDispatching {
    private let directory: URL
    private let distinctId: String
    private var requests: [DeviceLegDispatchRequest] = []
    private var durableClaim = false

    init(directory: URL, distinctId: String) {
        self.directory = directory
        self.distinctId = distinctId
    }

    func dispatch(
        _ request: DeviceLegDispatchRequest
    ) async -> DeviceLegDispatchResult {
        requests.append(request)
        if let journal = try? DeviceLegRunJournal(
            directory: directory,
            distinctId: distinctId
        ), let run = try? await journal.runs().first(where: {
            $0.id == request.runId
        }) {
            durableClaim = run.park == nil
                && run.effectReceipts[request.stepId] == request.effectId
        }
        return .outlet("next")
    }

    func onlyRequest() -> DeviceLegDispatchRequest? {
        requests.count == 1 ? requests[0] : nil
    }

    func observedDurableClaim() -> Bool { durableClaim }
}

actor CaptureOnlyDeviceLegEvents: RoutedStableSystemEventCapturing {
    private var routed: [NuxieEvent] = []

    func captureSystemEvent(
        _ event: String,
        properties: sending [String: Any]?,
        eventId: String,
        distinctId: String
    ) async -> DurableTriggerCapture? {
        DurableTriggerCapture(event: NuxieEvent(
            id: eventId,
            name: event,
            distinctId: distinctId,
            properties: properties ?? [:]
        ))
    }

    func captureAndRouteSystemEvent(
        _ request: StableSystemEventCaptureRequest
    ) async -> DurableTriggerCapture? {
        let capture = DurableTriggerCapture(event: NuxieEvent(
            id: request.eventId,
            name: request.name,
            distinctId: request.distinctId,
            properties: request.properties ?? [:]
        ))
        routed.append(capture.event)
        return capture
    }

    func captureAndRouteSystemEvent(
        _ request: StableSystemEventCaptureRequest,
        admission: any StableEventCaptureCommitAdmission
    ) async -> DurableTriggerCapture? {
        let capture = DurableTriggerCapture(event: NuxieEvent(
            id: request.eventId,
            name: request.name,
            distinctId: request.distinctId,
            properties: request.properties ?? [:]
        ))
        let admitted = admission.commitIfCurrent {
            routed.append(capture.event)
            return StableEventCaptureCommit(
                outcome: .dropped,
                commitSequence: nil
            )
        }
        return admitted == nil ? nil : capture
    }

    func captureAndRouteSystemEventBatch(
        _ items: [RoutedStableSystemEventBatchItem],
        admission: any StableEventCaptureBatchCommitAdmission
    ) async -> [String: DurableTriggerCapture]? {
        let events = items.map { item in
            NuxieEvent(
                id: item.request.eventId,
                name: item.request.name,
                distinctId: item.request.distinctId,
                properties: item.request.properties ?? [:],
                timestamp: item.occurredAt
            )
        }
        let admitted = admission.commitBatchIfCurrent {
            routed.append(contentsOf: events)
            return []
        }
        guard admitted != nil else { return nil }
        return Dictionary(uniqueKeysWithValues: events.map {
            ($0.id, DurableTriggerCapture(event: $0))
        })
    }

    func routedNames() -> [String] {
        routed.map(\.name)
    }
}

actor SuspendedDeviceLegDispatcher: DeviceLegDispatching {
    private let underlying: any DeviceLegDispatching
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(underlying: any DeviceLegDispatching) {
        self.underlying = underlying
    }

    func dispatch(
        _ request: DeviceLegDispatchRequest
    ) async -> DeviceLegDispatchResult {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }
        return await underlying.dispatch(request)
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

actor DeviceLegEmissionBatchRecorder {
    private var batches: [ScreenEmissionBatch] = []

    func accept(_ batch: ScreenEmissionBatch) -> Bool {
        batches.append(batch)
        return true
    }

    func invocationIds() -> [String] {
        batches.map(\.invocationId)
    }
}

@MainActor
final class DeviceLegAppActionRecorder {
    private var actions: [AppAction] = []

    func record(_ action: AppAction) {
        actions.append(action)
    }

    func onlyAction() -> AppAction? {
        actions.count == 1 ? actions[0] : nil
    }
}

actor SequencedFeatureAccess {
    private var values: [Bool]
    private var count = 0

    init(_ values: [Bool]) {
        self.values = values
    }

    func next() -> FeatureAccess? {
        count += 1
        guard !values.isEmpty else { return nil }
        return FeatureAccess(
            allowed: values.removeFirst(),
            unlimited: true,
            balance: nil,
            type: .boolean
        )
    }

    func readCount() -> Int { count }
}

actor PinnedReleaseAuthenticationRecorder {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int { value }
}

actor DeviceLegScreenCommitGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

actor DeviceLegOutcomeCallRecorder {
    private var values: [(DeviceLegSurfaceOutcome, String?)] = []

    func record(outcome: DeviceLegSurfaceOutcome, screenId: String?) {
        values.append((outcome, screenId))
    }

    func count() -> Int {
        values.count
    }

    func onlyCall() -> (
        outcome: DeviceLegSurfaceOutcome,
        screenId: String?
    )? {
        guard values.count == 1 else { return nil }
        return values[0]
    }
}

actor DeviceLegRevealRecorder {
    private var value = 0

    func record() {
        value += 1
    }

    func count() -> Int { value }
}

actor DeviceLegResponsePersistenceProbe {
    private var values: [String?] = []

    func record(_ value: String?) {
        values.append(value)
    }

    func observations() -> [String?] {
        values
    }
}

@MainActor
final class RecordingDeviceLegPresenter {
    fileprivate final class Reservation: @unchecked Sendable {
        private weak var owner: RecordingDeviceLegPresenter?
        private var released = false

        init(owner: RecordingDeviceLegPresenter) {
            self.owner = owner
        }

        @MainActor
        func release() {
            guard !released else { return }
            released = true
            owner?.releaseReservation()
        }
    }

    var available = true {
        didSet { refreshAvailability() }
    }
    var result = DeviceLegPresentationResult.shown
    var automaticallyRevealsShownPresentation = true
    var navigationResult = DeviceLegPresentationNavigationResult.navigated
    var actionResult = DeviceLegPresentationActionResult.handled
    var resolvedPurchasePlacementId: String?
    var presentHandler:
        ((DeviceLegPresentationRequest) async -> DeviceLegPresentationResult)?
    private(set) var request: DeviceLegPresentationRequest?
    private(set) var presentationRequests: [DeviceLegPresentationRequest] = []
    private(set) var navigationScreenIds: [String] = []
    private(set) var resolvedActionSources: [ScreenEmissionSource?] = []
    private(set) var presentationActions: [(
        journeyId: String,
        ownerDistinctId: String,
        action: [String: ExperienceReleaseJSONValue],
        effectId: String
    )] = []
    private(set) var finishedOwners: [(journeyId: String, ownerDistinctId: String)] = []
    private(set) var shutdownOwners: [String] = []
    var onFinish: (() -> Void)?
    var onNavigate: ((String) -> Void)?
    private var activeOwner: DeviceLegPresentationOwner?
    private var reservationPending = false
    private var availabilityWasOpen = true
    private var availabilityHandler: (@MainActor @Sendable () -> Void)?

    func deviceLegProfileRefreshDidComplete() {}

    func setDeviceLegPresentationAvailabilityHandler(
        _ handler: (@MainActor @Sendable () -> Void)?
    ) {
        availabilityHandler = handler
        availabilityWasOpen = capacityIsOpen
    }

    func reserveDeviceLegPresentation(
        ownerDistinctId: String
    ) -> (any DeviceLegPresentationReservation)? {
        _ = ownerDistinctId
        guard capacityIsOpen else { return nil }
        reservationPending = true
        refreshAvailability()
        return Reservation(owner: self)
    }

    func ownsDeviceLegPresentation(
        owner: DeviceLegPresentationOwner
    ) -> Bool {
        activeOwner == owner
    }

    func presentDeviceLeg(
        _ request: DeviceLegPresentationRequest
    ) async -> DeviceLegPresentationResult {
        self.request = request
        presentationRequests.append(request)
        let resolvedResult = if let presentHandler {
            await presentHandler(request)
        } else {
            result
        }
        if resolvedResult == .shown {
            activeOwner = request.owner
            if automaticallyRevealsShownPresentation {
                await request.onPresentationRevealed()
            }
        }
        return resolvedResult
    }

    func navigateDeviceLegPresentation(
        owner: DeviceLegPresentationOwner,
        screenId: String,
        transition: ExperienceReleaseJSONValue?
    ) async -> DeviceLegPresentationNavigationResult {
        _ = transition
        navigationScreenIds.append(screenId)
        onNavigate?(screenId)
        guard let activeOwner else {
            return .noPresentation
        }
        guard activeOwner == owner else {
            return .declined
        }
        return navigationResult
    }

    func resolveDeviceLegPresentationAction(
        owner: DeviceLegPresentationOwner,
        action: [String: ExperienceReleaseJSONValue],
        source: ScreenEmissionSource?
    ) -> [String: ExperienceReleaseJSONValue]? {
        resolvedActionSources.append(source)
        guard activeOwner == owner else {
            return nil
        }
        guard case .string("purchase")? = action["type"] else {
            return action
        }
        guard let placementId = resolvedPurchasePlacementId
                ?? deviceLegPresentationLiteralString(action["placementId"])
        else { return action }
        var resolved = action
        resolved["placementId"] = .string(placementId)
        return resolved
    }

    func dispatchDeviceLegPresentationAction(
        owner: DeviceLegPresentationOwner,
        action: [String: ExperienceReleaseJSONValue],
        effectId: String
    ) async -> DeviceLegPresentationActionResult {
        presentationActions.append((
            journeyId: owner.journeyId,
            ownerDistinctId: owner.distinctId,
            action: action,
            effectId: effectId
        ))
        guard let activeOwner else {
            return .noPresentation
        }
        guard activeOwner == owner else {
            return .declined
        }
        return actionResult
    }

    func finishDeviceLegPresentation(
        owner: DeviceLegPresentationOwner
    ) async {
        finishedOwners.append((owner.journeyId, owner.distinctId))
        onFinish?()
        guard activeOwner == owner else { return }
        activeOwner = nil
        refreshAvailability()
    }

    func shutdownDeviceLegPresentation(ownerDistinctId: String) async {
        shutdownOwners.append(ownerDistinctId)
        if activeOwner?.distinctId == ownerDistinctId {
            activeOwner = nil
            refreshAvailability()
        }
    }

    func dropPresentationOwnershipForRelaunch() {
        activeOwner = nil
        reservationPending = false
        availabilityWasOpen = capacityIsOpen
    }

    private var capacityIsOpen: Bool {
        available && !reservationPending && activeOwner == nil
    }

    private func releaseReservation() {
        reservationPending = false
        availabilityWasOpen = capacityIsOpen
    }

    private func refreshAvailability() {
        let isOpen = capacityIsOpen
        guard isOpen != availabilityWasOpen else { return }
        availabilityWasOpen = isOpen
        if isOpen {
            availabilityHandler?()
        }
    }
}

extension RecordingDeviceLegPresenter: DeviceLegPresenting {}
extension RecordingDeviceLegPresenter.Reservation:
    DeviceLegPresentationReservation {}

import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

final class DeviceLegServiceTests: XCTestCase {
    func testCanonicalForegroundArmCompletesOnceAcrossProfileRevalidation() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            reentry: .init(type: .everyTime, windowSeconds: nil)
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let now = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1_000))
        let service = DeviceLegService(
            identity: identity,
            events: events,
            dateProvider: now,
            sleepProvider: MockSleepProvider(),
            journalDirectory: directory,
            featureAccess: { _ in nil },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed),
            currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyLegStarted
                    || $0 == JourneyEvents.journeyLegCompleted
            },
            [JourneyEvents.journeyLegStarted, JourneyEvents.journeyLegCompleted]
        )
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
        let mark = try await journal.checkmark(experienceId: "experience_golden")
        XCTAssertEqual(mark?.outcome, "continue")
    }

    func testProfileArmedInBackgroundStartsWhenForegroundLatchOpens() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = try await authenticatedSnapshot(fixture)
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = DeviceLegService(
            identity: identity,
            events: events,
            dateProvider: MockDateProvider(),
            sleepProvider: MockSleepProvider(),
            journalDirectory: directory,
            featureAccess: { _ in nil },
            timezones: try XCTUnwrap(SignedTimezoneBundle.installed),
            currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!
        )

        await service.initialize()
        await service.onAppDidEnterBackground()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        XCTAssertTrue(events.routedEvents.isEmpty)

        await service.onAppWillEnterForeground()
        XCTAssertTrue(events.routedEvents.isEmpty)

        await service.onAppBecameActive()

        XCTAssertEqual(
            events.routedEvents.map(\.name).filter {
                $0 == JourneyEvents.journeyLegStarted
                    || $0 == JourneyEvents.journeyLegCompleted
            },
            [JourneyEvents.journeyLegStarted, JourneyEvents.journeyLegCompleted]
        )
    }

    func testEventArmsAreEdgesAndProjectOnlyDeclaredEventFields() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let eventField: [String: ExperienceReleaseJSONValue] = [
            "key": .string("sku"),
            "type": .string("string"),
            "required": .bool(true),
        ]
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .event,
                eventName: "purchase_intent",
                segmentId: nil,
                member: nil,
                condition: nil
            ),
            reentry: .init(type: .everyTime, windowSeconds: nil),
            inputs: .init(eventFields: [eventField], responseFields: []),
            completionOutputs: [
                "continue": .init(
                    eventFields: [eventField],
                    responseFields: []
                )
            ]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")
        await service.handleEvent(NuxieEvent(
            name: "unrelated",
            distinctId: "customer"
        ))
        XCTAssertTrue(events.routedEvents.isEmpty)

        await service.handleEvent(NuxieEvent(
            id: "00000000-0000-7000-8000-000000000101",
            name: "purchase_intent",
            distinctId: "customer",
            properties: ["sku": "pro", "ignored": "extra"],
            timestamp: Date(timeIntervalSince1970: 1_001)
        ))
        await service.handleEvent(NuxieEvent(
            id: "00000000-0000-7000-8000-000000000102",
            name: "purchase_intent",
            distinctId: "customer",
            properties: ["sku": "team"],
            timestamp: Date(timeIntervalSince1970: 1_002)
        ))

        let lifecycle = events.routedEvents.filter {
            $0.name == JourneyEvents.journeyLegStarted
                || $0.name == JourneyEvents.journeyLegCompleted
        }
        XCTAssertEqual(lifecycle.map(\.name), [
            JourneyEvents.journeyLegStarted,
            JourneyEvents.journeyLegCompleted,
            JourneyEvents.journeyLegStarted,
            JourneyEvents.journeyLegCompleted,
        ])
        let completionOutputs = try lifecycle
            .filter { $0.name == JourneyEvents.journeyLegCompleted }
            .map { event -> [String: Any] in
                try XCTUnwrap(event.properties["outputs"] as? [String: Any])
            }
        XCTAssertEqual(
            completionOutputs.compactMap {
                ($0["event"] as? [String: String])?["sku"]
            },
            ["pro", "team"]
        )
        XCTAssertTrue(completionOutputs.allSatisfy {
            ($0["event"] as? [String: Any])?["ignored"] == nil
        })
    }

    func testStartRechecksEntryConditionAfterSuspendingGates() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let condition = IREnvelope(
            ir_version: 1,
            engine_min: nil,
            compiled_at: nil,
            expr: .feature(op: "has", id: "entry", value: nil)
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entry: .init(
                type: .appForegrounded,
                eventName: nil,
                segmentId: nil,
                member: nil,
                condition: condition
            )
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let access = SequencedFeatureAccess([true, false])
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            featureAccess: { featureId in
                guard featureId == "entry" else { return nil }
                return await access.next()
            }
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertTrue(events.routedEvents.isEmpty)
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let runs = try await journal.runs()
        XCTAssertTrue(runs.isEmpty)
        let accessCount = await access.readCount()
        XCTAssertEqual(accessCount, 2)
    }

    func testEntitlementGateSuppressesAProductWhoseFullGrantIsPresent() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entitlementGate: .init(enabled: true, products: [
                .init(productId: "pro", featureIds: ["premium"])
            ])
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            featureAccess: { featureId in
                guard featureId == "premium" else { return nil }
                return FeatureAccess(
                    allowed: true,
                    unlimited: true,
                    balance: nil,
                    type: .boolean
                )
            }
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        XCTAssertTrue(events.routedEvents.isEmpty)
    }

    func testProfileClearAbandonsAParkedRun() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let delay = DeviceLeg.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(60_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [delay, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let now = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1_000))
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: now
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let parked = try await journal.runs()
        XCTAssertEqual(parked.count, 1)
        XCTAssertNotNil(parked.first?.park)
        XCTAssertEqual(events.routedEvents.map(\.name), [
            JourneyEvents.journeyLegStarted,
        ])

        await service.profileDidClear(distinctId: "customer")

        let remaining = try await journal.runs()
        XCTAssertTrue(remaining.isEmpty)
        let completion = try XCTUnwrap(events.routedEvents.last)
        XCTAssertEqual(completion.name, JourneyEvents.journeyLegCompleted)
        XCTAssertEqual(completion.properties["outcome"] as? String, "abandoned")
    }

    func testNewUserProfileRetiresTheOldJournalBeforeQueuedTransitionWork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let delay = DeviceLeg.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(60_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [delay, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer-a")
        let events = MockEventLog()
        events.identity = identity
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: MockDateProvider(
                initialDate: Date(timeIntervalSince1970: 1_000)
            )
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer-a")
        await service.onAppDidEnterBackground()
        let oldJournal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-a"
        )
        let parkedOldRuns = try await oldJournal.runs()
        XCTAssertEqual(parkedOldRuns.count, 1)

        identity.setDistinctId("customer-b")
        await service.profileDidCommit(snapshot, distinctId: "customer-b")

        let oldRuns = try await oldJournal.runs()
        XCTAssertTrue(oldRuns.isEmpty)
        let oldCompletion = try XCTUnwrap(events.routedEvents.first {
            $0.distinctId == "customer-a"
                && $0.name == JourneyEvents.journeyLegCompleted
        })
        XCTAssertEqual(
            oldCompletion.properties["outcome"] as? String,
            "abandoned"
        )
        let newJournal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer-b"
        )
        let newRuns = try await newJournal.runs()
        XCTAssertTrue(newRuns.isEmpty)

        await service.handleUserChange(
            from: "customer-a",
            to: "customer-b"
        )
        let oldRunsAfterTransition = try await oldJournal.runs()
        XCTAssertTrue(oldRunsAfterTransition.isEmpty)
    }

    func testRecoveryResumesOnlyThePersistedDueParkPoint() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try DeviceLegPlaneProfileTestFixture.load()
        let delay = DeviceLeg.Step(
            kind: .action,
            id: "wait",
            action: [
                "type": .string("delay"),
                "durationMs": .number(1_000),
            ],
            outlets: ["next": "report"],
            outcome: nil
        )
        let complete = DeviceLeg.Step(
            kind: .complete,
            id: "report",
            action: nil,
            outlets: nil,
            outcome: "continue"
        )
        let snapshot = replacing(
            try await authenticatedSnapshot(fixture),
            entryStepId: "wait",
            steps: [delay, complete]
        )
        let identity = MockIdentityService()
        identity.setDistinctId("customer")
        let events = MockEventLog()
        events.identity = identity
        let now = MockDateProvider(initialDate: Date(timeIntervalSince1970: 1_002))
        let journal = try DeviceLegRunJournal(
            directory: directory,
            distinctId: "customer"
        )
        let arm = try XCTUnwrap(snapshot.profile.armedLegs.first)
        let admitted = try await journal.admit(
            arm: arm,
            reentry: .init(type: .oneTime, windowSeconds: nil),
            entryStepId: "wait",
            at: Date(timeIntervalSince1970: 1_000)
        )
        let run = try XCTUnwrap(admitted)
        try await DeviceLegReporter(journal: journal, events: events)
            .flushPending()
        try await journal.transition(
            run.id,
            stepId: "wait",
            context: run.context,
            checkpoint: .init(
                anchorAtMillis: 1_000_000,
                wakeAtMillis: 1_001_000
            )
        )
        let service = makeService(
            identity: identity,
            events: events,
            directory: directory,
            dateProvider: now
        )

        await service.initialize()
        await service.profileDidCommit(snapshot, distinctId: "customer")

        let remaining = try await journal.runs()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(events.routedEvents.map(\.name).filter {
            $0 == JourneyEvents.journeyLegStarted
                || $0 == JourneyEvents.journeyLegCompleted
        }, [JourneyEvents.journeyLegStarted, JourneyEvents.journeyLegCompleted])
    }

    private func authenticatedSnapshot(
        _ fixture: DeviceLegPlaneProfileTestFixture
    ) async throws -> DeviceLegProfileCatalog.Snapshot {
        let catalog = DeviceLegProfileCatalog(
            authorizationKeys: [ExperiencePackageAuthorizationKey(
                keyID: "TEST_ONLY_DEV_KEYPAIR",
                ed25519PublicKeyBytes: fixture.publicKey
            )],
            supportedRuntime: ExperienceReleaseRuntime.current,
            highWaterStore: InMemoryExperienceReleaseHighWaterStore()
        )
        let prepared = try await catalog.prepare(fixture.profile)
        _ = try await catalog.commit(prepared, distinctId: "customer")
        let snapshot = await catalog.snapshot(distinctId: "customer")
        return try XCTUnwrap(snapshot)
    }

    private func makeService(
        identity: MockIdentityService,
        events: MockEventLog,
        directory: URL,
        dateProvider: DateProviderProtocol = MockDateProvider(),
        featureAccess: @escaping DeviceLegService.FeatureAccessLookup = { _ in nil }
    ) -> DeviceLegService {
        DeviceLegService(
            identity: identity,
            events: events,
            dateProvider: dateProvider,
            sleepProvider: MockSleepProvider(),
            journalDirectory: directory,
            featureAccess: featureAccess,
            timezones: SignedTimezoneBundle.installed!,
            currentDeviceTimezone: TimeZone(secondsFromGMT: 0)!
        )
    }

    private func replacing(
        _ snapshot: DeviceLegProfileCatalog.Snapshot,
        entry: DeviceLegEntryCondition? = nil,
        reentry: DeviceLeg.Reentry? = nil,
        entitlementGate: DeviceLeg.EntitlementGate? = nil,
        inputs: DeviceLeg.Boundary? = nil,
        completionOutputs: [String: DeviceLeg.Boundary]? = nil,
        entryStepId: String? = nil,
        steps: [DeviceLeg.Step]? = nil
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
            routes: originalLeg.routes,
            screens: originalLeg.screens,
            reentry: reentry ?? originalLeg.reentry,
            entitlementGate: entitlementGate ?? originalLeg.entitlementGate,
            facts: originalLeg.facts,
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
            products: originalDescriptor.products,
            placements: originalDescriptor.placements,
            viewModelValues: originalDescriptor.viewModelValues,
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
        return .init(profile: profile, releasesByDigest: releases)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private actor SequencedFeatureAccess {
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

import Foundation
@_spi(Testing) @testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// Errors thrown by the orchestration harness itself (never by the SDK).
enum OrchestrationHarnessError: Error, CustomStringConvertible {
    case timedOut(String)

    var description: String {
        switch self {
        case .timedOut(let what): return "OrchestrationHarness timed out: \(what)"
        }
    }
}

/// One booted "app process" for the Orchestration suite (cleanup plan P6).
///
/// Unlike the unit suites, this harness runs the REAL composition root
/// (`NuxieCore`) over REAL stores in a caller-owned temp directory: real
/// `EventLog` (SQLite), real `JourneyStore` (files), real `JourneyService`
/// actor, real Profile/Segment/Feature/Trigger services, real
/// `IdentityService`. Only three seams are replaced:
///
///   - transport: `MockNuxieApi`
///   - time:      `MockDateProvider` + `MockSleepProvider`
///   - the UI edge: `MockExperienceService` (flow-artifact delivery — the
///     production implementation downloads riv bundles over plain URLSession,
///     outside the mocked transport) and `MockExperiencePresentationService`
///     (window presentation — the test host has no scenes)
///
/// Multiple stacks can be booted sequentially over the SAME storage directory
/// to model process kill + relaunch. `kill()` drops the event log's SQLite
/// handle — the harness stand-in for the OS reclaiming file descriptors — and
/// deliberately performs NO graceful teardown: no journey shutdown, no
/// background snapshot, no event flush.
final class OrchestrationStack {
    let config: NuxieConfiguration
    let core: NuxieCore
    let storageURL: URL
    let api: MockNuxieApi
    let dateProvider: MockDateProvider
    let sleepProvider: MockSleepProvider
    let experienceService: MockExperienceService
    let presentation: MockExperiencePresentationService

    private init(
        config: NuxieConfiguration,
        core: NuxieCore,
        storageURL: URL,
        api: MockNuxieApi,
        dateProvider: MockDateProvider,
        sleepProvider: MockSleepProvider,
        experienceService: MockExperienceService,
        presentation: MockExperiencePresentationService
    ) {
        self.config = config
        self.core = core
        self.storageURL = storageURL
        self.api = api
        self.dateProvider = dateProvider
        self.sleepProvider = sleepProvider
        self.experienceService = experienceService
        self.presentation = presentation
    }

    // MARK: - Boot / kill

    /// Build and wire a full stack over `storageURL`. Mirrors
    /// `NuxieSDK.setup` exactly where it matters: the composition root is
    /// `NuxieCore(configuration:overrides:)`, and the committed-event
    /// subscriptions (segments before journeys) are registered BEFORE
    /// `EventLog.configure` so the routers observe every committed event —
    /// including events captured before configure finished.
    static func boot(
        storageURL: URL,
        api: MockNuxieApi,
        dateProvider: MockDateProvider,
        sleepProvider: MockSleepProvider,
        distinctId: String,
        initialFeatureAccess: [String: FeatureAccess] = [:],
        forwardingHandler: ForwardingEventHandler? = nil,
        productService: ProductService? = nil,
        preRegisteredExperiences: [(Experience, JourneyDocument)] = [],
        configure: ((NuxieConfiguration) -> Void)? = nil
    ) async throws -> OrchestrationStack {
        try FileManager.default.createDirectory(
            at: storageURL, withIntermediateDirectories: true
        )

        let config = NuxieConfiguration(apiKey: "orchestration-suite-key")
        config.testingOverrides.customStoragePath = storageURL
        config.testingOverrides.flushAt = 10_000  // delivery is manual-flush only
        config.testingOverrides.flushInterval = 3600
        config.testingOverrides.retryCount = 1
        config.testingOverrides.retryDelay = 0.01
        configure?(config)

        var overrides = NuxieCoreOverrides()
        overrides.api = api
        overrides.dateProvider = dateProvider
        overrides.sleepProvider = sleepProvider
        let experienceService = MockExperienceService()
        overrides.experiences = experienceService
        let presentation = MockExperiencePresentationService()
        overrides.experiencePresentation = presentation
        if let productService {
            overrides.productService = productService
        }

        // Flow bundles available BEFORE journeys.initialize() runs — a real
        // launch reads riv artifacts from the disk cache, so an
        // expired-while-dead timer restored during initialize can rebuild its
        // runner immediately. The mocked artifact edge has no disk cache;
        // pre-registration models that cache.
        for (metadata, journey) in preRegisteredExperiences {
            experienceService.mockExperiences[metadata.versionId] = Experience(
                metadata: metadata,
                journey: journey,
                assetBaseURL: metadata.assetBaseURL
            )
        }

        let core = NuxieCore(configuration: config, overrides: overrides)
        if !initialFeatureAccess.isEmpty {
            await MainActor.run {
                core.featureInfo.admitProfileSnapshot(
                    initialFeatureAccess,
                    admittedAt: dateProvider.now()
                )
            }
        }
        presentation.eventLog = core.eventLog

        // Identity is real and disk-backed: on a relaunch boot this is a
        // same-id no-op because IdentityService restored it from
        // <storage>/nuxie/identity.json — exactly like a real process launch.
        core.identity.setDistinctId(distinctId)

        // Mirror NuxieSDK.setup's event wiring. Segment membership is a
        // server-owned profile mirror, so committed events route only
        // to journeys.
        let journeys = core.journeys
        await core.eventLog.subscribeCommitted { [weak journeys] event in
            await journeys?.handleEvent(event)
        }
        if let forwardingHandler {
            await core.eventLog.subscribeForwarding(handler: forwardingHandler)
        }
        try await core.eventLog.configure(configuration: core.configuration)
        await journeys.initialize()
        await core.featureUseCommands.recover()

        return OrchestrationStack(
            config: config,
            core: core,
            storageURL: storageURL,
            api: api,
            dateProvider: dateProvider,
            sleepProvider: sleepProvider,
            experienceService: experienceService,
            presentation: presentation
        )
    }

    /// Simulate a process kill: the OS reclaims the SQLite file handle but
    /// nothing else runs — no journey shutdown, no background snapshot, no
    /// flush. (Closing the log releases the db connection so the next
    /// "process" doesn't contend with this one's, which a real kill never
    /// causes. `close()` does not deliver pending events.)
    func kill() async {
        await core.eventLog.close()
    }

    /// Post-test cleanup only — never part of a scenario. Drains queued
    /// identity transitions, stops journey timers, closes storage.
    func shutdownForCleanup() async {
        await core.userTransitions.drain()
        await core.journeys.shutdown()
        await core.featureUseCommands.close()
        await core.eventLog.close()
    }

    // MARK: - Convenience accessors

    var distinctId: String { core.identity.getDistinctId() }
    var eventLog: EventLogProtocol { core.eventLog }
    var journeys: JourneyServiceProtocol { core.journeys }

    /// A FRESH JourneyStore over the same directory — reads what is actually
    /// persisted on disk, not what the live service holds in memory.
    func journeyStoreOnDisk() -> JourneyStore {
        JourneyStore(customStoragePath: storageURL, dateProvider: dateProvider)
    }

    // MARK: - Profile / experience installation

    /// Serve experience metadata and journeys from the mocked transport and force a
    /// profile fetch, exactly like a fresh online launch would.
    func installProfile(experiences: [Experience], journeys: [JourneyDocument]) async throws {
        registerExperiences(journeys, metadata: experiences)
        let references = experiences.map {
            ExperienceReference(experienceId: $0.id, versionId: $0.versionId)
        }
        experienceService.authenticatedReleaseReferences = references
        await api.setProfileResponse(ProfileResponse(
            segments: [],
            releases: Self.releaseProfile(for: references),
            userProperties: nil,
            experiments: nil,
            features: nil
        ))
        _ = try await core.profile.refetchProfile(distinctId: distinctId)
    }

    private static func releaseProfile(
        for references: [ExperienceReference]
    ) -> ExperienceReleaseProfile {
        let digest = String(repeating: "a", count: 64)
        let envelope = try! ExperienceReleaseDescriptorEnvelope(
            mediaType: ExperienceReleaseDescriptorLimits.mediaType,
            encoding: "base64",
            descriptorSha256: digest,
            descriptorSizeBytes: 2,
            descriptorBytesBase64: "e30=",
            signature: .init(
                version: 1,
                algorithm: "ed25519",
                keyId: "test",
                signatureBase64: "signature"
            )
        ).canonicalBytes()
        return ExperienceReleaseProfile(
            delivery: .init(
                renderBaseUrl: "https://cdn.nuxie.test/renders/",
                assetBaseUrl: "https://cdn.nuxie.test/assets/"
            ),
            active: references.enumerated().map { index, reference in
                ExperienceReleaseProfileEntry(
                    locator: .init(
                        appId: "orchestration-app",
                        environment: "test",
                        experienceId: reference.experienceId,
                        experienceVersionId: reference.versionId,
                        buildId: "build-\(index)",
                        versionNumber: index + 1,
                        publishedAt: "2026-08-13T00:00:00Z",
                        publishedAtSeq: index + 1
                    ),
                    descriptorSha256: digest,
                    envelopeBytes: envelope
                )
            },
            pinned: []
        )
    }

    /// Register journeys with the mocked package edge. The mock has no
    /// disk cache, so relaunch-offline sessions re-register them.
    func registerExperiences(
        _ experiences: [JourneyDocument],
        metadata: [Experience]
    ) {
        for (experience, journey) in zip(metadata, experiences) {
            experienceService.mockExperiences[experience.versionId] = Experience(
                metadata: experience,
                journey: journey,
                assetBaseURL: experience.assetBaseURL
            )
        }
    }

    /// Bounded poll until ProfileService's disk-cache load makes the cached
    /// profile visible. Relaunch-offline sessions have no network fetch to
    /// await — the disk load runs as a detached task inside ProfileService.
    func waitForCachedProfile(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await core.profile.getCachedProfile(distinctId: distinctId) != nil {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw OrchestrationHarnessError.timedOut("cached profile for \(distinctId)")
    }

    // MARK: - Event dispatch

    /// Durable-pipeline dispatch: capture → enrich → persist pending →
    /// committed routing (segments, then journeys). Returns after both
    /// event-log workers drained, i.e. after journey routing for this event
    /// completed.
    func trackAndDrain(_ name: String, properties: [String: Any]? = nil) async {
        core.eventLog.track(
            name, properties: properties, userProperties: nil, userPropertiesSetOnce: nil
        )
        await core.eventLog.drain()
    }

    /// Production trigger path (`NuxieSDK.trigger` minus the facade):
    /// synchronous /i/event round trip + journey routing. Updates are
    /// collected for assertion.
    @discardableResult
    func trigger(_ event: String, properties: [String: Any]? = nil) async -> TriggerUpdateBox {
        let box = TriggerUpdateBox()
        await core.triggers.trigger(
            event,
            properties: properties
        ) { update in
            box.append(update)
        }
        return box
    }

    /// Production-shaped identify: set the id, then run the serialized
    /// user-transition fan-out to completion. Cancels the previous user's
    /// live journeys (`$journey_exited` with exit_reason "cancelled").
    func switchUser(to newDistinctId: String) async {
        let old = core.identity.getDistinctId()
        core.identity.setDistinctId(newDistinctId)
        core.userTransitions.enqueue(
            UserTransitionCoordinator.Transition(
                kind: .identify,
                from: old,
                to: newDistinctId,
                migrateEvents: false
            ))
        await core.userTransitions.drain()
    }

    // MARK: - Store queries (assertion helpers)

    /// All locally persisted event names, oldest volume well below the limit
    /// in this suite. Reads the REAL SQLite store.
    func storedEventNames(limit: Int = 500) async -> [String] {
        await core.eventLog.getRecentEvents(limit: limit).map(\.name)
    }

    func eventCount(_ name: String) async -> Int {
        await storedEventNames().filter { $0 == name }.count
    }

    func storedEvents(named name: String) async -> [StoredEvent] {
        await core.eventLog.getRecentEvents(limit: 500).filter { $0.name == name }
    }

    /// `$journey_enrolled` count for one experience — the enrollment ledger.
    func journeyStartCount(experienceId: String) async -> Int {
        await storedEvents(named: "$journey_enrolled").filter {
            (try? $0.getProperties())?["experience_id"]?.value as? String == experienceId
        }.count
    }

    /// Terminal reason of the most recent `$journey_exited`.
    func lastJourneyExitReason() async -> String? {
        guard let event = await storedEvents(named: "$journey_exited").last else {
            return nil
        }
        return (try? event.getProperties())?["reason"]?.value as? String
    }
}

// MARK: - Trigger update collection

/// Lock-guarded collector for `trigger(...)` progressive updates. Handlers
/// run on service executors, so shared state must be lock-protected.
final class TriggerUpdateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _updates: [TriggerUpdate] = []

    func append(_ update: TriggerUpdate) {
        lock.lock()
        _updates.append(update)
        lock.unlock()
    }

    var updates: [TriggerUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return _updates
    }

    var decisions: [TriggerDecision] {
        updates.compactMap {
            if case .decision(let decision) = $0 { return decision }
            return nil
        }
    }

    var startedExperienceIds: [String] {
        decisions.compactMap {
            if case .journeyStarted(let ref) = $0 { return ref.experienceId }
            return nil
        }
    }

    var suppressReasons: [SuppressReason] {
        decisions.compactMap {
            if case .suppressed(let reason) = $0 { return reason }
            return nil
        }
    }

    var errors: [TriggerError] {
        updates.compactMap {
            if case .error(let error) = $0 { return error }
            return nil
        }
    }
}

// MARK: - Wire-format fixtures

/// Experience/flow fixtures decoded through the production Codable path (same
/// wire shapes as `fixtures/journeys/golden-journeys.json`), so the suite
/// exercises exactly what the server would deliver.
enum OrchestrationFixtures {

    static func experience(
        id: String,
        flowId: String,
        eventName: String,
        reentry: ExperienceReentry
    ) -> Experience {
        Experience(
            id: id,
            versionId: flowId,
            name: "Orchestration \(id)",
            reentry: reentry,
            publishedAt: "2026-01-01T00:00:00Z",
            trigger: .event(EventTriggerConfig(eventName: eventName, condition: nil)),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil
        )
    }

    /// Entry handler: track `effect`, then exit — the journey completes on
    /// the same dispatch that enrolled it.
    static func exitFlow(id: String, trigger: String, effect: String) throws -> JourneyDocument {
        try flow(id: id, trigger: trigger, actionsJSON: """
            [
              { "type": "send_event", "eventName": "\(effect)" },
              { "type": "exit" }
            ]
            """)
    }

    /// Entry handler: delay, then track `effect`, then exit — the journey
    /// pauses with a persisted resumable `pendingAction`.
    static func delayFlow(
        id: String, trigger: String, delayMs: Int, effect: String
    ) throws -> JourneyDocument {
        try flow(id: id, trigger: trigger, actionsJSON: """
            [
              { "type": "delay", "durationMs": \(delayMs) },
              { "type": "send_event", "eventName": "\(effect)" },
              { "type": "exit" }
            ]
            """)
    }

    /// Entry handler: purchase with a wired onCompleted outlet chain
    /// (track `effect`, then exit).
    static func purchaseFlow(
        id: String, trigger: String, placementId: String, effect: String
    ) throws -> JourneyDocument {
        try flow(id: id, trigger: trigger, actionsJSON: """
            [
              {
                "type": "purchase",
                "placementId": "\(placementId)",
                "onCompleted": [
                  { "type": "send_event", "eventName": "\(effect)" },
                  { "type": "exit" }
                ]
              }
            ]
            """)
    }

    private static func flow(
        id: String, trigger: String, actionsJSON: String
    ) throws -> JourneyDocument {
        let json = """
            {
              "schemaVersion": 1,
              "screens": [ { "id": "screen-1" } ],
              "events": {
                "__journey__": [
                  {
                    "id": "event-\(id)-\(trigger)",
                    "eventName": "\(trigger)"
                  }
                ]
              },
              "scripts": {},
              "handlers": {
                "__journey__": [
                  {
                    "id": "h-entry-\(id)",
                    "eventName": "\(trigger)",
                    "actions": \(actionsJSON)
                  }
                ]
              }
            }
            """
        return try JSONDecoder().decode(JourneyDocument.self, from: Data(json.utf8))
    }
}

import Foundation
@testable import Nuxie
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
    let flowService: MockExperienceService
    let presentation: MockExperiencePresentationService

    private init(
        config: NuxieConfiguration,
        core: NuxieCore,
        storageURL: URL,
        api: MockNuxieApi,
        dateProvider: MockDateProvider,
        sleepProvider: MockSleepProvider,
        flowService: MockExperienceService,
        presentation: MockExperiencePresentationService
    ) {
        self.config = config
        self.core = core
        self.storageURL = storageURL
        self.api = api
        self.dateProvider = dateProvider
        self.sleepProvider = sleepProvider
        self.flowService = flowService
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
        productService: ProductService? = nil,
        preRegisteredExperiences: [RemoteFlow] = [],
        configure: ((NuxieConfiguration) -> Void)? = nil
    ) async throws -> OrchestrationStack {
        try FileManager.default.createDirectory(
            at: storageURL, withIntermediateDirectories: true
        )

        let config = NuxieConfiguration(apiKey: "orchestration-suite-key")
        config.customStoragePath = storageURL
        config.flushAt = 10_000  // delivery is manual-flush only
        config.flushInterval = 3600
        config.retryCount = 1
        config.retryDelay = 0.01
        configure?(config)

        var overrides = NuxieCoreOverrides()
        overrides.api = api
        overrides.dateProvider = dateProvider
        overrides.sleepProvider = sleepProvider
        let flowService = MockExperienceService()
        overrides.flows = flowService
        let presentation = MockExperiencePresentationService()
        overrides.flowPresentation = presentation
        if let productService {
            overrides.productService = productService
        }

        // Flow bundles available BEFORE journeys.initialize() runs — a real
        // launch reads riv artifacts from the disk cache, so an
        // expired-while-dead timer restored during initialize can rebuild its
        // runner immediately. The mocked artifact edge has no disk cache;
        // pre-registration models that cache.
        for flow in preRegisteredExperiences {
            flowService.mockExperiences[flow.id] = Experience(screens: flow)
        }

        let core = NuxieCore(configuration: config, overrides: overrides)
        presentation.eventLog = core.eventLog

        // Identity is real and disk-backed: on a relaunch boot this is a
        // same-id no-op because IdentityService restored it from
        // <storage>/nuxie/identity.json — exactly like a real process launch.
        core.identity.setDistinctId(distinctId)

        // Mirror NuxieSDK.setup's event wiring. Segment membership is a
        // server-owned profile mirror in E1, so committed events route only
        // to journeys.
        let journeys = core.journeys
        await core.eventLog.subscribeCommitted { [weak journeys] event in
            await journeys?.handleEvent(event)
        }
        try await core.eventLog.configure(configuration: config)
        await journeys.initialize()

        return OrchestrationStack(
            config: config,
            core: core,
            storageURL: storageURL,
            api: api,
            dateProvider: dateProvider,
            sleepProvider: sleepProvider,
            flowService: flowService,
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

    /// Serve `campaigns` + `flows` from the mocked transport and force a
    /// profile fetch, exactly like a fresh online launch would.
    func installProfile(campaigns: [Campaign], flows: [RemoteFlow]) async throws {
        registerExperiences(flows)
        await api.setProfileResponse(ProfileResponse(
            campaigns: campaigns,
            segments: [],
            flows: flows,
            userProperties: nil,
            experiments: nil,
            features: nil
        ))
        _ = try await core.profile.refetchProfile(distinctId: distinctId)
    }

    /// Register flow bundles with the mocked artifact edge. The mock has no
    /// disk cache (production caches riv artifacts on disk), so
    /// relaunch-offline sessions re-register the same bundles.
    func registerExperiences(_ flows: [RemoteFlow]) {
        for flow in flows {
            flowService.mockExperiences[flow.id] = Experience(screens: flow)
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
            properties: properties,
            userProperties: nil,
            userPropertiesSetOnce: nil
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

    /// `$journey_enrolled` count for one campaign — the enrollment ledger.
    func journeyStartCount(campaignId: String) async -> Int {
        await storedEvents(named: "$journey_enrolled").filter {
            (try? $0.getProperties())?["experience_id"]?.value as? String == campaignId
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

    var startedCampaignIds: [String] {
        decisions.compactMap {
            if case .journeyStarted(let ref) = $0 { return ref.campaignId }
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

/// Campaign/flow fixtures decoded through the production Codable path (same
/// wire shapes as `fixtures/journeys/golden-journeys.json`), so the suite
/// exercises exactly what the server would deliver.
enum OrchestrationFixtures {

    static func campaign(
        id: String,
        flowId: String,
        eventName: String,
        reentry: CampaignReentry
    ) -> Campaign {
        Campaign(
            id: id,
            name: "Orchestration \(id)",
            flowId: flowId,
            flowNumber: 1,
            flowName: nil,
            reentry: reentry,
            publishedAt: "2026-01-01T00:00:00Z",
            trigger: .event(EventTriggerConfig(eventName: eventName, condition: nil)),
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            campaignType: nil
        )
    }

    /// Entry handler: track `effect`, then exit — the journey completes on
    /// the same dispatch that enrolled it.
    static func exitFlow(id: String, trigger: String, effect: String) throws -> RemoteFlow {
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
    ) throws -> RemoteFlow {
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
        id: String, trigger: String, productId: String, effect: String
    ) throws -> RemoteFlow {
        try flow(id: id, trigger: trigger, actionsJSON: """
            [
              {
                "type": "purchase",
                "placementIndex": 0,
                "productId": "\(productId)",
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
    ) throws -> RemoteFlow {
        let json = """
            {
              "id": "\(id)",
              "flowArtifact": {
                "url": "https://example.com/builds/\(id)",
                "buildId": "build-\(id)",
                "manifest": {
                  "totalFiles": 0,
                  "totalSize": 0,
                  "contentHash": "hash-\(id)",
                  "files": []
                }
              },
              "screens": [ { "id": "screen-1" } ],
              "events": {},
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
        return try JSONDecoder().decode(RemoteFlow.self, from: Data(json.utf8))
    }
}

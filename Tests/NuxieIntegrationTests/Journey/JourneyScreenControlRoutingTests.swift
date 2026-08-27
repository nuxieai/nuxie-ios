import Foundation
import CryptoKit
import Nimble
import Quick
@_spi(Testing) @testable import Nuxie
@testable import NuxieTestSupport

private final class RoutingClaimFailingJourneyStore: MockJourneyStore, @unchecked Sendable {
    private let failureLock = NSLock()
    private var failNextRoutingClaim = false

    func failNextAuthoredRoutingClaim() {
        failureLock.lock()
        failNextRoutingClaim = true
        failureLock.unlock()
    }

    public override func saveJourney(_ journey: JourneySnapshot) throws {
        failureLock.lock()
        let shouldFail = failNextRoutingClaim
            && journey.executionState.screenRouting.eventRecords.values.contains { record in
                record.pendingAuthoredEvents.contains { $0.phase == .routingClaimed }
            }
        if shouldFail {
            failNextRoutingClaim = false
        }
        failureLock.unlock()
        if shouldFail {
            throw NSError(
                domain: "RoutingClaimFailingJourneyStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Injected routing-claim save failure"]
            )
        }
        try super.saveJourney(journey)
    }
}

private struct ScreenEmissionRuntimeFixture: Decodable {
    struct Run: Decodable {
        let screenId: String

        enum CodingKeys: String, CodingKey {
            case screenId = "screen_id"
        }
    }

    struct Input: Decodable {
        let actionId: String
        let componentId: String
        let instanceId: String
        let value: String

        enum CodingKeys: String, CodingKey {
            case actionId = "action_id"
            case componentId = "component_id"
            case instanceId = "instance_id"
            case value
        }
    }

    struct Effect: Decodable {
        let kind: String
        let field: String?
        let value: String?
        let name: String?
        let payload: [String: String]?
    }

    struct Expected: Decodable {
        let batchSequence: UInt64
        let emissionSequences: [UInt64]
        let emissionIds: [String]
        let customerEventIds: [String]
        let responseValues: [String: String]
        let pendingBatchCountAfterDrain: Int
        let replayCustomerEventCount: Int
        let replayResponseVersionIncrement: UInt64

        enum CodingKeys: String, CodingKey {
            case batchSequence = "batch_sequence"
            case emissionSequences = "emission_sequences"
            case emissionIds = "emission_ids"
            case customerEventIds = "customer_event_ids"
            case responseValues = "response_values"
            case pendingBatchCountAfterDrain = "pending_batch_count_after_drain"
            case replayCustomerEventCount = "replay_customer_event_count"
            case replayResponseVersionIncrement = "replay_response_version_increment"
        }
    }

    let run: Run
    let input: Input
    let effects: [Effect]
    let expected: Expected
}

private final class ScreenEmissionFixtureIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String]

    init(_ values: [String]) {
        self.values = values
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}

final class JourneyScreenControlRoutingTests: AsyncSpec {
    override class func spec() {
        nonisolated(unsafe) var mocks: MockFactory!
        nonisolated(unsafe) var store: MockJourneyStore!
        nonisolated(unsafe) var service: JourneyService!
        nonisolated(unsafe) var controller: MockExperienceViewController!
        nonisolated(unsafe) var featureInfo: FeatureInfo!
        nonisolated(unsafe) var featureService: FeatureService!
        nonisolated(unsafe) var definitionsByJourneyId: [String: ExperienceDefinition] = [:]

        let distinctId = "screen-control-user"
        let experienceId = "screen-control-experience"
        let versionId = "screen-control-version"

        func definition(eventName: String) -> ExperienceDefinition {
            ExperienceDefinition(
                entryRouteEventName: "paywall_trigger",
                screens: [JourneyScreen(
                    id: "screen-1",
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )],
                viewModelValues: [],
                routes: [:],
                executionPlans: [],
                responseSchema: nil,
                controlsByScreen: [
                    "screen-1": [
                        "submit": ScreenControlActionDefinition(
                            actionId: "submit",
                            binding: .declarative([
                                .emit(eventName: eventName, payload: [
                                    "answer": .invocationValue,
                                    "component": .componentId,
                                    "instance": .instanceId,
                                ])
                            ])
                        )
                    ]
                ]
            )
        }

        func responseDefinition() -> ExperienceDefinition {
            ExperienceDefinition(
                entryRouteEventName: "paywall_trigger",
                screens: [JourneyScreen(
                    id: "screen-1",
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )],
                viewModelValues: [],
                routes: [:],
                executionPlans: [],
                responseSchema: PinnedResponseSessionSchema(
                    key: "survey",
                    versionId: "survey-v1",
                    version: 1,
                    fields: [ResponseSessionField(
                        key: "answer",
                        type: .text,
                        required: true,
                        options: nil,
                        minimum: nil,
                        maximum: nil
                    )],
                    capturesByScreen: ["screen-1": ["answer"]]
                ),
                controlsByScreen: [
                    "screen-1": [
                        "answer": ScreenControlActionDefinition(
                            actionId: "answer",
                            binding: .declarative([
                                .responseSet(field: "answer", value: .invocationValue)
                            ])
                        )
                    ]
                ]
            )
        }

        func loadScreenEmissionRuntimeFixture() throws -> ScreenEmissionRuntimeFixture {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let url = repositoryRoot
                .appendingPathComponent("fixtures/journeys/screen-emission-runtime")
                .appendingPathComponent("input-effect-persistence-replay.json")
            return try JSONDecoder().decode(
                ScreenEmissionRuntimeFixture.self,
                from: Data(contentsOf: url)
            )
        }

        func signedExperience(
            definition: ExperienceDefinition,
            goal: GoalConfig? = nil,
            exitPolicy: ExitPolicy? = nil
        ) -> Experience {
            let identity = ExperienceReleaseIdentity(
                appId: "test-app",
                environment: "test",
                experienceId: experienceId,
                experienceVersionId: versionId,
                buildId: "signed-build",
                versionNumber: 1,
                publishedAt: "2026-08-13T00:00:00.000Z",
                publishedAtSeq: 1
            )
            return Experience(
                behavior: ExperienceBehaviorDefinition(
                    reference: .init(experienceId: experienceId, versionId: versionId),
                    buildId: identity.buildId,
                    artifactContentHash: String(repeating: "a", count: 64),
                    name: "Signed screen controls",
                    reentry: .everyTime,
                    publishedAt: identity.publishedAt,
                    trigger: .event(.init(eventName: "paywall_trigger", condition: nil)),
                    goal: goal,
                    exitPolicy: exitPolicy,
                    conversionAnchor: nil,
                    timeLimitSeconds: nil,
                    experienceType: nil,
                    presentationStyle: .fullScreen
                ),
                journey: definition.renderShell,
                definition: definition,
                assetBaseURL: URL(string: "https://assets.nuxie.ai/")!,
                authenticatedReleaseID: .init(
                    identity: identity,
                    descriptorSHA256: String(repeating: "b", count: 64)
                )
            )
        }

        func renamedRouteDefinition() -> ExperienceDefinition {
            let routeKey = JourneyRouteKey(
                host: .screen("screen-1"),
                eventName: "renamed_submit"
            )
            let nestedRouteKey = JourneyRouteKey(
                host: .screen("screen-1"),
                eventName: "renamed_route_ran"
            )
            let revision = String(repeating: "c", count: 64)
            let nestedRevision = String(repeating: "8", count: 64)
            let route = JourneyRoute(
                key: routeKey,
                revisionSHA256: revision,
                program: [.object([
                    "type": .string("condition"),
                    "branches": .array([]),
                    "defaultProgram": .array([.object([
                        "type": .string("send_event"),
                        "eventName": .string("renamed_route_ran"),
                        "payload": .object([:]),
                    ])]),
                ])]
            )
            let cursor = JourneyExecutionCursor(
                programPath: "/program",
                actionIndex: 0
            )
            let region = JourneyExecutionRegion(
                id: "device",
                plane: .device,
                entryCursor: cursor,
                actionPaths: ["/program/0", "/program/0/defaultProgram/0"]
            )
            let nestedRoute = JourneyRoute(
                key: nestedRouteKey,
                revisionSHA256: nestedRevision,
                program: [.object([
                    "type": .string("send_event"),
                    "eventName": .string("nested_route_ran"),
                    "payload": .object([:]),
                ])]
            )
            let nestedRegion = JourneyExecutionRegion(
                id: "nested-device",
                plane: .device,
                entryCursor: cursor,
                actionPaths: ["/program/0"]
            )
            return ExperienceDefinition(
                entryRouteEventName: "paywall_trigger",
                screens: [JourneyScreen(
                    id: "screen-1",
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )],
                viewModelValues: [],
                routes: [routeKey: route, nestedRouteKey: nestedRoute],
                executionPlans: [
                    JourneyExecutionPlan(
                        id: "renamed-route-plan",
                        route: routeKey,
                        revisionSHA256: revision,
                        startPlane: .device,
                        entryRegionId: region.id,
                        entryCursor: cursor,
                        deviceRegions: [region],
                        serverRegions: [],
                        handoffEdges: []
                    ),
                    JourneyExecutionPlan(
                        id: "nested-route-plan",
                        route: nestedRouteKey,
                        revisionSHA256: nestedRevision,
                        startPlane: .device,
                        entryRegionId: nestedRegion.id,
                        entryCursor: cursor,
                        deviceRegions: [nestedRegion],
                        serverRegions: [],
                        handoffEdges: []
                    ),
                ],
                responseSchema: nil,
                controlsByScreen: [
                    "screen-1": [
                        "submit": ScreenControlActionDefinition(
                            actionId: "submit",
                            binding: .declarative([
                                .emit(eventName: "original_submit", payload: [:])
                            ])
                        )
                    ]
                ]
            )
        }

        func pausedRouteDefinition() -> ExperienceDefinition {
            let eventName = "pause_route"
            let routeKey = JourneyRouteKey(
                host: .screen("screen-1"),
                eventName: eventName
            )
            let revision = String(repeating: "e", count: 64)
            let route = JourneyRoute(
                key: routeKey,
                revisionSHA256: revision,
                program: [
                    .object([
                        "type": .string("delay"),
                        "durationMs": .number(60_000),
                    ]),
                    .object([
                        "type": .string("send_event"),
                        "eventName": .string("after_delay"),
                        "payload": .object([:]),
                    ]),
                ]
            )
            let cursor = JourneyExecutionCursor(programPath: "/program", actionIndex: 0)
            let region = JourneyExecutionRegion(
                id: "paused-device",
                plane: .device,
                entryCursor: cursor,
                actionPaths: ["/program/0", "/program/1"]
            )
            return ExperienceDefinition(
                entryRouteEventName: "paywall_trigger",
                screens: [JourneyScreen(
                    id: "screen-1",
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )],
                viewModelValues: [],
                routes: [routeKey: route],
                executionPlans: [JourneyExecutionPlan(
                    id: "paused-route-plan",
                    route: routeKey,
                    revisionSHA256: revision,
                    startPlane: .device,
                    entryRegionId: region.id,
                    entryCursor: cursor,
                    deviceRegions: [region],
                    serverRegions: [],
                    handoffEdges: []
                )],
                responseSchema: nil,
                controlsByScreen: [
                    "screen-1": [
                        "submit": ScreenControlActionDefinition(
                            actionId: "submit",
                            binding: .declarative([
                                .emit(eventName: eventName, payload: [:])
                            ])
                        )
                    ]
                ]
            )
        }

        func replayRecoveryDefinition() -> ExperienceDefinition {
            let routeKey = JourneyRouteKey(
                host: .screen("screen-1"),
                eventName: "replay_source"
            )
            let revision = String(repeating: "f", count: 64)
            let route = JourneyRoute(
                key: routeKey,
                revisionSHA256: revision,
                program: [.object([
                    "type": .string("send_event"),
                    "eventName": .string("replay_child"),
                    "payload": .object([:]),
                ])]
            )
            let cursor = JourneyExecutionCursor(programPath: "/program", actionIndex: 0)
            let region = JourneyExecutionRegion(
                id: "replay-device",
                plane: .device,
                entryCursor: cursor,
                actionPaths: ["/program/0"]
            )
            return ExperienceDefinition(
                entryRouteEventName: "paywall_trigger",
                screens: [JourneyScreen(
                    id: "screen-1",
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )],
                viewModelValues: [],
                routes: [routeKey: route],
                executionPlans: [JourneyExecutionPlan(
                    id: "replay-route-plan",
                    route: routeKey,
                    revisionSHA256: revision,
                    startPlane: .device,
                    entryRegionId: region.id,
                    entryCursor: cursor,
                    deviceRegions: [region],
                    serverRegions: [],
                    handoffEdges: []
                )],
                responseSchema: nil,
                controlsByScreen: [:]
            )
        }

        func backReplayDefinition() -> ExperienceDefinition {
            let routeKey = JourneyRouteKey(
                host: .screen("screen-1"),
                eventName: "go_back"
            )
            let revision = String(repeating: "9", count: 64)
            let route = JourneyRoute(
                key: routeKey,
                revisionSHA256: revision,
                program: [.object([
                    "type": .string("back"),
                    "steps": .number(1),
                ])]
            )
            let cursor = JourneyExecutionCursor(programPath: "/program", actionIndex: 0)
            let region = JourneyExecutionRegion(
                id: "back-device",
                plane: .device,
                entryCursor: cursor,
                actionPaths: ["/program/0"]
            )
            return ExperienceDefinition(
                entryRouteEventName: "paywall_trigger",
                screens: [JourneyScreen(
                    id: "screen-1",
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )],
                viewModelValues: [],
                routes: [routeKey: route],
                executionPlans: [JourneyExecutionPlan(
                    id: "back-route-plan",
                    route: routeKey,
                    revisionSHA256: revision,
                    startPlane: .device,
                    entryRegionId: region.id,
                    entryCursor: cursor,
                    deviceRegions: [region],
                    serverRegions: [],
                    handoffEdges: []
                )],
                responseSchema: nil,
                controlsByScreen: [:]
            )
        }

        func journeyEntryEventDefinition(eventName: String) -> ExperienceDefinition {
            let routeKey = JourneyRouteKey(host: .journey, eventName: "paywall_trigger")
            let revision = String(repeating: "d", count: 64)
            let route = JourneyRoute(
                key: routeKey,
                revisionSHA256: revision,
                program: [.object([
                    "type": .string("send_event"),
                    "eventName": .string(eventName),
                    "payload": .object([:]),
                ])]
            )
            let cursor = JourneyExecutionCursor(programPath: "/program", actionIndex: 0)
            let region = JourneyExecutionRegion(
                id: "entry-device",
                plane: .device,
                entryCursor: cursor,
                actionPaths: ["/program/0"]
            )
            return ExperienceDefinition(
                entryRouteEventName: "paywall_trigger",
                screens: [],
                viewModelValues: [],
                routes: [routeKey: route],
                executionPlans: [JourneyExecutionPlan(
                    id: "entry-plan",
                    route: routeKey,
                    revisionSHA256: revision,
                    startPlane: .device,
                    entryRegionId: region.id,
                    entryCursor: cursor,
                    deviceRegions: [region],
                    serverRegions: [],
                    handoffEdges: []
                )],
                responseSchema: nil,
                controlsByScreen: [:]
            )
        }

        func gatePlanResponse(flowId: String) -> EventResponse {
            EventResponse(
                status: "ok",
                payload: ["gate": AnyCodable([
                    "decision": "show_flow",
                    "flowId": flowId,
                ])]
            )
        }

        func featureGatePlanResponse(
            featureId: String,
            requiredBalance: Double,
            flowId: String
        ) -> EventResponse {
            EventResponse(
                status: "ok",
                payload: ["gate": AnyCodable([
                    "decision": "require_feature",
                    "featureId": featureId,
                    "requiredBalance": requiredBalance,
                    "flowId": flowId,
                    "policy": "hard",
                ])]
            )
        }

        func install(_ experience: Experience) async {
            mocks.identityService.setDistinctId(distinctId)
            let reference = ExperienceReference(
                experienceId: experience.id,
                versionId: experience.versionId
            )
            mocks.profileService.effectiveExperienceReferences = [reference]
            mocks.profileService.activeExperienceReferences = [reference]
            mocks.experienceService.mockExperiences[experience.versionId] = experience
            mocks.profileService.setProfileResponse(
                ResponseBuilders.buildProfileResponse(experiences: [experience])
            )
            _ = try? await mocks.profileService.refetchProfile(distinctId: distinctId)
        }

        func start(_ experience: Experience) async -> Journey? {
            await install(experience)
            await service.initialize()
            let journey = await service.startJourney(for: experience, distinctId: distinctId)
            if let journey, let definition = experience.definition {
                definitionsByJourneyId[journey.id] = definition
                await service.handleRuntimeReady(journeyId: journey.id, controller: controller)
            }
            return journey
        }

        func emitRendererControlAction(
            journeyId: String,
            screenId: String?,
            invocation: ScreenActionInvocation
        ) async {
            guard let scope = await service.screenControlRunScope(journeyId: journeyId),
                  scope.screenId == screenId else { return }
            await emitRendererControlAction(
                journeyId: journeyId,
                scope: scope,
                invocation: invocation
            )
        }

        func emitRendererControlAction(
            journeyId: String,
            scope: ScreenControlRunScope?,
            invocation: ScreenActionInvocation
        ) async {
            guard let scope,
                  let definition = definitionsByJourneyId[journeyId],
                  let action = definition.control(
                    screenId: scope.screenId,
                    actionId: invocation.actionId
                  ) else { return }
            let dispatcher = ScreenEmissionDispatcher(
                createId: { UUID.v7().uuidString },
                now: { Date().ISO8601Format() },
                executeScriptAction: { input in
                    throw ScreenEmissionDispatchError.scriptActionMissing(
                        actionId: input.actionId
                    )
                }
            )
            await dispatcher.restoreProgress(
                journeyId: journeyId,
                nextBatchSequence: scope.nextBatchSequence,
                nextEmissionSequence: scope.nextEmissionSequence
            )
            guard case .success(let batch) = await dispatcher.dispatch(
                run: ScreenEmissionRun(
                    journeyId: journeyId,
                    executionOwnershipEpoch: scope.executionOwnershipEpoch,
                    lifecycleGeneration: scope.lifecycleGeneration,
                    presentationEpoch: scope.presentationEpoch
                ),
                screenId: scope.screenId,
                definition: action,
                invocation: invocation
            ) else { return }
            if !(await service.handleRendererScreenEmissionBatch(batch)) {
                _ = await dispatcher.rollbackUnpublishedBatch(batch)
            }
        }

        func persistAuthoredEventRecoveryCut(
            journey: Journey,
            parentPhase: JourneyScreenEventPhase,
            authoredPhase: JourneyScreenAuthoredEventPhase
        ) async throws {
            let sourceId = "recovery-source-\(authoredPhase.rawValue)"
            let authoredId = "recovery-authored-\(authoredPhase.rawValue)"
            let occurredAt = Date()
            let source = ScreenCustomerEvent(
                id: sourceId,
                customerId: distinctId,
                occurredAt: occurredAt.ISO8601Format(),
                name: "source_event",
                payload: [:],
                source: .screen(
                    experienceId: experienceId,
                    journeyId: journey.id,
                    source: ScreenEmissionSource(
                        screenId: "screen-1",
                        actionId: "submit",
                        componentId: "submit-button",
                        instanceId: nil
                    )
                ),
                causality: ExperienceEventCausality(
                    chainId: journey.id,
                    parentEventId: nil,
                    visitedExperienceIds: [experienceId],
                    hopCount: 0
                )
            )
            let authored = JourneyScreenAuthoredEvent(
                id: authoredId,
                name: "renamed_submit",
                properties: [:],
                occurredAt: occurredAt,
                hostId: "screen-1",
                screenId: "screen-1",
                handlerId: nil,
                phase: authoredPhase,
                preparedId: authoredId,
                preparedName: "renamed_submit",
                preparedDistinctId: distinctId,
                preparedProperties: [:],
                preparedOccurredAt: occurredAt
            )
            var snapshot = await journey.snapshot()
            snapshot.executionState.screenRouting.eventRecords[sourceId] =
                JourneyScreenEventRecord(
                    sourceEvent: source,
                    preparedId: sourceId,
                    preparedName: source.name,
                    preparedDistinctId: distinctId,
                    preparedProperties: [:],
                    preparedOccurredAt: occurredAt,
                    localRoute: .none,
                    excludedExperienceId: experienceId,
                    phase: parentPhase,
                    routeContinuation: nil,
                    claimedEffectPaths: [],
                    pendingAuthoredEvents: [authored]
                )
            try store.saveJourney(snapshot)
        }

        func restartAndRecover(_ experience: Experience) async {
            await service.shutdown()
            service = mocks.makeJourneyService(journeyStore: store)
            mocks.experiencePresentationService.defaultMockViewController = controller
            await install(experience)
            await service.initialize()
            for journey in await service.getActiveJourneys(for: distinctId) {
                let committed = await service.handleWillActivateInitialScreen(
                    journeyId: journey.id,
                    controller: controller
                )
                if committed {
                    let screenId = (await journey.snapshot()).executionState.currentScreenId
                        ?? "screen-1"
                    _ = await service.handleWillDispatchInitialScreenLifecycle(
                        journeyId: journey.id,
                        controller: controller,
                        screenId: screenId
                    )
                    await service.handleRuntimeReady(
                        journeyId: journey.id,
                        controller: controller
                    )
                }
            }
        }

        func persistAuthoredIntentBeforeParentCursor(
            journey: Journey
        ) async throws {
            let admissionId = "cursor-cut-source"
            let revision = String(repeating: "f", count: 64)
            let routeIdentity = "route:\(revision)"
            let actionPath = "/program/0"
            let eventName = "replay_child"
            let material = [
                admissionId,
                routeIdentity,
                "screen-1",
                actionPath,
                eventName,
            ].joined(separator: "|")
            let authoredId = SHA256.hash(data: Data(material.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let occurredAt = Date()
            let source = ScreenCustomerEvent(
                id: admissionId,
                customerId: distinctId,
                occurredAt: occurredAt.ISO8601Format(),
                name: "replay_source",
                payload: [:],
                source: .screen(
                    experienceId: experienceId,
                    journeyId: journey.id,
                    source: ScreenEmissionSource(
                        screenId: "screen-1",
                        actionId: "submit",
                        componentId: nil,
                        instanceId: nil
                    )
                ),
                causality: ExperienceEventCausality(
                    chainId: journey.id,
                    parentEventId: nil,
                    visitedExperienceIds: [experienceId],
                    hopCount: 0
                )
            )
            let request = JourneyContinuationRequest(
                rootId: admissionId,
                isPriority: false,
                actions: [.sendEvent(SendEventAction(eventName: eventName))],
                actionPaths: [actionPath],
                hostId: "screen-1",
                screenId: "screen-1",
                componentId: nil,
                handlerId: routeIdentity,
                instanceId: nil,
                payload: ["__nuxie_emission_id": AnyCodable(admissionId)],
                requiresTerminalTransfer: false,
                startIndex: 0,
                usesPendingResumeContext: false,
                resume: nil,
                screenRouteAdmissionId: admissionId
            )
            let authored = JourneyScreenAuthoredEvent(
                id: authoredId,
                name: eventName,
                properties: [:],
                occurredAt: occurredAt,
                hostId: "screen-1",
                screenId: "screen-1",
                handlerId: routeIdentity,
                phase: .intent,
                preparedId: nil,
                preparedName: nil,
                preparedDistinctId: nil,
                preparedProperties: nil,
                preparedOccurredAt: nil
            )
            var snapshot = await journey.snapshot()
            snapshot.executionState.screenRouting.eventRecords[admissionId] =
                JourneyScreenEventRecord(
                    sourceEvent: source,
                    preparedId: admissionId,
                    preparedName: source.name,
                    preparedDistinctId: distinctId,
                    preparedProperties: [:],
                    preparedOccurredAt: occurredAt,
                    localRoute: .ready(AcceptedScreenLocalRoute(
                        admissionId: admissionId,
                        key: .screen(screenId: "screen-1", eventName: source.name),
                        routeRevision: revision
                    )),
                    excludedExperienceId: experienceId,
                    phase: .routeExecuting,
                    routeContinuation: [JourneyContinuationStep(
                        rootId: admissionId,
                        operation: .request(request)
                    )],
                    claimedEffectPaths: [],
                    pendingAuthoredEvents: [authored]
                )
            try store.saveJourney(snapshot)
        }

        beforeEach { @MainActor in
            mocks = MockFactory.shared
            mocks.dateProvider.setCurrentDate(Date())
            store = MockJourneyStore()
            featureInfo = FeatureInfo()
            featureService = FeatureService(
                api: mocks.nuxieApi,
                identity: mocks.identityService,
                profile: mocks.profileService,
                dateProvider: mocks.dateProvider,
                featureInfo: featureInfo,
                cacheTTL: NuxieInternalConfiguration().featureCacheTTL
            )
            service = mocks.makeJourneyService(
                journeyStore: store,
                features: featureService,
                featureInfo: featureInfo
            )
            controller = MockExperienceViewController(mockExperienceVersionId: versionId)
            mocks.experiencePresentationService.defaultMockViewController = controller
            definitionsByJourneyId = [:]
        }

        it("routes a generated control through its signed definition and journals the result") {
            let eventName = "survey_submitted"
            let experience = signedExperience(definition: definition(eventName: eventName))
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(
                    actionId: "submit",
                    value: .string("premium"),
                    componentId: "submit-button",
                    instanceId: "survey-1"
                )
            )

            let routed = mocks.eventLog.routedEvents.first { $0.name == eventName }
            expect(routed?.properties["answer"] as? String).to(equal("premium"))
            expect(routed?.properties["component"] as? String).to(equal("submit-button"))
            let routing = (await journey.snapshot()).executionState.screenRouting
            expect(routing.eventRecords[routed?.id ?? ""]).to(beNil())
            expect(routing.recentEventIds).to(contain(routed?.id ?? ""))
            expect(routing.batchReceipts["0"]?.result.status).to(equal(.drained))
            expect(routing.lastProcessedBatchSequence).to(equal(0))
            expect(routing.pendingBatches).to(beEmpty())
            let encoded = try JSONEncoder().encode(await journey.snapshot())
            expect(encoded).toNot(beEmpty())
        }

        it("runs the typed input-effect-persistence-replay fixture end to end") {
            let fixture = try loadScreenEmissionRuntimeFixture()
            guard let responseEffect = fixture.effects.first(where: { $0.kind == "response_set" }),
                  let eventEffect = fixture.effects.first(where: { $0.kind == "event" }),
                  let responseField = responseEffect.field,
                  let eventName = eventEffect.name else {
                fail("fixture must contain typed response_set and event effects")
                return
            }
            let definition = ExperienceDefinition(
                entryRouteEventName: "fixture_trigger",
                screens: [JourneyScreen(
                    id: fixture.run.screenId,
                    defaultViewModelName: nil,
                    defaultInstanceId: nil
                )],
                viewModelValues: [],
                routes: [:],
                executionPlans: [],
                responseSchema: PinnedResponseSessionSchema(
                    key: "fixture",
                    versionId: "fixture-v1",
                    version: 1,
                    fields: [ResponseSessionField(
                        key: responseField,
                        type: .text,
                        required: true,
                        options: nil,
                        minimum: nil,
                        maximum: nil
                    )],
                    capturesByScreen: [fixture.run.screenId: [responseField]]
                ),
                controlsByScreen: [
                    fixture.run.screenId: [
                        fixture.input.actionId: ScreenControlActionDefinition(
                            actionId: fixture.input.actionId,
                            binding: .declarative([
                                .responseSet(field: responseField, value: .invocationValue),
                                .emit(
                                    eventName: eventName,
                                    payload: ["answer": .invocationValue]
                                ),
                            ])
                        )
                    ]
                ]
            )
            let experience = signedExperience(definition: definition)
            guard let journey = await start(experience),
                  let scope = await service.screenControlRunScope(journeyId: journey.id) else {
                fail("expected signed fixture journey")
                return
            }
            let ids = ScreenEmissionFixtureIDSource(
                ["fixture-invocation"] + fixture.expected.emissionIds
            )
            let dispatcher = ScreenEmissionDispatcher(
                createId: { ids.next() },
                now: { "2026-08-27T12:00:00Z" },
                executeScriptAction: { _ in [] }
            )
            await dispatcher.restoreProgress(
                journeyId: journey.id,
                nextBatchSequence: scope.nextBatchSequence,
                nextEmissionSequence: scope.nextEmissionSequence
            )
            guard let action = definition.control(
                screenId: fixture.run.screenId,
                actionId: fixture.input.actionId
            ) else {
                fail("missing signed fixture action")
                return
            }
            let result = await dispatcher.dispatch(
                run: ScreenEmissionRun(
                    journeyId: journey.id,
                    executionOwnershipEpoch: scope.executionOwnershipEpoch,
                    lifecycleGeneration: scope.lifecycleGeneration,
                    presentationEpoch: scope.presentationEpoch
                ),
                screenId: fixture.run.screenId,
                definition: action,
                invocation: ScreenActionInvocation(
                    actionId: fixture.input.actionId,
                    value: .string(fixture.input.value),
                    componentId: fixture.input.componentId,
                    instanceId: fixture.input.instanceId
                )
            )
            let batch = try result.get()

            expect(batch.batchSequence).to(equal(fixture.expected.batchSequence))
            expect(batch.emissions.map(\.sequence)).to(equal(fixture.expected.emissionSequences))
            expect(batch.emissions.map(\.id)).to(equal(fixture.expected.emissionIds))
            let published = await service.handleRendererScreenEmissionBatch(batch)
            expect(published).to(beTrue())

            let persisted = await journey.snapshot()
            expect(persisted.executionState.screenRouting.pendingBatches.count)
                .to(equal(fixture.expected.pendingBatchCountAfterDrain))
            expect(persisted.responseSession?.values[responseField])
                .to(equal(.string(fixture.expected.responseValues[responseField] ?? "")))
            let event = mocks.eventLog.routedEvents.first { $0.name == eventName }
            expect(event?.id).to(equal(fixture.expected.customerEventIds.first))
            let responseVersion = persisted.responseSession?.version ?? 0

            await restartAndRecover(experience)
            let replayedBatch = await service.handleRendererScreenEmissionBatch(batch)
            expect(replayedBatch).to(beTrue())

            expect(mocks.eventLog.routedEvents.filter { $0.name == eventName }.count)
                .to(equal(fixture.expected.replayCustomerEventCount))
            let replayed = store.loadJourney(id: journey.id)
            expect(replayed?.responseSession?.version)
                .to(equal(responseVersion + fixture.expected.replayResponseVersionIncrement))
        }

        it("persists a declarative response emission in the pinned response session") {
            let experience = signedExperience(definition: responseDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(
                    actionId: "answer",
                    value: .string("premium"),
                    componentId: "answer-field",
                    instanceId: "survey-1"
                )
            )

            let snapshot = await journey.snapshot()
            expect(snapshot.responseSession?.state).to(equal(.draft))
            expect(snapshot.responseSession?.values["answer"]).to(equal(.string("premium")))
            let serverWrite = await mocks.nuxieApi.lastResponseFieldCall
            expect(serverWrite?.journeyId).to(equal(journey.id))
            expect(serverWrite?.responseSchemaId).to(equal("survey"))
            expect(serverWrite?.schemaVersion).to(equal(1))
            expect(serverWrite?.key).to(equal("answer"))
            expect(serverWrite?.value as? String).to(equal("premium"))
            expect(snapshot.executionState.screenRouting.batchReceipts["0"]?.result.status)
                .to(equal(.drained))
        }

        it("retains earlier failed response writes until every mutation synchronizes") {
            let experience = signedExperience(definition: responseDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            await mocks.nuxieApi.setResponseWriteError(NSError(
                domain: "ResponseWrite",
                code: 1
            ))

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(
                    actionId: "answer",
                    value: .string("first")
                )
            )

            var snapshot = await journey.snapshot()
            expect(snapshot.pendingResponseFieldWrites.count).to(equal(1))
            expect(snapshot.responseSessionRetryRequired).to(beTrue())
            await service.handleRuntimeDismiss(
                journeyId: journey.id,
                reason: .userDismissed,
                controller: controller
            )
            let activeJourneyIds = await service.getActiveJourneys(for: distinctId).map(\.id)
            expect(activeJourneyIds).to(contain(journey.id))

            await mocks.nuxieApi.setResponseWriteError(nil)
            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(
                    actionId: "answer",
                    value: .string("second")
                )
            )

            snapshot = await journey.snapshot()
            expect(snapshot.pendingResponseFieldWrites).to(beEmpty())
            expect(snapshot.responseSessionRetryRequired).to(beFalse())
            expect(snapshot.responseSession?.values["answer"]).to(equal(.string("second")))
            let values = await mocks.nuxieApi.responseFieldCalls.compactMap {
                $0.value as? String
            }
            expect(values).to(equal(["first", "first", "second"]))
        }

        it("completes a dismissal after an in-flight response write synchronizes") {
            let experience = signedExperience(definition: responseDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            await mocks.nuxieApi.setResponseWriteDelay(0.5)

            let write = Task {
                await emitRendererControlAction(
                    journeyId: journey.id,
                    screenId: "screen-1",
                    invocation: ScreenActionInvocation(
                        actionId: "answer",
                        value: .string("premium")
                    )
                )
            }
            for _ in 0..<100 {
                if await mocks.nuxieApi.lastResponseFieldCall != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let inFlightCall = await mocks.nuxieApi.lastResponseFieldCall
            expect(inFlightCall).toNot(beNil())

            await service.handleRuntimeDismiss(
                journeyId: journey.id,
                reason: .userDismissed,
                controller: controller
            )
            let activeDuringWrite = await service.getActiveJourneys(for: distinctId).map(\.id)
            expect(activeDuringWrite).to(contain(journey.id))

            await write.value

            let activeAfterWrite = await service.getActiveJourneys(for: distinctId).map(\.id)
            expect(activeAfterWrite).toNot(contain(journey.id))
        }

        it("compacts a generated event dropped by beforeSend after its batch commits") {
            let eventName = "survey_filtered"
            let experience = signedExperience(definition: definition(eventName: eventName))
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            mocks.eventLog.preparedTriggerBeforeSend = { event in
                event.name == eventName ? nil : event
            }

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(
                    actionId: "submit",
                    value: .string("filtered"),
                    componentId: "submit-button",
                    instanceId: "survey-1"
                )
            )

            let routing = (await journey.snapshot()).executionState.screenRouting
            expect(routing.eventRecords).to(beEmpty())
            expect(routing.recentEventIds).to(haveCount(1))
            expect(routing.pendingBatches).to(beEmpty())
            expect(routing.batchReceipts["0"]?.result.status).to(equal(.drained))
            expect(mocks.eventLog.routedEvents.map(\.name)).toNot(contain(eventName))
        }

        it("runs no signed route or authored effect when beforeSend drops the source") {
            let experience = signedExperience(definition: renamedRouteDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            mocks.eventLog.preparedTriggerBeforeSend = { event in
                event.name == "original_submit" ? nil : event
            }

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(actionId: "submit")
            )

            let routedNames = mocks.eventLog.routedEvents.map(\.name)
            expect(routedNames).toNot(contain("original_submit"))
            expect(routedNames).toNot(contain("renamed_route_ran"))
            expect(routedNames).toNot(contain("nested_route_ran"))
            let routing = (await journey.snapshot()).executionState.screenRouting
            expect(routing.pendingBatches).to(beEmpty())
            expect(routing.batchReceipts["0"]?.result.status).to(equal(.drained))
        }

        it("waits for the remounted renderer before replaying an admitted screen batch") {
            let experience = signedExperience(definition: replayRecoveryDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            var snapshot = await journey.snapshot()
            let batch = ScreenEmissionBatch(
                journeyId: journey.id,
                executionOwnershipEpoch: UInt64(max(snapshot.epoch, 0)),
                lifecycleGeneration: snapshot.executionState.lifecycleGeneration,
                presentationEpoch: snapshot.executionState.presentationEpoch,
                batchSequence: 0,
                previousCommittedBatchSequence: nil,
                invocationId: "restored-invocation",
                source: ScreenEmissionSource(
                    screenId: "screen-1",
                    actionId: "submit",
                    componentId: "submit-button",
                    instanceId: nil
                ),
                emissions: [ScreenEmission(
                    id: "restored-emission",
                    sequence: 0,
                    occurredAt: Date().ISO8601Format(),
                    name: "replay_source",
                    payload: [:]
                )]
            )
            snapshot.executionState.screenRouting.pendingBatches["0"] = batch
            snapshot.executionState.screenRouting.nextBatchSequence = 1
            snapshot.executionState.screenRouting.nextEmissionSequence = 1
            try store.saveJourney(snapshot)

            await service.shutdown()
            service = mocks.makeJourneyService(journeyStore: store)
            mocks.experiencePresentationService.defaultMockViewController = controller
            await install(experience)
            await service.initialize()

            expect(mocks.eventLog.routedEvents.map(\.name)).toNot(contain("replay_child"))
            expect(store.loadJourney(id: journey.id)?.executionState.screenRouting.pendingBatches)
                .to(haveCount(1))

            store.shouldThrowOnSave = true
            let rejectedCommit = await service.handleWillActivateInitialScreen(
                journeyId: journey.id,
                controller: controller
            )
            let rejectedRecovery = await service.handleWillDispatchInitialScreenLifecycle(
                journeyId: journey.id,
                controller: controller,
                screenId: "screen-1"
            )
            expect(rejectedCommit).to(beFalse())
            expect(rejectedRecovery).to(beFalse())
            expect(mocks.eventLog.routedEvents.map(\.name)).toNot(contain("replay_child"))

            store.shouldThrowOnSave = false
            let committed = await service.handleWillActivateInitialScreen(
                journeyId: journey.id,
                controller: controller
            )
            expect(committed).to(beTrue())
            expect(mocks.eventLog.routedEvents.map(\.name)).toNot(contain("replay_child"))
            let recoveredBeforeLifecycle = await service
                .handleWillDispatchInitialScreenLifecycle(
                    journeyId: journey.id,
                    controller: controller,
                    screenId: "screen-1"
                )
            expect(recoveredBeforeLifecycle).to(beTrue())
            await service.handleRuntimeReady(journeyId: journey.id, controller: controller)

            await expect {
                mocks.eventLog.routedEvents.filter { $0.name == "replay_child" }.count
            }.toEventually(equal(1), timeout: .seconds(2))
            let restored = store.loadJourney(id: journey.id)
            expect(restored?.executionState.screenRouting.pendingBatches).to(beEmpty())
            expect(restored?.executionState.screenRouting.batchReceipts["0"]?.result.status)
                .to(equal(.drained))
        }

        it("commits a signed journey-route event without requiring a screen journal") {
            let eventName = "journey_entry_authored"
            let experience = signedExperience(
                definition: journeyEntryEventDefinition(eventName: eventName)
            )
            await install(experience)
            await service.initialize()

            _ = await service.startJourney(for: experience, distinctId: distinctId)

            expect(mocks.eventLog.routedEvents.map(\.name)).to(contain(eventName))
        }

        it("rejects an invocation captured from an older presentation epoch") {
            let eventName = "stale_control_must_not_emit"
            let experience = signedExperience(definition: definition(eventName: eventName))
            guard let journey = await start(experience),
                  let stale = await service.screenControlRunScope(journeyId: journey.id) else {
                fail("expected live signed run scope")
                return
            }
            await journey.update { $0.executionState.presentationEpoch &+= 1 }

            await emitRendererControlAction(
                journeyId: journey.id,
                scope: stale,
                invocation: ScreenActionInvocation(
                    actionId: "submit",
                    value: .string("ignored"),
                    componentId: "submit-button",
                    instanceId: "survey-1"
                )
            )

            expect(mocks.eventLog.routedEvents.map(\.name)).toNot(contain(eventName))
            let routing = (await journey.snapshot()).executionState.screenRouting
            expect(routing.pendingBatches).to(beEmpty())
            expect(routing.batchReceipts).to(beEmpty())
            expect(routing.recentEventIds).to(beEmpty())
        }

        it("admits a successful batch after an accepted invocation leaves a sequence gap") {
            let eventName = "after_failed_invocation"
            let experience = signedExperience(definition: definition(eventName: eventName))
            guard let journey = await start(experience),
                  let scope = await service.screenControlRunScope(journeyId: journey.id),
                  let action = experience.definition?.control(
                    screenId: scope.screenId,
                    actionId: "submit"
                  ) else {
                fail("expected live signed screen")
                return
            }
            let dispatcher = ScreenEmissionDispatcher(
                createId: { UUID.v7().uuidString },
                now: { Date().ISO8601Format() },
                executeScriptAction: { _ in [] }
            )
            _ = await dispatcher.dispatch(
                run: ScreenEmissionRun(
                    journeyId: journey.id,
                    executionOwnershipEpoch: scope.executionOwnershipEpoch,
                    lifecycleGeneration: scope.lifecycleGeneration,
                    presentationEpoch: scope.presentationEpoch
                ),
                source: ScreenEmissionSource(
                    screenId: scope.screenId,
                    actionId: "invalid-runtime-transaction",
                    componentId: nil,
                    instanceId: nil
                ),
                drafts: [.event(name: "", payload: [:])]
            )
            let result = await dispatcher.dispatch(
                run: ScreenEmissionRun(
                    journeyId: journey.id,
                    executionOwnershipEpoch: scope.executionOwnershipEpoch,
                    lifecycleGeneration: scope.lifecycleGeneration,
                    presentationEpoch: scope.presentationEpoch
                ),
                screenId: scope.screenId,
                definition: action,
                invocation: ScreenActionInvocation(
                    actionId: "submit",
                    value: .string("accepted"),
                    componentId: "submit-button",
                    instanceId: "survey-1"
                )
            )
            let batch = try result.get()

            expect(batch.batchSequence).to(equal(1))
            expect(batch.previousCommittedBatchSequence).to(beNil())
            let batchHandled = await service.handleRendererScreenEmissionBatch(batch)
            expect(batchHandled).to(beTrue())
            expect(mocks.eventLog.routedEvents.map(\.name)).to(contain(eventName))
        }

        it("rejects cross-batch emission sequence and identity reuse") {
            let experience = signedExperience(definition: responseDefinition())
            guard let journey = await start(experience),
                  let scope = await service.screenControlRunScope(journeyId: journey.id) else {
                fail("expected live signed screen")
                return
            }
            func batch(
                batchSequence: UInt64,
                previous: UInt64?,
                emissionId: String,
                emissionSequence: UInt64,
                name: String = "unrouted",
                payload: [String: ScreenEmissionValue] = [:]
            ) -> ScreenEmissionBatch {
                ScreenEmissionBatch(
                    journeyId: journey.id,
                    executionOwnershipEpoch: scope.executionOwnershipEpoch,
                    lifecycleGeneration: scope.lifecycleGeneration,
                    presentationEpoch: scope.presentationEpoch,
                    batchSequence: batchSequence,
                    previousCommittedBatchSequence: previous,
                    invocationId: "invocation-\(batchSequence)-\(emissionSequence)",
                    source: ScreenEmissionSource(
                        screenId: scope.screenId,
                        actionId: "runtime",
                        componentId: nil,
                        instanceId: nil
                    ),
                    emissions: [ScreenEmission(
                        id: emissionId,
                        sequence: emissionSequence,
                        occurredAt: Date().ISO8601Format(),
                        name: name,
                        payload: payload
                    )]
                )
            }
            let first = batch(
                batchSequence: 0,
                previous: nil,
                emissionId: "durable-emission",
                emissionSequence: 0,
                name: SystemEventNames.responseSet,
                payload: ["field": .string("answer"), "value": .string("first")]
            )
            let firstHandled = await service.handleRendererScreenEmissionBatch(first)
            expect(firstHandled).to(beTrue())
            let firstRouting = (await journey.snapshot()).executionState.screenRouting
            let firstResult = firstRouting.batchReceipts["0"]?.result
            expect(firstResult?.status).to(equal(.drained))
            expect(firstResult?.acceptedEmissionIds).to(equal(["durable-emission"]))
            expect(firstResult?.skippedEmissionIds).to(beEmpty())
            expect(firstRouting.eventRecords).to(beEmpty())
            expect(firstRouting.recentEventIds).to(beEmpty())

            let reusedSequence = batch(
                batchSequence: 1,
                previous: 0,
                emissionId: "new-emission",
                emissionSequence: 0
            )
            let reusedSequenceHandled = await service.handleRendererScreenEmissionBatch(reusedSequence)
            expect(reusedSequenceHandled).to(beFalse())
            let reusedIdentity = batch(
                batchSequence: 1,
                previous: 0,
                emissionId: "durable-emission",
                emissionSequence: 1
            )
            let reusedIdentityHandled = await service.handleRendererScreenEmissionBatch(reusedIdentity)
            expect(reusedIdentityHandled).to(beFalse())
        }

        it("admits live Journey ingress and rejects stale or reserved host ingress") {
            let experience = signedExperience(definition: definition(eventName: "unused_route"))
            guard let journey = await start(experience),
                  let scope = await service.screenControlRunScope(journeyId: journey.id) else {
                fail("expected live signed run")
                return
            }
            let ingressScope = JourneyIngressRunScope(
                experienceId: experience.id,
                journeyId: journey.id,
                executionOwnershipEpoch: scope.executionOwnershipEpoch,
                lifecycleGeneration: scope.lifecycleGeneration
            )
            let accepted = await service.handleJourneyIngressEvent(JourneyIngressEvent(
                id: "stable-ingress-id",
                customerId: distinctId,
                occurredAt: Date().ISO8601Format(),
                name: SystemEventNames.screenShown,
                payload: [:],
                source: .sdkSystemRun(scope: ingressScope, effectInvocationId: nil)
            ))
            expect(try? accepted.get().disposition).to(equal(.accepted))
            expect(mocks.eventLog.routedEvents.first {
                $0.name == SystemEventNames.screenShown
            }?.id).to(equal("stable-ingress-id"))

            let stale = await service.handleJourneyIngressEvent(JourneyIngressEvent(
                id: "stale-ingress-id",
                customerId: distinctId,
                occurredAt: Date().ISO8601Format(),
                name: SystemEventNames.screenShown,
                payload: [:],
                source: .sdkSystemRun(
                    scope: JourneyIngressRunScope(
                        experienceId: experience.id,
                        journeyId: journey.id,
                        executionOwnershipEpoch: scope.executionOwnershipEpoch + 1,
                        lifecycleGeneration: scope.lifecycleGeneration
                    ),
                    effectInvocationId: nil
                )
            ))
            expect(stale.failureValue).to(equal(.ownershipStale))
            let reservedHost = await service.handleJourneyIngressEvent(JourneyIngressEvent(
                id: "invalid-host-ingress",
                customerId: distinctId,
                occurredAt: Date().ISO8601Format(),
                name: SystemEventNames.screenShown,
                payload: [:],
                source: .hostApp
            ))
            expect(reservedHost.failureValue).to(equal(.eventNameInvalid))
        }

        it("rejects an emission from a screen that is no longer active before persistence") {
            let eventName = "stale_screen_must_not_emit"
            let experience = signedExperience(definition: definition(eventName: eventName))
            guard let journey = await start(experience),
                  let stale = await service.screenControlRunScope(journeyId: journey.id),
                  let action = experience.definition?.control(
                    screenId: stale.screenId,
                    actionId: "submit"
                  ) else {
                fail("expected live signed screen")
                return
            }
            let dispatcher = ScreenEmissionDispatcher(
                createId: { UUID.v7().uuidString },
                now: { Date().ISO8601Format() },
                executeScriptAction: { _ in [] }
            )
            let result = await dispatcher.dispatch(
                run: ScreenEmissionRun(
                    journeyId: journey.id,
                    executionOwnershipEpoch: stale.executionOwnershipEpoch,
                    lifecycleGeneration: stale.lifecycleGeneration,
                    presentationEpoch: stale.presentationEpoch
                ),
                screenId: stale.screenId,
                definition: action,
                invocation: ScreenActionInvocation(
                    actionId: "submit",
                    value: .string("ignored"),
                    componentId: "submit-button",
                    instanceId: "survey-1"
                )
            )
            let batch = try result.get()
            await journey.update { $0.executionState.currentScreenId = "screen-2" }

            let published = await service.handleRendererScreenEmissionBatch(batch)

            expect(published).to(beFalse())
            expect(mocks.eventLog.routedEvents.map(\.name)).toNot(contain(eventName))
            let routing = (await journey.snapshot()).executionState.screenRouting
            expect(routing.pendingBatches).to(beEmpty())
            expect(routing.batchReceipts).to(beEmpty())
            expect(routing.recentEventIds).to(beEmpty())
        }

        it("preserves a nested signed action path after prepared-name route admission") {
            let experience = signedExperience(definition: renamedRouteDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            mocks.eventLog.preparedTriggerBeforeSend = { event in
                guard event.name == "original_submit" else { return event }
                return NuxieEvent(
                    id: event.id,
                    name: "renamed_submit",
                    distinctId: event.distinctId,
                    properties: event.properties,
                    timestamp: event.timestamp
                )
            }

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(actionId: "submit")
            )

            expect(mocks.eventLog.routedEvents.map(\.name))
                .to(contain("renamed_route_ran"))
            expect(mocks.eventLog.routedEvents.map(\.name))
                .to(contain("nested_route_ran"))
        }

        it("applies a source gate plan before a nested authored-event gate plan") {
            let sourceFlow = "source-gate-flow"
            let nestedFlow = "nested-gate-flow"
            let experience = signedExperience(definition: renamedRouteDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            mocks.eventLog.preparedTriggerBeforeSend = { event in
                guard event.name == "original_submit" else { return event }
                return NuxieEvent(
                    id: event.id,
                    name: "renamed_submit",
                    distinctId: event.distinctId,
                    properties: event.properties,
                    timestamp: event.timestamp
                )
            }
            mocks.eventLog.setTrackWithResponseResult(
                gatePlanResponse(flowId: sourceFlow),
                for: "renamed_submit"
            )
            mocks.eventLog.setTrackWithResponseResult(
                gatePlanResponse(flowId: nestedFlow),
                for: "renamed_route_ran"
            )

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(actionId: "submit")
            )

            await expect {
                mocks.experiencePresentationService.presentedExperiences
                    .map(\.experienceVersionId)
                    .filter { $0 == sourceFlow || $0 == nestedFlow }
            }.toEventually(equal([sourceFlow, nestedFlow]), timeout: .seconds(2))
        }

        it("accepts an exact authoritative opaque feature gate without showing its fallback") {
            let fallbackFlow = "opaque-gate-fallback"
            let experience = signedExperience(definition: renamedRouteDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            mocks.eventLog.preparedTriggerBeforeSend = { event in
                guard event.name == "original_submit" else { return event }
                return NuxieEvent(
                    id: event.id,
                    name: "renamed_submit",
                    distinctId: event.distinctId,
                    properties: event.properties,
                    timestamp: event.timestamp
                )
            }
            mocks.eventLog.setTrackWithResponseResult(
                featureGatePlanResponse(
                    featureId: "exports",
                    requiredBalance: 2,
                    flowId: fallbackFlow
                ),
                for: "renamed_submit"
            )
            await featureService.applyAuthoritativeUse(
                FeatureCheckResult(
                    customerId: distinctId,
                    featureId: "credit_wallet",
                    requiredBalance: 2,
                    code: "feature_found",
                    allowed: true,
                    unlimited: false,
                    balance: 8,
                    type: .creditSystem,
                    preview: nil
                ),
                requestedFeatureId: "exports",
                distinctId: distinctId,
                entityId: nil
            )
            await featureService.syncFeatureInfo()
            let published = await MainActor.run {
                featureInfo.feature("exports")
            }
            expect(published?.allowed).to(beTrue())
            expect(published?.balance).to(beNil())
            await mocks.nuxieApi.setCheckFeatureResponse(
                FeatureCheckResult(
                    customerId: distinctId,
                    featureId: "exports",
                    requiredBalance: 2,
                    code: "insufficient_balance",
                    allowed: false,
                    unlimited: false,
                    balance: 0,
                    type: .metered,
                    preview: nil
                )
            )

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(actionId: "submit")
            )

            expect(mocks.experiencePresentationService.presentedExperiences.map(\.experienceVersionId))
                .toNot(contain(fallbackFlow))
        }

        it("rejects an ordinary metered feature gate with no visible balance") {
            let fallbackFlow = "ordinary-gate-fallback"
            let experience = signedExperience(definition: renamedRouteDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            mocks.eventLog.preparedTriggerBeforeSend = { event in
                guard event.name == "original_submit" else { return event }
                return NuxieEvent(
                    id: event.id,
                    name: "renamed_submit",
                    distinctId: event.distinctId,
                    properties: event.properties,
                    timestamp: event.timestamp
                )
            }
            mocks.eventLog.setTrackWithResponseResult(
                featureGatePlanResponse(
                    featureId: "exports",
                    requiredBalance: 2,
                    flowId: fallbackFlow
                ),
                for: "renamed_submit"
            )
            let info = featureInfo!
            await MainActor.run {
                info.update([
                    "exports": FeatureAccess(
                        allowed: true,
                        unlimited: false,
                        balance: nil,
                        type: .metered
                    )
                ])
            }
            await mocks.nuxieApi.setCheckFeatureResponse(
                FeatureCheckResult(
                    customerId: distinctId,
                    featureId: "exports",
                    requiredBalance: 2,
                    code: "insufficient_balance",
                    allowed: false,
                    unlimited: false,
                    balance: 0,
                    type: .metered,
                    preview: nil
                )
            )

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(actionId: "submit")
            )

            await expect {
                mocks.experiencePresentationService.presentedExperiences
                    .map(\.experienceVersionId)
            }.toEventually(contain(fallbackFlow), timeout: .seconds(2))
        }

        it("does not re-enroll the source experience from its own generated event") {
            let eventName = "paywall_trigger"
            let experience = signedExperience(definition: definition(eventName: eventName))
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(
                    actionId: "submit",
                    value: .string("done"),
                    componentId: "submit-button",
                    instanceId: "survey-1"
                )
            )

            let active = await service.getActiveJourneys(for: distinctId)
            expect(active.map(\.id)).to(equal([journey.id]))
        }

        it("reuses the unpublished sequence after a routing journal save failure") {
            let eventName = "survey_submitted_after_retry"
            let experience = signedExperience(definition: definition(eventName: eventName))
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            store.shouldThrowOnSave = true
            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(
                    actionId: "submit",
                    value: .string("first"),
                    componentId: "submit-button",
                    instanceId: "survey-1"
                )
            )
            expect(mocks.eventLog.routedEvents.map(\.name)).toNot(contain(eventName))
            let failedRouting = (await journey.snapshot()).executionState.screenRouting
            expect(failedRouting.nextBatchSequence).to(equal(0))
            expect(failedRouting.pendingBatches).to(beEmpty())
            let currentScope = await service.screenControlRunScope(journeyId: journey.id)
            expect(currentScope).toNot(beNil())

            store.shouldThrowOnSave = false
            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(
                    actionId: "submit",
                    value: .string("second"),
                    componentId: "submit-button",
                    instanceId: "survey-1"
                )
            )

            let routing = (await journey.snapshot()).executionState.screenRouting
            expect(mocks.eventLog.routedEvents.map(\.name)).to(contain(eventName))
            expect(routing.nextBatchSequence).to(equal(1))
            expect(Array(routing.pendingBatches.keys)).to(beEmpty())
            expect(routing.lastProcessedBatchSequence).to(equal(0))
            expect(routing.batchReceipts["0"]?.result.status).to(equal(.drained))
        }

        it("keeps a failed authored routing claim recoverable without blocking later responses") {
            let claimFailingStore = RoutingClaimFailingJourneyStore()
            store = claimFailingStore
            service = mocks.makeJourneyService(journeyStore: store)
            let experience = signedExperience(definition: renamedRouteDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            mocks.eventLog.preparedTriggerBeforeSend = { event in
                guard event.name == "original_submit" else { return event }
                return NuxieEvent(
                    id: event.id,
                    name: "renamed_submit",
                    distinctId: event.distinctId,
                    properties: event.properties,
                    timestamp: event.timestamp
                )
            }
            mocks.eventLog.setTrackWithResponseResult(
                gatePlanResponse(flowId: "authored-response-flow"),
                for: "renamed_route_ran"
            )
            claimFailingStore.failNextAuthoredRoutingClaim()

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(actionId: "submit")
            )

            let failed = await journey.snapshot()
            expect(failed.executionState.screenRouting.eventRecords.values
                .flatMap(\.pendingAuthoredEvents)).toNot(beEmpty())
            expect(mocks.experiencePresentationService.presentedExperiences.filter {
                $0.experienceVersionId == "authored-response-flow"
            })
                .to(beEmpty())

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(actionId: "submit")
            )

            await expect {
                mocks.experiencePresentationService.presentedExperiences.filter {
                    $0.experienceVersionId == "authored-response-flow"
                }.count
            }.toEventually(equal(1), timeout: .seconds(2))

            await restartAndRecover(experience)

            await expect {
                store.loadJourney(id: journey.id)?.executionState.screenRouting
                    .eventRecords.values.flatMap(\.pendingAuthoredEvents) ?? []
            }.toEventually(beEmpty(), timeout: .seconds(2))
        }

        it("does not recreate a screen routing snapshot after its journey exits") {
            let experience = signedExperience(
                definition: renamedRouteDefinition(),
                goal: GoalConfig(kind: .event, eventName: "renamed_route_ran"),
                exitPolicy: ExitPolicy(mode: .onGoal)
            )
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            mocks.eventLog.preparedTriggerBeforeSend = { event in
                guard event.name == "original_submit" else { return event }
                return NuxieEvent(
                    id: event.id,
                    name: "renamed_submit",
                    distinctId: event.distinctId,
                    properties: event.properties,
                    timestamp: event.timestamp
                )
            }

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(actionId: "submit")
            )

            let activeJourneys = await service.getActiveJourneys(for: distinctId)
            expect(activeJourneys).to(beEmpty())
            expect(store.loadJourney(id: journey.id)).to(beNil())
        }

        it("recovers pending authored events retained by a finished admission") {
            let experience = signedExperience(definition: renamedRouteDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            try await persistAuthoredEventRecoveryCut(
                journey: journey,
                parentPhase: .finished,
                authoredPhase: .prepared
            )

            await restartAndRecover(experience)

            await expect { mocks.eventLog.routedEvents.map(\.name) }
                .toEventually(contain("renamed_route_ran"), timeout: .seconds(2))
            guard let restored = store.loadJourney(id: journey.id) else {
                fail("expected restored journey")
                return
            }
            expect(restored.executionState.screenRouting.eventRecords)
                .to(beEmpty())
        }

        it("resumes an authored event after its durable routing claim") {
            let experience = signedExperience(definition: renamedRouteDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            try await persistAuthoredEventRecoveryCut(
                journey: journey,
                parentPhase: .finished,
                authoredPhase: .routingClaimed
            )

            await restartAndRecover(experience)

            await expect {
                mocks.eventLog.routedEvents.filter { $0.name == "renamed_route_ran" }.count
            }.toEventually(equal(1), timeout: .seconds(2))
            guard let restored = store.loadJourney(id: journey.id) else {
                fail("expected restored journey")
                return
            }
            expect(restored.executionState.screenRouting.eventRecords)
                .to(beEmpty())
        }

        it("retains a screen-route admission while its delayed continuation is pending") {
            let experience = signedExperience(definition: pausedRouteDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }

            await emitRendererControlAction(
                journeyId: journey.id,
                screenId: "screen-1",
                invocation: ScreenActionInvocation(actionId: "submit")
            )

            let snapshot = await journey.snapshot()
            let admissionId = snapshot.executionState.pendingAction?.continuation?
                .compactMap { step -> String? in
                    guard case .request(let request) = step.operation else { return nil }
                    return request.screenRouteAdmissionId
                }
                .first
            expect(admissionId).toNot(beNil())
            expect(snapshot.executionState.screenRouting.eventRecords[admissionId ?? ""])
                .toNot(beNil())
        }

        it("reconciles an authored intent before resuming its stale parent cursor") {
            let experience = signedExperience(definition: replayRecoveryDefinition())
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            try await persistAuthoredIntentBeforeParentCursor(journey: journey)

            await restartAndRecover(experience)

            await expect {
                mocks.eventLog.routedEvents.filter { $0.name == "replay_child" }.count
            }.toEventually(equal(1), timeout: .seconds(2))
            guard let restored = store.loadJourney(id: journey.id) else {
                fail("expected restored journey")
                return
            }
            expect(restored.executionState.screenRouting.eventRecords.values
                .flatMap(\.pendingAuthoredEvents)).to(beEmpty())
        }

        it("does not execute a durably claimed back action again after restart") {
            let definition = backReplayDefinition()
            let experience = signedExperience(definition: definition)
            guard let journey = await start(experience) else {
                fail("expected signed journey")
                return
            }
            let admissionId = "claimed-back-source"
            let source = ScreenCustomerEvent(
                id: admissionId,
                customerId: distinctId,
                occurredAt: Date().ISO8601Format(),
                name: "go_back",
                payload: [:],
                source: .screen(
                    experienceId: experienceId,
                    journeyId: journey.id,
                    source: ScreenEmissionSource(
                        screenId: "screen-1",
                        actionId: "back",
                        componentId: nil,
                        instanceId: nil
                    )
                ),
                causality: ExperienceEventCausality(
                    chainId: journey.id,
                    parentEventId: nil,
                    visitedExperienceIds: [experienceId],
                    hopCount: 0
                )
            )
            let request = JourneyContinuationRequest(
                rootId: admissionId,
                isPriority: false,
                actions: [.back(BackAction(steps: 1))],
                actionPaths: ["/program/0"],
                hostId: "screen-1",
                screenId: "screen-1",
                componentId: nil,
                handlerId: "route:\(String(repeating: "9", count: 64))",
                instanceId: nil,
                payload: ["__nuxie_emission_id": AnyCodable(admissionId)],
                requiresTerminalTransfer: false,
                startIndex: 0,
                usesPendingResumeContext: false,
                resume: nil,
                screenRouteAdmissionId: admissionId
            )
            var snapshot = await journey.snapshot()
            snapshot.executionState.navigationStack = ["screen-a", "screen-b"]
            snapshot.executionState.screenRouting.eventRecords[admissionId] =
                JourneyScreenEventRecord(
                    sourceEvent: source,
                    preparedId: admissionId,
                    preparedName: source.name,
                    preparedDistinctId: distinctId,
                    preparedProperties: [:],
                    preparedOccurredAt: Date(),
                    localRoute: .ready(AcceptedScreenLocalRoute(
                        admissionId: admissionId,
                        key: .screen(screenId: "screen-1", eventName: source.name),
                        routeRevision: String(repeating: "9", count: 64)
                    )),
                    excludedExperienceId: experienceId,
                    phase: .routeExecuting,
                    routeContinuation: [JourneyContinuationStep(
                        rootId: admissionId,
                        operation: .request(request)
                    )],
                    claimedEffectPaths: ["\(admissionId):action:/program/0"],
                    pendingAuthoredEvents: []
                )
            try store.saveJourney(snapshot)

            await restartAndRecover(experience)

            let restored = store.loadJourney(id: journey.id)
            expect(restored?.executionState.navigationStack)
                .to(equal(["screen-a", "screen-b"]))
        }
    }
}

extension Result {
    fileprivate var failureValue: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}

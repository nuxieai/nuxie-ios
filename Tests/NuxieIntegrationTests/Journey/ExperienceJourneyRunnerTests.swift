import Foundation
import Quick
import Nimble
import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

final class ExperienceJourneyRunnerTests: AsyncSpec {
    override class func spec() {
        // nonisolated(unsafe): Quick runs beforeEach and each example strictly
        // serially, so spec-level fixtures are never accessed concurrently despite
        // being captured by @MainActor example closures.
        nonisolated(unsafe) var mocks: MockFactory!

        beforeEach {
            mocks = MockFactory.shared
        }

        // Builds a runner over the shared mocks plus a real feature service
        // and wired IR runtime, mirroring the old container defaults.
        func makeRunner(
            journey: Journey,
            experience: Experience,
            content: Experience,
            onMilestone: (@Sendable (_ milestoneId: String, _ milestoneLabel: String?, _ screenId: String?, _ handlerId: String?) async -> Void)? = nil,
            persistEntryActionClaim: @escaping @Sendable (JourneySnapshot) async -> Bool = { _ in true }
        ) -> JourneyRunner {
            let featureInfo = FeatureInfo()
            let irRuntime = IRRuntime(dateProvider: mocks.dateProvider)
            let features = FeatureService(
                api: mocks.nuxieApi,
                identity: mocks.identityService,
                profile: mocks.profileService,
                dateProvider: mocks.dateProvider,
                featureInfo: featureInfo,
                cacheTTL: 5 * 60
            )
            irRuntime.wire(
                identity: mocks.identityService,
                eventLog: mocks.eventLog,
                segments: mocks.segmentService,
                features: features
            )
            let hydratedExperience = Experience(
                id: experience.id,
                versionId: content.versionId,
                buildId: content.buildId,
                name: experience.name,
                reentry: experience.reentry,
                publishedAt: experience.publishedAt,
                trigger: experience.trigger,
                goal: experience.goal,
                exitPolicy: experience.exitPolicy,
                conversionAnchor: experience.conversionAnchor,
                timeLimitSeconds: experience.timeLimitSeconds,
                experienceType: experience.experienceType,
                journey: content.journey,
                products: content.products
            )
            return JourneyRunner(
                journey: journey,
                experience: hydratedExperience,
                onMilestone: onMilestone,
                eventLog: mocks.eventLog,
                identity: mocks.identityService,
                segments: mocks.segmentService,
                features: features,
                profile: mocks.profileService,
                apiClient: mocks.nuxieApi,
                dateProvider: mocks.dateProvider,
                irRuntime: irRuntime,
                persistEntryActionClaim: persistEntryActionClaim
            )
        }

        func makeExperience(flowId: String) -> Experience {
            let publishedAt = ISO8601DateFormatter().string(from: Date())
            return Experience(
                id: "camp-1",
                versionId: flowId,
                name: "Test Experience",
                reentry: .oneTime,
                publishedAt: publishedAt,
                trigger: .event(EventTriggerConfig(eventName: "test_event", condition: nil)),
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                experienceType: nil
            )
        }

        func vmPath(_ propertyPath: String, viewModelName: String = "VM") -> VmPathRef {
            VmPathRef(viewModelName: viewModelName, path: propertyPath)
        }

        func makePaywallViewModel() -> ViewModel {
            let stringProperty = { (id: Int, defaultValue: String?) in
                ViewModelProperty(
                    type: .string,
                    propertyId: id,
                    defaultValue: defaultValue.map(AnyCodable.init),
                    required: nil,
                    enumValues: nil,
                    itemType: nil,
                    schema: nil,
                    viewModelId: nil,
                    validation: nil
                )
            }
            let statusProperty = { (id: Int, values: [String]) in
                ViewModelProperty(
                    type: .enum,
                    propertyId: id,
                    defaultValue: AnyCodable("idle"),
                    required: nil,
                    enumValues: values,
                    itemType: nil,
                    schema: nil,
                    viewModelId: nil,
                    validation: nil
                )
            }
            return ViewModel(
                id: "vm-1",
                name: "VM",
                viewModelPathId: 0,
                properties: [
                    "paywall": ViewModelProperty(
                        type: .object,
                        propertyId: 1,
                        defaultValue: nil,
                        required: nil,
                        enumValues: nil,
                        itemType: nil,
                        schema: [
                            "purchase": ViewModelProperty(
                                type: .object,
                                propertyId: 2,
                                defaultValue: nil,
                                required: nil,
                                enumValues: nil,
                                itemType: nil,
                                schema: [
                                    "status": statusProperty(3, ["idle", "running", "success", "error", "cancelled"]),
                                    "errorCode": stringProperty(4, ""),
                                    "invocationId": stringProperty(5, ""),
                                ],
                                viewModelId: nil,
                                validation: nil
                            ),
                            "restore": ViewModelProperty(
                                type: .object,
                                propertyId: 6,
                                defaultValue: nil,
                                required: nil,
                                enumValues: nil,
                                itemType: nil,
                                schema: [
                                    "status": statusProperty(7, ["idle", "running", "success", "error", "not_found"]),
                                    "errorCode": stringProperty(8, ""),
                                    "invocationId": stringProperty(9, ""),
                                ],
                                viewModelId: nil,
                                validation: nil
                            ),
                        ],
                        viewModelId: nil,
                        validation: nil
                    )
                ]
            )
        }

        func snapshotValue(_ journey: Journey, path: String) async -> Any? {
            (await journey.snapshot()).executionState.viewModelSnapshot?.viewModelInstances
                .compactMap { $0.values[path]?.value }
                .first
        }

        func normalizeAnyCodable(_ value: AnyCodable) -> AnyCodable {
            AnyCodable(normalizeAny(value.value))
        }

        func normalizeAny(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                return dict.mapValues { normalizeAny($0) }
            }
            if let dict = value as? [String: AnyCodable] {
                return dict.mapValues { normalizeAnyCodable($0) }
            }
            if let array = value as? [Any] {
                return array.map { normalizeAny($0) }
            }
            if let array = value as? [AnyCodable] {
                return array.map { normalizeAnyCodable($0) }
            }
            return value
        }

        func normalizeAction(_ action: JourneyAction, viewModels: [ViewModel]) -> JourneyAction {
            switch action {
            case .setViewModel(let action):
                return .setViewModel(SetViewModelAction(
                    type: action.type,
                    path: action.path,
                    value: normalizeAnyCodable(action.value)
                ))
            case .fireTrigger(let action):
                return .fireTrigger(FireTriggerAction(
                    type: action.type,
                    path: action.path
                ))
            case .listInsert(let action):
                return .listInsert(ListInsertAction(
                    type: action.type,
                    path: action.path,
                    index: action.index,
                    value: normalizeAnyCodable(action.value)
                ))
            case .listRemove(let action):
                return .listRemove(ListRemoveAction(
                    type: action.type,
                    path: action.path,
                    index: action.index
                ))
            case .listSwap(let action):
                return .listSwap(ListSwapAction(
                    type: action.type,
                    path: action.path,
                    indexA: action.indexA,
                    indexB: action.indexB
                ))
            case .listMove(let action):
                return .listMove(ListMoveAction(
                    type: action.type,
                    path: action.path,
                    from: action.from,
                    to: action.to
                ))
            case .listSet(let action):
                return .listSet(ListSetAction(
                    type: action.type,
                    path: action.path,
                    index: action.index,
                    value: normalizeAnyCodable(action.value)
                ))
            case .listClear(let action):
                return .listClear(ListClearAction(
                    type: action.type,
                    path: action.path
                ))
            case .condition(let action):
                return .condition(ConditionAction(
                    type: action.type,
                    nodeId: action.nodeId,
                    branches: action.branches.map { branch in
                        ConditionBranch(
                            id: branch.id,
                            label: branch.label,
                            condition: branch.condition,
                            actions: branch.actions.map { normalizeAction($0, viewModels: viewModels) }
                        )
                    },
                    defaultActions: action.defaultActions?.map { normalizeAction($0, viewModels: viewModels) }
                ))
            case .experiment(let action):
                return .experiment(ExperimentAction(
                    type: action.type,
                    nodeId: action.nodeId,
                    experimentId: action.experimentId,
                    variants: action.variants.map { variant in
                        ExperimentVariant(
                            id: variant.id,
                            name: variant.name,
                            percentage: variant.percentage,
                            actions: variant.actions.map { normalizeAction($0, viewModels: viewModels) }
                        )
                    }
                ))
            case .timeWindow(let action):
                return .timeWindow(TimeWindowAction(
                    type: action.type,
                    nodeId: action.nodeId,
                    startTime: action.startTime,
                    endTime: action.endTime,
                    timezone: action.timezone,
                    daysOfWeek: action.daysOfWeek,
                    successActions: action.successActions?.map { normalizeAction($0, viewModels: viewModels) }
                ))
            case .purchase(let action):
                return .purchase(PurchaseAction(
                    type: action.type,
                    placementIndex: normalizeAnyCodable(action.placementIndex),
                    productId: normalizeAnyCodable(action.productId),
                    onCompleted: action.onCompleted?.map { normalizeAction($0, viewModels: viewModels) },
                    onFailed: action.onFailed?.map { normalizeAction($0, viewModels: viewModels) },
                    onCancelled: action.onCancelled?.map { normalizeAction($0, viewModels: viewModels) }
                ))
            default:
                return action
            }
        }

        func defaultValues(for viewModel: ViewModel) -> [String: AnyCodable] {
            viewModel.properties.compactMapValues { $0.defaultValue }
        }

        func viewModelValues(
            viewModels: [ViewModel],
            instances: [ViewModelInstance]?
        ) -> [JourneyViewModelValue] {
            let nameById = Dictionary(uniqueKeysWithValues: viewModels.map { ($0.id, $0.name) })
            let sourceInstances = instances ?? viewModels.compactMap { viewModel -> ViewModelInstance? in
                let values = defaultValues(for: viewModel)
                guard !values.isEmpty else { return nil }
                return ViewModelInstance(
                    viewModelId: viewModel.id,
                    instanceId: "\(viewModel.name):default",
                    name: "Default",
                    values: values
                )
            }
            return sourceInstances.flatMap { instance in
                guard let viewModelName = nameById[instance.viewModelId] else { return [JourneyViewModelValue]() }
                return instance.values.map { key, value in
                    JourneyViewModelValue(
                        viewModelName: viewModelName,
                        instanceId: instance.instanceId,
                        instanceName: instance.name,
                        path: key,
                        value: value
                    )
                }
            }
        }

        func makeJourneyDocument(
            flowId: String,
            entryActions: [JourneyAction]? = nil,
            events: JourneyEventMap = [:],
            handlers: JourneyHandlerMap = [:],
            synthesizeHandlerEvents: Bool = true,
            scripts: [String: [ScreenScriptRef]] = [:],
            viewModels: [ViewModel] = [],
            viewModelInstances: [ViewModelInstance]? = nil,
            screens: [JourneyScreen]? = nil,
            responseSchemas: [JourneyResponseSchema]? = nil
        ) -> JourneyDocument {
            var handlerMap = handlers
            if let entryActions, !entryActions.isEmpty {
                handlerMap[JourneyDocument.journeyEventHostKey, default: []].append(
                    JourneyEventHandler(
                        id: "start",
                        eventName: "$app_opened",
                        enabled: true,
                        actions: entryActions.map { normalizeAction($0, viewModels: viewModels) }
                    )
                )
            }
            let resolvedScreens = (screens ?? [
                JourneyScreen(
                    id: "screen-1",
                    defaultViewModelName: viewModels.first?.name,
                    defaultInstanceId: nil
                )
            ]).map { screen in
                JourneyScreen(
                    id: screen.id,
                    defaultViewModelName: screen.defaultViewModelName.map { defaultName in
                        viewModels.first(where: { $0.id == defaultName })?.name ?? defaultName
                    },
                    defaultInstanceId: screen.defaultInstanceId
                )
            }
            let normalizedHandlers = handlerMap.mapValues { handlers in
                handlers.map { handler in
                    JourneyEventHandler(
                        id: handler.id,
                        eventName: handler.eventName,
                        enabled: handler.enabled,
                        order: handler.order,
                        actions: handler.actions.map { normalizeAction($0, viewModels: viewModels) }
                    )
                }
            }
            var eventMap = events
            if synthesizeHandlerEvents {
                for (hostId, handlers) in normalizedHandlers {
                    var seen = Set(eventMap[hostId, default: []].map(\.eventName))
                    for handler in handlers where !seen.contains(handler.eventName) {
                        seen.insert(handler.eventName)
                        eventMap[hostId, default: []].append(
                            EventDeclaration(
                                id: "\(handler.id):event",
                                eventName: handler.eventName
                            )
                        )
                    }
                }
            }
            let values = viewModelValues(viewModels: viewModels, instances: viewModelInstances)

            return JourneyDocument(
                screens: resolvedScreens,
                events: eventMap,
                handlers: normalizedHandlers,
                scripts: scripts,
                viewModelValues: values.isEmpty ? nil : values,
                responseSchemas: responseSchemas
            )
        }

        func loadFixtureObject(_ path: String) throws -> [String: Any] {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let data = try Data(
                contentsOf: root.appendingPathComponent("fixtures/\(path)")
            )
            guard let object = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return object
        }

        describe("JourneyRunner") {
            it("persists presentation, then resumes the post-attach continuation exactly once") {
                let flowId = "flow-pre-mount-continuation"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .navigate(NavigateAction(
                            screenId: "screen-selected",
                            transition: nil
                        )),
                        .sendEvent(SendEventAction(eventName: "after_attach"))
                    ]
                )
                let content = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: content
                )

                guard case .present(let commit) = await runner.advanceUntilPresentation() else {
                    fail("expected persisted presentation commit")
                    return
                }
                expect(commit.screenId).to(equal("screen-selected"))
                expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("after_attach"))
                let beforeAttach = await journey.snapshot()
                expect(beforeAttach.executionState.currentScreenId).to(beNil())

                let attached = await runner.commitRendererAttachment()
                expect(attached).to(beTrue())
                _ = await runner.handleRuntimeReady()
                _ = await runner.handleRuntimeReady()

                let state = await journey.snapshot()
                expect(state.executionState.pendingPresentation).to(beNil())
                expect(state.executionState.currentScreenId).to(equal("screen-selected"))
                expect(mocks.eventLog.trackedEvents.map(\.name).filter {
                    $0 == "after_attach"
                }).to(haveCount(1))
            }

            it("resumes a durably claimed signed entry after a crash before execution") {
                let flowId = "flow-pre-mount-claim-crash"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .navigate(NavigateAction(
                            screenId: "screen-selected",
                            transition: nil
                        )),
                        .sendEvent(SendEventAction(eventName: "after_attach_once"))
                    ],
                    screens: [JourneyScreen(id: "screen-selected")]
                )
                let content = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let firstJourney = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let durableStore = MockJourneyStore()
                let crashingRunner = makeRunner(
                    journey: firstJourney,
                    experience: experience,
                    content: content,
                    persistEntryActionClaim: { snapshot in
                        try? durableStore.saveJourney(snapshot)
                        return false
                    }
                )

                let crashedOutcome = await crashingRunner.advanceUntilPresentation()
                expect(crashedOutcome).to(beNil())
                let persisted = try XCTUnwrap(
                    durableStore.loadJourney(id: firstJourney.id)
                )
                expect(persisted.executionState.prePresentationContinuation).toNot(beNil())
                expect(persisted.executionState.pendingPresentation).to(beNil())

                let restoredJourney = Journey(snapshot: persisted)
                let restoredRunner = makeRunner(
                    journey: restoredJourney,
                    experience: experience,
                    content: content
                )
                guard case .present(let commit) = await restoredRunner.advanceUntilPresentation() else {
                    fail("expected restored presentation commit")
                    return
                }
                expect(commit.screenId).to(equal("screen-selected"))
                expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("after_attach_once"))

                let attached = await restoredRunner.commitRendererAttachment()
                expect(attached).to(beTrue())
                _ = await restoredRunner.handleRuntimeReady()
                _ = await restoredRunner.handleRuntimeReady()
                expect(mocks.eventLog.trackedEvents.map(\.name).filter {
                    $0 == "after_attach_once"
                }).to(haveCount(1))
            }

            it("restores an exact pending presentation and continuation without replay") {
                let flowId = "flow-pre-mount-pending-restart"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .navigate(.init(
                            nodeId: "node-attach-retry",
                            screenId: "screen-selected",
                            transition: nil
                        )),
                        .sendEvent(.init(eventName: "continued_after_restart"))
                    ],
                    screens: [JourneyScreen(id: "screen-selected")]
                )
                let content = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let originalJourney = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let originalRunner = makeRunner(
                    journey: originalJourney,
                    experience: experience,
                    content: content
                )
                guard case .present(let originalCommit) =
                    await originalRunner.advanceUntilPresentation() else {
                    fail("expected original presentation commit")
                    return
                }

                let restoredJourney = Journey(snapshot: await originalJourney.snapshot())
                let restoredRunner = makeRunner(
                    journey: restoredJourney,
                    experience: experience,
                    content: content
                )
                guard case .present(let restoredCommit) =
                    await restoredRunner.advanceUntilPresentation() else {
                    fail("expected restored presentation commit")
                    return
                }
                expect(restoredCommit.screenId).to(equal(originalCommit.screenId))
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain("continued_after_restart"))

                let attached = await restoredRunner.commitRendererAttachment()
                expect(attached).to(beTrue())
                _ = await restoredRunner.handleRuntimeReady()
                _ = await restoredRunner.handleRuntimeReady()
                let final = await restoredJourney.snapshot()
                expect(final.executionState.pendingPresentation).to(beNil())
                expect(final.executionState.currentScreenId).to(equal("screen-selected"))
                expect(mocks.eventLog.trackedEvents.map(\.name).filter {
                    $0 == "continued_after_restart"
                }).to(haveCount(1))
            }

            it("sorts same-event entry handlers before selecting the presentation commit") {
                let flowId = "flow-pre-mount-handler-order"
                let journeyDocument = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            .init(
                                id: "post-attach",
                                eventName: SystemEventNames.journeyStarted,
                                order: 20,
                                actions: [.sendEvent(.init(eventName: "ordered_after_attach"))]
                            ),
                            .init(
                                id: "presentation-commit",
                                eventName: SystemEventNames.journeyStarted,
                                order: 10,
                                actions: [.navigate(.init(
                                    screenId: "screen-selected",
                                    transition: nil
                                ))]
                            ),
                        ],
                    ],
                    screens: [JourneyScreen(id: "screen-selected")]
                )
                let content = Experience.test(journey: journeyDocument, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: content
                )

                guard case .present(let commit) = await runner.advanceUntilPresentation() else {
                    fail("expected ordered presentation commit")
                    return
                }
                expect(commit.screenId).to(equal("screen-selected"))
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain("ordered_after_attach"))
                let attached = await runner.commitRendererAttachment()
                expect(attached).to(beTrue())
                _ = await runner.handleRuntimeReady()
                expect(mocks.eventLog.trackedEvents.map(\.name).filter {
                    $0 == "ordered_after_attach"
                }).to(haveCount(1))
            }

            it("keeps a failed attachment commit retryable without exposing lifecycle") {
                let flowId = "flow-pre-mount-attach-save-failure"
                let document = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .navigate(.init(
                            nodeId: "node-attach-retry",
                            screenId: "screen-selected",
                            transition: nil
                        )),
                        .sendEvent(.init(eventName: "after_attach_retry")),
                    ],
                    screens: [JourneyScreen(id: "screen-selected")]
                )
                let content = Experience.test(journey: document, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let attempts = LockedCounter()
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: content,
                    persistEntryActionClaim: { _ in attempts.increment() != 3 }
                )
                guard case .present = await runner.advanceUntilPresentation() else {
                    fail("expected presentation commit")
                    return
                }

                let firstAttach = await runner.commitRendererAttachment()
                expect(firstAttach).to(beFalse())
                let failed = await journey.snapshot()
                expect(failed.executionState.pendingPresentation).toNot(beNil())
                expect(failed.executionState.currentScreenId).to(beNil())
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain("after_attach_retry"))

                let retryAttach = await runner.commitRendererAttachment()
                expect(retryAttach).to(beTrue())
                _ = await runner.handleRuntimeReady()
                expect(mocks.eventLog.trackedEvents.map(\.name).filter {
                    $0 == "after_attach_retry"
                }).to(haveCount(1))
            }

            it("restores a durable attached continuation before it has drained") {
                let flowId = "flow-pre-mount-attached-crash"
                let document = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .navigate(.init(screenId: "screen-selected", transition: nil)),
                        .sendEvent(.init(eventName: "after_attached_crash")),
                    ],
                    screens: [JourneyScreen(id: "screen-selected")]
                )
                let content = Experience.test(journey: document, products: [])
                let experience = makeExperience(flowId: flowId)
                let first = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let durableStore = MockJourneyStore()
                let runner = makeRunner(
                    journey: first,
                    experience: experience,
                    content: content,
                    persistEntryActionClaim: { snapshot in
                        try? durableStore.saveJourney(snapshot)
                        return true
                    }
                )
                guard case .present = await runner.advanceUntilPresentation() else {
                    fail("expected presentation commit")
                    return
                }
                let attached = await runner.commitRendererAttachment()
                expect(attached).to(beTrue())
                let persisted = try XCTUnwrap(durableStore.loadJourney(id: first.id))
                expect(persisted.executionState.pendingPresentation).to(beNil())
                expect(persisted.executionState.postPresentationContinuation).toNot(beNil())

                let restoredJourney = Journey(snapshot: persisted)
                let restored = makeRunner(
                    journey: restoredJourney,
                    experience: experience,
                    content: content
                )
                _ = await restored.handleRuntimeReady()
                expect(mocks.eventLog.trackedEvents.map(\.name).filter {
                    $0 == "after_attached_crash"
                }).to(haveCount(1))
            }

            it("runs initial screen lifecycle before the durable post-attach tail across a pause") {
                let flowId = "flow-pre-mount-lifecycle-pause"
                let document = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .navigate(.init(screenId: "screen-selected", transition: nil)),
                        .sendEvent(.init(eventName: "after_lifecycle_tail")),
                    ],
                    handlers: [
                        "screen-selected": [
                            .init(
                                id: "initial-screen-shown",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .delay(.init(durationMs: 1_000)),
                                    .sendEvent(.init(eventName: "lifecycle_first")),
                                ]
                            )
                        ]
                    ],
                    screens: [JourneyScreen(id: "screen-selected")]
                )
                let content = Experience.test(journey: document, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: content
                )

                guard case .present = await runner.advanceUntilPresentation() else {
                    fail("expected presentation commit")
                    return
                }
                let attached = await runner.commitRendererAttachment()
                expect(attached).to(beTrue())
                guard case .paused = await runner.handleScreenChanged("screen-selected") else {
                    fail("expected initial lifecycle pause")
                    return
                }
                _ = await runner.handleRuntimeReady()
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain("lifecycle_first"))
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain("after_lifecycle_tail"))

                _ = await runner.resumePendingAction(reason: .timer, event: nil)
                let relevant = mocks.eventLog.trackedEvents.map(\.name).filter {
                    $0 == "lifecycle_first" || $0 == "after_lifecycle_tail"
                }
                expect(relevant).to(equal([
                    "lifecycle_first",
                    "after_lifecycle_tail",
                ]))
            }

            it("does not replay a durable pre-presentation transition after a crash") {
                let flowId = "flow-pre-mount-transition-crash"
                let document = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .navigate(.init(
                            nodeId: "node-selected",
                            screenId: "screen-selected",
                            transition: nil
                        ))
                    ],
                    screens: [JourneyScreen(id: "screen-selected")]
                )
                let content = Experience.test(journey: document, products: [])
                let experience = makeExperience(flowId: flowId)
                let first = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let durableStore = MockJourneyStore()
                let firstRunner = makeRunner(
                    journey: first,
                    experience: experience,
                    content: content,
                    persistEntryActionClaim: { snapshot in
                        try? durableStore.saveJourney(snapshot)
                        return true
                    }
                )

                guard case .present = await firstRunner.advanceUntilPresentation() else {
                    fail("expected first presentation commit")
                    return
                }
                let persisted = try XCTUnwrap(durableStore.loadJourney(id: first.id))
                expect(persisted.executionState.currentNodeId).to(equal("node-selected"))
                expect(mocks.eventLog.trackWithResponseCalls.map(\.event).filter {
                    $0 == JourneyEvents.journeyTransition
                }).to(haveCount(1))

                let restored = Journey(snapshot: persisted)
                let restoredRunner = makeRunner(
                    journey: restored,
                    experience: experience,
                    content: content
                )
                guard case .present = await restoredRunner.advanceUntilPresentation() else {
                    fail("expected restored presentation commit")
                    return
                }
                expect(mocks.eventLog.trackWithResponseCalls.map(\.event).filter {
                    $0 == JourneyEvents.journeyTransition
                }).to(haveCount(1))
            }

            it("restores the already-selected condition branch without reevaluating it") {
                let flowId = "flow-pre-mount-selected-branch-crash"
                let document = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .condition(.init(
                            nodeId: "node-condition",
                            branches: [
                                .init(
                                    id: "branch-a",
                                    label: nil,
                                    condition: TestIRBuilder.userProperty("route", equals: "a"),
                                    actions: [
                                        .navigate(.init(
                                            nodeId: "node-a",
                                            screenId: "screen-a",
                                            transition: nil
                                        ))
                                    ]
                                )
                            ],
                            defaultActions: [
                                .navigate(.init(
                                    nodeId: "node-b",
                                    screenId: "screen-b",
                                    transition: nil
                                ))
                            ]
                        ))
                    ],
                    screens: [
                        JourneyScreen(id: "screen-a"),
                        JourneyScreen(id: "screen-b"),
                    ]
                )
                let content = Experience.test(journey: document, products: [])
                let experience = makeExperience(flowId: flowId)
                let first = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                mocks.identityService.setUserProperties(["route": "a"])
                let durableStore = MockJourneyStore()
                let persists = LockedCounter()
                let firstRunner = makeRunner(
                    journey: first,
                    experience: experience,
                    content: content,
                    persistEntryActionClaim: { snapshot in
                        try? durableStore.saveJourney(snapshot)
                        return persists.increment() != 3
                    }
                )

                guard case .exited(.error)? = await firstRunner.advanceUntilPresentation() else {
                    fail("expected the simulated crash boundary to stop execution")
                    return
                }
                let persisted = try XCTUnwrap(durableStore.loadJourney(id: first.id))
                expect(persisted.executionState.currentNodeId).to(equal("node-condition"))
                expect(persisted.executionState.prePresentationContinuation).toNot(beNil())
                mocks.identityService.setUserProperties(["route": "b"])

                let restored = Journey(snapshot: persisted)
                let restoredRunner = makeRunner(
                    journey: restored,
                    experience: experience,
                    content: content
                )
                guard case .present(let commit) =
                    await restoredRunner.advanceUntilPresentation() else {
                    fail("expected the durably selected branch to present")
                    return
                }
                expect(commit.screenId).to(equal("screen-a"))
                let transitionNodeIds = mocks.eventLog.trackWithResponseCalls
                    .filter { $0.event == JourneyEvents.journeyTransition }
                    .compactMap { $0.properties?["to_node"] as? String }
                expect(transitionNodeIds).to(equal(["node-condition", "node-a"]))
                expect(transitionNodeIds).toNot(contain("node-b"))
            }

            it("selects the only signed screen when no entry handler exists") {
                let flowId = "flow-pre-mount-one-screen-fallback"
                let document = makeJourneyDocument(
                    flowId: flowId,
                    screens: [JourneyScreen(id: "only-screen")]
                )
                let content = Experience.test(journey: document, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: content
                )

                guard case .present(let commit) = await runner.advanceUntilPresentation() else {
                    fail("expected one-screen presentation commit")
                    return
                }
                expect(commit.screenId).to(equal("only-screen"))
            }

            it("does not erase concurrent journey state while attachment persistence is suspended") {
                let flowId = "flow-pre-mount-attach-cas"
                let document = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .navigate(.init(
                            nodeId: "node-attach-cas",
                            screenId: "screen-selected",
                            transition: nil
                        ))
                    ],
                    screens: [JourneyScreen(id: "screen-selected")]
                )
                let content = Experience.test(journey: document, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let attempts = LockedCounter()
                let gate = AsyncTestGate()
                let durableStore = MockJourneyStore()
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: content,
                    persistEntryActionClaim: { snapshot in
                        try? durableStore.saveJourney(snapshot)
                        if attempts.increment() == 3 { await gate.suspend() }
                        return true
                    }
                )
                guard case .present = await runner.advanceUntilPresentation() else {
                    fail("expected presentation commit")
                    return
                }

                let attach = Task { await runner.commitRendererAttachment() }
                await gate.waitUntilEntered()
                await journey.setContext(
                    "concurrent",
                    value: AnyCodable("retained"),
                    at: Date()
                )
                gate.release()

                let attached = await attach.value
                expect(attached).to(beFalse())
                let live = await journey.snapshot()
                expect(live.context["concurrent"]?.value as? String)
                    .to(equal("retained"))
                expect(durableStore.loadJourney(id: journey.id)?.context["concurrent"]?.value as? String)
                    .to(equal("retained"))
            }

            it("does not emit a transition or erase state when its cursor checkpoint loses a CAS") {
                let flowId = "flow-pre-mount-transition-cas"
                let document = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .navigate(.init(
                            nodeId: "node-transition-cas",
                            screenId: "screen-selected",
                            transition: nil
                        ))
                    ],
                    screens: [JourneyScreen(id: "screen-selected")]
                )
                let content = Experience.test(journey: document, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let attempts = LockedCounter()
                let gate = AsyncTestGate()
                let durableStore = MockJourneyStore()
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: content,
                    persistEntryActionClaim: { snapshot in
                        try? durableStore.saveJourney(snapshot)
                        if attempts.increment() == 2 { await gate.suspend() }
                        return true
                    }
                )

                let advance = Task { await runner.advanceUntilPresentation() }
                await gate.waitUntilEntered()
                await journey.setContext(
                    "concurrent",
                    value: AnyCodable("retained"),
                    at: Date()
                )
                gate.release()
                _ = await advance.value

                let live = await journey.snapshot()
                expect(live.context["concurrent"]?.value as? String)
                    .to(equal("retained"))
                expect(durableStore.loadJourney(id: journey.id)?.context["concurrent"]?.value as? String)
                    .to(equal("retained"))
                expect(mocks.eventLog.trackWithResponseCalls.map(\.event))
                    .toNot(contain(JourneyEvents.journeyTransition))
            }

            it("merges concurrent state while durably consuming the post-attach tail") {
                let flowId = "flow-pre-mount-postattach-cas"
                let document = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .navigate(.init(screenId: "screen-selected", transition: nil)),
                        .sendEvent(.init(eventName: "postattach_once")),
                    ],
                    screens: [JourneyScreen(id: "screen-selected")]
                )
                let content = Experience.test(journey: document, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let attempts = LockedCounter()
                let gate = AsyncTestGate()
                let durableStore = MockJourneyStore()
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: content,
                    persistEntryActionClaim: { snapshot in
                        try? durableStore.saveJourney(snapshot)
                        if attempts.increment() == 3 { await gate.suspend() }
                        return true
                    }
                )
                guard case .present = await runner.advanceUntilPresentation() else {
                    fail("expected presentation commit")
                    return
                }
                let attached = await runner.commitRendererAttachment()
                expect(attached).to(beTrue())

                let ready = Task { await runner.handleRuntimeReady() }
                await gate.waitUntilEntered()
                await journey.setContext(
                    "concurrent",
                    value: AnyCodable("retained"),
                    at: Date()
                )
                try? durableStore.saveJourney(await journey.snapshot())
                gate.release()
                _ = await ready.value

                let live = await journey.snapshot()
                let stored = try XCTUnwrap(durableStore.loadJourney(id: journey.id))
                expect(live.context["concurrent"]?.value as? String)
                    .to(equal("retained"))
                expect(stored.context["concurrent"]?.value as? String)
                    .to(equal("retained"))
                expect(live.executionState.postPresentationContinuation).to(beNil())
                expect(stored.executionState.postPresentationContinuation).to(beNil())
                expect(mocks.eventLog.trackedEvents.map(\.name).filter {
                    $0 == "postattach_once"
                }).to(haveCount(1))
            }

            it("pauses on entry delay") {
                let flowId = "flow-delay"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .delay(DelayAction(durationMs: 5000))
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let outcome = await runner.handleRuntimeReady()

                var paused = false
                if case .paused(let pending) = outcome {
                    paused = (pending.kind == .delay)
                }

                expect(paused).to(beTrue())
                let state = await journey.snapshot()
                expect(state.executionState.pendingAction?.kind).to(equal(.delay))
            }

            it("claims entry actions once across concurrent runtime-ready calls") {
                let flowId = "flow-concurrent-entry"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .sendEvent(SendEventAction(eventName: "entry_once"))
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )

                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<20 {
                        group.addTask { _ = await runner.handleRuntimeReady() }
                    }
                }

                expect(mocks.eventLog.trackedEvents.map(\.name).filter {
                    $0 == "entry_once"
                }).to(haveCount(1))
            }

            it("dispatches the canonical signed journey-started entry handler before fallback") { @MainActor in
                let flowId = "flow-signed-journey-entry"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "signed-entry",
                                eventName: SystemEventNames.journeyStarted,
                                actions: [
                                    .navigate(NavigateAction(
                                        screenId: "screen-authored-entry",
                                        transition: nil
                                    ))
                                ]
                            ),
                            JourneyEventHandler(
                                id: "competing-app-opened",
                                eventName: SystemEventNames.appOpened,
                                actions: [
                                    .navigate(NavigateAction(
                                        screenId: "screen-fallback",
                                        transition: nil
                                    ))
                                ]
                            ),
                        ]
                    ],
                    screens: [
                        JourneyScreen(id: "screen-fallback"),
                        JourneyScreen(id: "screen-authored-entry"),
                    ]
                )
                let experience = Experience(
                    id: "test-experience",
                    versionId: "test-version",
                    name: "signed entry",
                    reentry: .everyTime,
                    publishedAt: "2026-08-12T00:00:00Z",
                    trigger: .event(.init(eventName: "external_trigger", condition: nil)),
                    goal: nil,
                    exitPolicy: nil,
                    conversionAnchor: nil,
                    experienceType: nil,
                    journey: screens
                )
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: experience
                )
                let controller = SpyExperienceViewController(content: experience)
                await runner.attach(viewController: controller)

                _ = await runner.handleRuntimeReady()
                _ = await runner.handleRuntimeReady()

                await polling(expect(controller.navigationRequests.map(\.screenId)))
                    .value.toEventually(equal(["screen-authored-entry"]))
            }

            it("consumes a pending action once across concurrent resumes") {
                let flowId = "flow-concurrent-resume"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .delay(DelayAction(durationMs: 1_000)),
                        .sendEvent(SendEventAction(eventName: "resume_once")),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )
                guard case .paused = await runner.handleRuntimeReady() else {
                    fail("Expected entry delay to pause")
                    return
                }

                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<20 {
                        group.addTask {
                            _ = await runner.resumePendingAction(
                                reason: .timer,
                                event: nil
                            )
                        }
                    }
                }

                expect(mocks.eventLog.trackedEvents.map(\.name).filter {
                    $0 == "resume_once"
                }).to(haveCount(1))
            }

            it("emits stable node transitions once across a paused action resume") {
                let flowId = "flow-node-transitions"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .delay(DelayAction(
                            nodeId: "either.delay",
                            durationMs: 1_000
                        )),
                        .sendEvent(SendEventAction(
                            nodeId: "either.send-event",
                            eventName: "after_delay"
                        )),
                        .exit(ExitAction(
                            nodeId: "either.exit",
                            reason: "completed"
                        )),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )
                let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
                mocks.dateProvider.setCurrentDate(startedAt)

                let paused = await runner.handleRuntimeReady()
                guard case .paused = paused else {
                    fail("Expected the delay to pause once")
                    return
                }
                mocks.dateProvider.setCurrentDate(
                    startedAt.addingTimeInterval(1)
                )
                let outcome = await runner.resumePendingAction(
                    reason: .timer,
                    event: nil
                )

                guard case .exited(.completed)? = outcome else {
                    fail("Expected the resumed action chain to complete")
                    return
                }
                let transitions = mocks.eventLog.trackWithResponseCalls.filter {
                    $0.event == JourneyEvents.journeyTransition
                }
                expect(transitions.compactMap {
                    $0.properties?["to_node"] as? String
                }).to(equal([
                    "either.delay",
                    "either.send-event",
                    "either.exit",
                ]))
                expect(transitions.compactMap {
                    $0.properties?["from_node"] as? String
                }).to(equal([
                    "either.delay",
                    "either.send-event",
                ]))
            }

            it("executes the either-vocabulary golden fixture exactly") {
                let fixture = try loadFixtureObject(
                    "journeys/conformance/either-vocabulary.json"
                )
                let actions = try JSONDecoder().decode(
                    [JourneyAction].self,
                    from: JSONSerialization.data(
                        withJSONObject: fixture["actions"] as Any
                    )
                )
                let assignment = try JSONDecoder().decode(
                    ExperimentAssignment.self,
                    from: JSONSerialization.data(
                        withJSONObject: fixture["experimentAssignment"] as Any
                    )
                )
                let expected = fixture["expected"] as! [String: Any]
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [
                    .withInternetDateTime,
                    .withFractionalSeconds,
                ]
                guard let now = formatter.date(
                    from: fixture["now"] as! String
                ) else {
                    fail("Expected a valid fixture timestamp")
                    return
                }
                mocks.dateProvider.setCurrentDate(now)
                mocks.profileService.setProfileResponse(ProfileResponse(
                    experiences: [],
                    segments: [],
                    pinnedVersions: [],
                    assetBaseUrl: "https://assets.nuxie.ai/",
                    userProperties: nil,
                    experiments: [
                        assignment.experimentKey: assignment
                    ],
                    features: nil
                ))
                _ = try await mocks.profileService.refetchProfile(
                    distinctId: "user-1"
                )

                let flowId = "flow-either-vocabulary-golden"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: actions
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: now
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )

                let outcome = await runner.handleRuntimeReady()

                guard case .exited(let reason)? = outcome else {
                    fail("Expected the golden journey to exit")
                    return
                }
                let transitionNodeIds = mocks.eventLog
                    .trackWithResponseCalls
                    .filter {
                        $0.event == JourneyEvents.journeyTransition
                    }
                    .compactMap {
                        $0.properties?["to_node"] as? String
                    }
                expect(transitionNodeIds).to(equal(
                    expected["transitionNodeIds"] as? [String]
                ))

                let expectedEventNames = expected["eventNames"] as! [String]
                expect(
                    mocks.eventLog.trackedEvents
                        .map(\.name)
                        .filter(expectedEventNames.contains)
                ).to(equal(expectedEventNames))
                expect(
                    mocks.identityService.getUserProperties() as NSDictionary
                ).to(equal(
                    expected["customerUpdates"] as? NSDictionary
                ))
                let milestones = mocks.eventLog.trackWithResponseCalls
                    .filter { $0.event == JourneyEvents.journeyMilestone }
                    .compactMap {
                        $0.properties?["milestone_id"] as? String
                    }
                expect(milestones).to(equal(
                    expected["milestones"] as? [String]
                ))
                let exposures = mocks.eventLog.trackedEvents
                    .filter {
                        $0.name == JourneyEvents.experimentExposure
                    }
                    .compactMap { event -> [String: String]? in
                        guard
                            let experimentId = event.properties?[
                                "experiment_key"
                            ] as? String,
                            let variantId = event.properties?[
                                "variant_key"
                            ] as? String
                        else {
                            return nil
                        }
                        return [
                            "experimentId": experimentId,
                            "variantId": variantId,
                        ]
                    }
                expect(exposures as NSArray).to(equal(
                    expected["exposures"] as? NSArray
                ))
                expect(reason.rawValue).to(equal(
                    expected["exitReason"] as? String
                ))
            }

            it("applies initial view model state through the native controller API") { @MainActor in
                let flowId = "flow-view-model-init-v2"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "title": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("Hello"),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    viewModels: [viewModel],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: "vm-1", defaultInstanceId: nil),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleRuntimeReady()

                await polling(expect(controller.viewModelSnapshots.count)).value.toEventually(equal(1))
                let snapshot = controller.viewModelSnapshots.first
                expect(snapshot?.screenId).to(beNil())
                expect(snapshot?.snapshot.viewModelInstances.first?.viewModelId).to(equal("VM"))
            }

            it("dispatches journey event handlers") { @MainActor in
                let flowId = "flow-global-event"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "handler-promo-ready",
                                eventName: "promo_ready",
                                actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))]
                            )
                        ]
                    ],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                        JourneyScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                var state = JourneySnapshot(experience: experience, distinctId: "user-1", now: Date())
                state.executionState.currentScreenId = "screen-1"
                let journey = Journey(snapshot: state)
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: "promo_ready",
                        distinctId: "user-1",
                        properties: [:]
                    )
                )

                await polling(expect(controller.navigationRequests.map(\.screenId))).value.toEventually(contain("screen-2"))
            }

            it("routes navigation dismissal only when the coordinator reports hidden") { @MainActor in
                let flowId = "flow-navigation-dismiss-screen-host"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        "screen-1": [
                            JourneyEventHandler(
                                id: "navigate",
                                eventName: "continue_tapped",
                                actions: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))]
                            ),
                            JourneyEventHandler(
                                id: "track-dismissal",
                                eventName: SystemEventNames.screenDismissed,
                                actions: [
                                    .sendEvent(SendEventAction(
                                        eventName: "screen_host_dismissed",
                                        properties: nil
                                    ))
                                ]
                            ),
                        ]
                    ],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                        JourneyScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                var state = JourneySnapshot(experience: experience, distinctId: "user-1", now: Date())
                state.executionState.currentScreenId = "screen-1"
                let journey = Journey(snapshot: state)
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.dispatchScreenEvent(
                    NuxieEvent(
                        name: "continue_tapped",
                        distinctId: "user-1",
                        properties: [:]
                    ),
                    screenId: "screen-1",
                    componentId: "button-1",
                    instanceId: nil
                )

                await polling(expect(controller.navigationRequests.map(\.screenId))).value.toEventually(contain("screen-2"))
                expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("screen_host_dismissed"))

                _ = await runner.handleScreenDismissed(
                    "screen-1",
                    revealingScreenId: nil,
                    method: "navigate"
                )

                expect(mocks.eventLog.trackedEvents.map(\.name)).to(contain("screen_host_dismissed"))
            }

            it("does not dispatch a handler-only screen lifecycle contract") {
                let flowId = "flow-handler-only-screen-lifecycle"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        "screen-1": [
                            JourneyEventHandler(
                                id: "track-screen-shown",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .sendEvent(SendEventAction(
                                        eventName: "handler_only_screen_shown",
                                        properties: nil
                                    ))
                                ]
                            )
                        ]
                    ],
                    synthesizeHandlerEvents: false
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                _ = await runner.handleScreenChanged("screen-1")

                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain("handler_only_screen_shown"))
            }

            it("prefers the screen lifecycle contract without also dispatching the legacy global host") {
                let flowId = "flow-screen-lifecycle-host-precedence"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        "screen-1": [
                            JourneyEventHandler(
                                id: "track-screen-host",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .sendEvent(SendEventAction(
                                        eventName: "screen_host_shown",
                                        properties: nil
                                    ))
                                ]
                            )
                        ],
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "track-global-host",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .sendEvent(SendEventAction(
                                        eventName: "global_host_shown",
                                        properties: nil
                                    ))
                                ]
                            )
                        ],
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                _ = await runner.handleScreenChanged("screen-1")

                let trackedNames = mocks.eventLog.trackedEvents.map(\.name)
                expect(trackedNames.filter { $0 == "screen_host_shown" }).to(haveCount(1))
                expect(trackedNames).toNot(contain("global_host_shown"))
            }

            it("matches the language-neutral handler-host dispatch vectors") {
                let fixtureURL = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("fixtures/journeys/handler-host-dispatch/lifecycle.json")
                let fixture = try JSONSerialization.jsonObject(
                    with: Data(contentsOf: fixtureURL)
                ) as! [String: Any]
                expect(fixture["version"] as? Int).to(equal(1))

                for vector in fixture["vectors"] as! [[String: Any]] {
                    await mocks.resetAll()

                    let name = vector["name"] as! String
                    let eventName = vector["event"] as! String
                    let screenId = vector["screenId"] as! String
                    let declarations = vector["screenDeclarations"] as! [String]
                    let journeyDeclarations = vector["journeyDeclarations"] as? [String] ?? []
                    let handlerVectors = vector["handlers"] as! [[String: String]]
                    let expectedMarkers = vector["expectedMarkers"] as! [String]
                    var events: JourneyEventMap = [:]
                    if !declarations.isEmpty {
                        events[screenId] = declarations.enumerated().map { index, declaration in
                            EventDeclaration(
                                id: "\(name)-declaration-\(index)",
                                eventName: declaration
                            )
                        }
                    }
                    if !journeyDeclarations.isEmpty {
                        events[JourneyDocument.journeyEventHostKey] =
                            journeyDeclarations.enumerated().map { index, declaration in
                                EventDeclaration(
                                    id: "\(name)-journey-declaration-\(index)",
                                    eventName: declaration
                                )
                            }
                    }
                    var handlers: JourneyHandlerMap = [:]
                    for (index, handler) in handlerVectors.enumerated() {
                        let host = handler["host"]!
                        handlers[host, default: []].append(
                            JourneyEventHandler(
                                id: "\(name)-handler-\(index)",
                                eventName: handler["event"]!,
                                actions: [
                                    .sendEvent(
                                        SendEventAction(
                                            eventName: handler["marker"]!,
                                            properties: nil
                                        )
                                    )
                                ]
                            )
                        )
                    }
                    let flowId = "fixture-handler-host-\(name)"
                    let screens = makeJourneyDocument(
                        flowId: flowId,
                        events: events,
                        handlers: handlers,
                        synthesizeHandlerEvents: false
                    )
                    let flow = Experience.test(journey: screens, products: [])
                    let experience = makeExperience(flowId: flowId)
                    let journey = Journey(
                        experience: experience,
                        distinctId: "fixture-user",
                        now: Date()
                    )
                    let runner = makeRunner(
                        journey: journey,
                        experience: experience,
                        content: flow
                    )

                    switch (vector["dispatch"] as? String, eventName) {
                    case ("journey", _):
                        _ = await runner.dispatchEventTrigger(
                            NuxieEvent(
                                name: eventName,
                                distinctId: "fixture-user",
                                properties: [:]
                            )
                        )
                    case (_, SystemEventNames.screenShown):
                        _ = await runner.handleScreenChanged(screenId)
                    case (_, SystemEventNames.screenDismissed):
                        await journey.update {
                            $0.executionState.currentScreenId = screenId
                        }
                        _ = await runner.handleScreenDismissed(
                            screenId,
                            revealingScreenId: nil,
                            method: "fixture"
                        )
                    default:
                        _ = await runner.dispatchScreenEvent(
                            NuxieEvent(
                                name: eventName,
                                distinctId: "fixture-user",
                                properties: [:]
                            ),
                            screenId: screenId,
                            componentId: nil,
                            instanceId: nil
                        )
                    }

                    let markerNames = Set(handlerVectors.compactMap { $0["marker"] })
                    let actualMarkers = mocks.eventLog.trackedEvents.map(\.name).filter {
                        markerNames.contains($0)
                    }
                    expect(actualMarkers)
                        .to(equal(expectedMarkers), description: name)
                }
            }

            it("reconciles visible screen state before returning a paused dismiss hook") {
                let flowId = "flow-dismiss-pauses"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        "screen-2": [
                            JourneyEventHandler(
                                id: "screen-dismiss-delay",
                                eventName: SystemEventNames.screenDismissed,
                                actions: [.delay(DelayAction(durationMs: 5000))]
                            )
                        ]
                    ],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                        JourneyScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                await journey.update {
                    $0.executionState.currentScreenId = "screen-2"
                    $0.executionState.navigationStack = ["screen-1"]
                }
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let outcome = await runner.handleScreenDismissed(
                    "screen-2",
                    revealingScreenId: "screen-1",
                    method: "native_sheet"
                )

                if case .paused(let pending) = outcome {
                    expect(pending.kind).to(equal(.delay))
                } else {
                    fail("Expected the screen_dismissed handler to pause")
                }
                let state = await journey.snapshot()
                expect(state.executionState.currentScreenId).to(equal("screen-1"))
                expect(state.executionState.navigationStack).to(beEmpty())
            }

            it("waits for the revealed active edge before dispatching screen shown") {
                let flowId = "flow-sheet-lifecycle-edges"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        "screen-1": [
                            JourneyEventHandler(
                                id: "shown-marker",
                                eventName: SystemEventNames.screenShown,
                                actions: [.sendEvent(SendEventAction(
                                    eventName: "shown_marker",
                                    properties: nil
                                ))]
                            )
                        ],
                        "screen-2": [
                            JourneyEventHandler(
                                id: "dismissed-marker",
                                eventName: SystemEventNames.screenDismissed,
                                actions: [.sendEvent(SendEventAction(
                                    eventName: "dismissed_marker",
                                    properties: nil
                                ))]
                            )
                        ],
                    ],
                    screens: [
                        JourneyScreen(id: "screen-1"),
                        JourneyScreen(id: "screen-2"),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                await journey.update {
                    $0.executionState.currentScreenId = "screen-2"
                    $0.executionState.navigationStack = ["screen-1"]
                }
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                _ = await runner.handleScreenDismissed(
                    "screen-2",
                    revealingScreenId: "screen-1",
                    method: "native_sheet"
                )

                expect(mocks.eventLog.trackedEvents.map(\.name)).to(contain("dismissed_marker"))
                expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("shown_marker"))

                _ = await runner.handleScreenChanged("screen-1")

                expect(mocks.eventLog.trackedEvents.map(\.name)).to(contain("shown_marker"))
            }

            it("does not echo renderer-origin trigger did_set changes back into the renderer") { @MainActor in
                let flowId = "flow-rive-trigger-no-echo"
                let path = vmPath("pulse")
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "pulse": ViewModelProperty(
                            type: .trigger,
                            propertyId: 1,
                            defaultValue: AnyCodable(0),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    viewModels: [viewModel],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: "vm-1", defaultInstanceId: nil)
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                await journey.update { $0.executionState.currentScreenId = "screen-1" }
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                for source in ["rive", "runtime"] {
                    _ = await runner.handleDidSet(
                        path: path,
                        value: true,
                        source: source,
                        screenId: "screen-1",
                        instanceId: nil,
                        isTrigger: true
                    )
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }

                expect(mocks.eventLog.trackedEvents.map(\.name)).toNot(contain("rive_trigger_seen"))
                expect(controller.viewModelTriggers).to(beEmpty())
                let state = await journey.snapshot()
                let values = state.executionState.viewModelSnapshot?.viewModelInstances.first?.values
                expect(values?["pulse"]?.value as? Int).to(equal(0))
            }

            it("applies set_view_model on screen shown and emits patch") { @MainActor in
                let flowId = "flow-vm"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "flag": ViewModelProperty(
                            type: .boolean,
                            propertyId: 1,
                            defaultValue: AnyCodable(false),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "screen-shown-set-flag",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .setViewModel(SetViewModelAction(
                                        path: vmPath("flag"),
                                        value: AnyCodable(["literal": true] as [String: Any])
                                    ))
                                ]
                            )
                        ]
                    ],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                let state = await journey.snapshot()
                let snapshot = state.executionState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let flag = values?["flag"]?.value as? Bool
                expect(flag).to(equal(true))

                await polling(expect(controller.viewModelValues.map(\.path.normalizedPath))).value.toEventually(
                    contain(vmPath("flag").normalizedPath)
                )
            }

            it("dispatches structured screen events from the native renderer event path") { @MainActor in
                let flowId = "flow-structured-renderer-event"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    events: [
                        "screen-1": [
                            EventDeclaration(
                                id: "event-purchase-tapped",
                                eventName: "purchase_tapped",
                                payloadSchema: ["productId": .string]
                            )
                        ]
                    ],
                    handlers: [
                        "screen-1": [
                            JourneyEventHandler(
                                id: "handler-purchase-tapped",
                                eventName: "purchase_tapped",
                                actions: [
                                    .navigate(NavigateAction(screenId: "screen-2", transition: nil))
                                ]
                            )
                        ]
                    ],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                        JourneyScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                await journey.update { $0.executionState.currentScreenId = "screen-1" }
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.dispatchScreenEvent(
                    NuxieEvent(
                        name: "purchase_tapped",
                        distinctId: "user-1",
                        properties: ["productId": "prod_1"]
                    ),
                    screenId: "screen-1",
                    componentId: "button-1",
                    instanceId: nil
                )

                await polling(expect(controller.navigationRequests.map(\.screenId))).value.toEventually(contain("screen-2"))
            }

            it("projects paywall purchase status through the native view model patch path") { @MainActor in
                let flowId = "flow-purchase-status"
                let viewModel = makePaywallViewModel()
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "purchase-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .purchase(PurchaseAction(
                                        placementIndex: AnyCodable(0),
                                        productId: AnyCodable("prod_1")
                                    ))
                                ]
                            )
                        ]
                    ],
                    viewModels: [viewModel]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                let statusPath = "paywall/purchase/status"
                let errorPath = "paywall/purchase/errorCode"
                let invocationPath = "paywall/purchase/invocationId"
                let statusPatchPath = VmPathRef(path: statusPath)

                let initialStatus = await snapshotValue(journey, path: statusPath) as? String
                let initialError = await snapshotValue(journey, path: errorPath) as? String
                let initialInvocation = await snapshotValue(journey, path: invocationPath) as? String
                expect(initialStatus).to(equal("running"))
                expect(initialError).to(equal(""))
                expect(initialInvocation).toNot(beEmpty())
                await polling(expect(controller.viewModelValues.map(\.path.normalizedPath))).value.toEventually(
                    contain(statusPatchPath.normalizedPath)
                )

                _ = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.purchaseCompleted,
                        distinctId: "user-1",
                        properties: ["product_id": "prod_1"]
                    )
                )

                let completedStatus = await snapshotValue(journey, path: statusPath) as? String
                expect(completedStatus).to(equal("success"))
                await polling(expect(controller.viewModelValues.compactMap { request in
                    request.path.normalizedPath == statusPatchPath.normalizedPath ? request.value as? String : nil
                })).value.toEventually(contain("success"))
            }

            it("projects paywall restore status through the native view model patch path") { @MainActor in
                let flowId = "flow-restore-status"
                let viewModel = makePaywallViewModel()
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.restore(RestoreAction())],
                    viewModels: [viewModel]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleRuntimeReady()

                let statusPath = "paywall/restore/status"
                let errorPath = "paywall/restore/errorCode"
                let invocationPath = "paywall/restore/invocationId"
                let statusPatchPath = VmPathRef(path: statusPath)

                let initialStatus = await snapshotValue(journey, path: statusPath) as? String
                let initialError = await snapshotValue(journey, path: errorPath) as? String
                let initialInvocation = await snapshotValue(journey, path: invocationPath) as? String
                expect(initialStatus).to(equal("running"))
                expect(initialError).to(equal(""))
                expect(initialInvocation).toNot(beEmpty())
                await polling(expect(controller.viewModelValues.map(\.path.normalizedPath))).value.toEventually(
                    contain(statusPatchPath.normalizedPath)
                )

                _ = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.restoreNoPurchases,
                        distinctId: "user-1",
                        properties: [:]
                    )
                )

                let completedStatus = await snapshotValue(journey, path: statusPath) as? String
                expect(completedStatus).to(equal("not_found"))
                await polling(expect(controller.viewModelValues.compactMap { request in
                    request.path.normalizedPath == statusPatchPath.normalizedPath ? request.value as? String : nil
                })).value.toEventually(contain("not_found"))
            }

            it("runs the purchase onCompleted outlet and consumes the outcome event") { @MainActor in
                let flowId = "flow-purchase-outlet-completed"
                let viewModel = makePaywallViewModel()
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        "screen-1": [
                            JourneyEventHandler(
                                id: "purchase-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .purchase(PurchaseAction(
                                        placementIndex: AnyCodable(0),
                                        productId: AnyCodable("prod_1"),
                                        onCompleted: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))],
                                        onFailed: [.navigate(NavigateAction(screenId: "screen-3", transition: nil))]
                                    ))
                                ]
                            )
                        ],
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "global-purchase-completed",
                                eventName: SystemEventNames.purchaseCompleted,
                                actions: [.navigate(NavigateAction(screenId: "screen-4", transition: nil))]
                            ),
                        ]
                    ],
                    viewModels: [viewModel],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: "VM", defaultInstanceId: nil),
                        JourneyScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
                        JourneyScreen(id: "screen-3", defaultViewModelName: nil, defaultInstanceId: nil),
                        JourneyScreen(id: "screen-4", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                _ = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.purchaseCompleted,
                        distinctId: "user-1",
                        properties: ["product_id": "prod_1"]
                    )
                )

                await polling(expect(controller.navigationRequests.map(\.screenId))).value.toEventually(contain("screen-2"))
                expect(controller.navigationRequests.map(\.screenId)).toNot(contain("screen-3"))
                expect(controller.navigationRequests.map(\.screenId)).toNot(contain("screen-4"))
            }

            it("transfers ownership from a purchase completion outlet") { @MainActor in
                let flowId = "flow-purchase-outlet-handoff"
                let handoff = HandoffAction(
                    nodeId: "handoff-node",
                    edgeId: "purchase-completed",
                    direction: "device_to_server",
                    toRegionId: "server-region-1",
                    toNodeId: "server-effect"
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        "screen-1": [
                            JourneyEventHandler(
                                id: "purchase-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .purchase(
                                        PurchaseAction(
                                            nodeId: "purchase-node",
                                            placementIndex: AnyCodable(0),
                                            productId: AnyCodable("prod_1"),
                                            onCompleted: [.handoff(handoff)]
                                        )
                                    )
                                ]
                            )
                        ]
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                await journey.update { $0.executionState.regionId = "device-region-1" }
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )
                let controller = SpyExperienceViewController(content: flow)
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")
                let outcome = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.purchaseCompleted,
                        distinctId: "user-1",
                        properties: ["product_id": "prod_1"]
                    )
                )

                guard case .transferred(let transferred)? = outcome else {
                    return fail("Expected purchase outlet handoff")
                }
                expect(transferred.edgeId).to(equal("purchase-completed"))
                let state = await journey.snapshot()
                expect(state.executionState.regionId).to(equal("server-region-1"))
                expect(state.executionState.currentNodeId).to(equal("server-effect"))
                expect(state.executionState.pendingPurchaseOutlets).to(beNil())
            }

            it("routes purchase failure to the onFailed outlet") { @MainActor in
                let flowId = "flow-purchase-outlet-failed"
                let viewModel = makePaywallViewModel()
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "purchase-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .purchase(PurchaseAction(
                                        placementIndex: AnyCodable(0),
                                        productId: AnyCodable("prod_1"),
                                        onCompleted: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))],
                                        onFailed: [.navigate(NavigateAction(screenId: "screen-3", transition: nil))]
                                    ))
                                ]
                            )
                        ]
                    ],
                    viewModels: [viewModel],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: "VM", defaultInstanceId: nil),
                        JourneyScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
                        JourneyScreen(id: "screen-3", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                _ = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.purchaseFailed,
                        distinctId: "user-1",
                        properties: ["product_id": "prod_1", "error_code": "payment_failed"]
                    )
                )

                await polling(expect(controller.navigationRequests.map(\.screenId))).value.toEventually(contain("screen-3"))
                expect(controller.navigationRequests.map(\.screenId)).toNot(contain("screen-2"))
            }

            it("falls back to global handlers when purchase has no outlets") { @MainActor in
                let flowId = "flow-purchase-no-outlets"
                let viewModel = makePaywallViewModel()
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "purchase-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .purchase(PurchaseAction(
                                        placementIndex: AnyCodable(0),
                                        productId: AnyCodable("prod_1")
                                    ))
                                ]
                            ),
                            JourneyEventHandler(
                                id: "global-purchase-completed",
                                eventName: SystemEventNames.purchaseCompleted,
                                actions: [.navigate(NavigateAction(screenId: "screen-4", transition: nil))]
                            ),
                        ]
                    ],
                    viewModels: [viewModel],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: "VM", defaultInstanceId: nil),
                        JourneyScreen(id: "screen-4", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                _ = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.purchaseCompleted,
                        distinctId: "user-1",
                        properties: ["product_id": "prod_1"]
                    )
                )

                await polling(expect(controller.navigationRequests.map(\.screenId))).value.toEventually(contain("screen-4"))
            }

            it("runs the restore onRestored outlet and consumes the outcome event") { @MainActor in
                let flowId = "flow-restore-outlet"
                let viewModel = makePaywallViewModel()
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "restore-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .restore(RestoreAction(
                                        onRestored: [.navigate(NavigateAction(screenId: "screen-2", transition: nil))],
                                        onNoPurchases: [.navigate(NavigateAction(screenId: "screen-3", transition: nil))]
                                    ))
                                ]
                            ),
                            JourneyEventHandler(
                                id: "global-restore-completed",
                                eventName: SystemEventNames.restoreCompleted,
                                actions: [.navigate(NavigateAction(screenId: "screen-4", transition: nil))]
                            ),
                        ]
                    ],
                    viewModels: [viewModel],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: "VM", defaultInstanceId: nil),
                        JourneyScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
                        JourneyScreen(id: "screen-3", defaultViewModelName: nil, defaultInstanceId: nil),
                        JourneyScreen(id: "screen-4", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                _ = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.restoreCompleted,
                        distinctId: "user-1",
                        properties: [:]
                    )
                )

                await polling(expect(controller.navigationRequests.map(\.screenId))).value.toEventually(contain("screen-2"))
                expect(controller.navigationRequests.map(\.screenId)).toNot(contain("screen-3"))
                expect(controller.navigationRequests.map(\.screenId)).toNot(contain("screen-4"))
            }

            it("transfers ownership from a restore completion outlet") { @MainActor in
                let flowId = "flow-restore-outlet-handoff"
                let handoff = HandoffAction(
                    nodeId: "restore-handoff-node",
                    edgeId: "restore-completed",
                    direction: "device_to_server",
                    toRegionId: "server-region-restore",
                    toNodeId: "server-restore-effect"
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        "screen-1": [
                            JourneyEventHandler(
                                id: "restore-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .restore(
                                        RestoreAction(
                                            nodeId: "restore-node",
                                            onRestored: [.handoff(handoff)]
                                        )
                                    )
                                ]
                            )
                        ]
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                await journey.update { $0.executionState.regionId = "device-region-1" }
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )
                let controller = SpyExperienceViewController(content: flow)
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")
                let outcome = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.restoreCompleted,
                        distinctId: "user-1",
                        properties: [:]
                    )
                )

                guard case .transferred(let transferred)? = outcome else {
                    return fail("Expected restore outlet handoff")
                }
                expect(transferred.edgeId).to(equal("restore-completed"))
                let state = await journey.snapshot()
                expect(state.executionState.regionId).to(equal("server-region-restore"))
                expect(state.executionState.currentNodeId).to(equal("server-restore-effect"))
                expect(state.executionState.pendingRestoreOutlets).to(beNil())
            }

            it("rejects trailing outlet work after a nested handoff") { @MainActor in
                let flowId = "flow-invalid-outlet-handoff-chain"
                let handoff = HandoffAction(
                    nodeId: "terminal-handoff-node",
                    edgeId: "restore-completed",
                    direction: "device_to_server",
                    toRegionId: "server-region-terminal",
                    toNodeId: "server-terminal-node"
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        "screen-1": [
                            JourneyEventHandler(
                                id: "restore-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .restore(
                                        RestoreAction(
                                            nodeId: "restore-node",
                                            onRestored: [
                                                .condition(
                                                    ConditionAction(
                                                        branches: [
                                                            ConditionBranch(
                                                                id: "handoff-branch",
                                                                label: nil,
                                                                condition: TestIRBuilder.alwaysTrue(),
                                                                actions: [.handoff(handoff)]
                                                            )
                                                        ]
                                                    )
                                                ),
                                                .sendEvent(
                                                    SendEventAction(
                                                        eventName: "trailing_device_work",
                                                        properties: nil
                                                    )
                                                ),
                                            ]
                                        )
                                    )
                                ]
                            )
                        ]
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                await journey.update { $0.executionState.regionId = "device-region-1" }
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )
                let controller = SpyExperienceViewController(content: flow)
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")
                let outcome = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.restoreCompleted,
                        distinctId: "user-1",
                        properties: [:]
                    )
                )

                guard case .exited(.error)? = outcome else {
                    return fail("Expected invalid outlet handoff chain to fail")
                }
                let state = await journey.snapshot()
                expect(state.executionState.regionId).to(equal("device-region-1"))
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain("trailing_device_work"))
            }

            it("preserves outlet transfer terminality across pause and resume") { @MainActor in
                let flowId = "flow-paused-outlet-handoff-chain"
                let handoff = HandoffAction(
                    nodeId: "paused-handoff-node",
                    edgeId: "restore-completed",
                    direction: "device_to_server",
                    toRegionId: "server-region-paused",
                    toNodeId: "server-paused-node"
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        "screen-1": [
                            JourneyEventHandler(
                                id: "restore-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .restore(
                                        RestoreAction(
                                            nodeId: "restore-node",
                                            onRestored: [
                                                .delay(DelayAction(durationMs: 1)),
                                                .handoff(handoff),
                                                .sendEvent(
                                                    SendEventAction(
                                                        eventName: "trailing_resumed_device_work",
                                                        properties: nil
                                                    )
                                                ),
                                            ]
                                        )
                                    )
                                ]
                            )
                        ]
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                await journey.update { $0.executionState.regionId = "device-region-1" }
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )
                let controller = SpyExperienceViewController(content: flow)
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")
                let pausedOutcome = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.restoreCompleted,
                        distinctId: "user-1",
                        properties: [:]
                    )
                )

                guard case .paused(let pending)? = pausedOutcome else {
                    return fail("Expected restore outlet delay to pause")
                }
                expect(pending.requiresTerminalTransfer).to(beTrue())

                let resumedOutcome = await runner.resumePendingAction(
                    reason: .timer,
                    event: nil
                )
                guard case .exited(.error)? = resumedOutcome else {
                    return fail("Expected resumed invalid outlet chain to fail")
                }
                let state = await journey.snapshot()
                expect(state.executionState.regionId).to(equal("device-region-1"))
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain("trailing_resumed_device_work"))
            }

            it("synthesizes set_response_field from the $response_set built-in") {
                let flowId = "flow-response-set"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    responseSchemas: [JourneyResponseSchema(responseSchemaId: "rs-1")]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                await journey.update { $0.executionState.currentScreenId = "screen-1" }
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                _ = await runner.dispatchScreenEvent(
                    NuxieEvent(
                        name: SystemEventNames.responseSet,
                        distinctId: "user-1",
                        properties: ["field": "goal", "value": "lose_weight"]
                    ),
                    screenId: "screen-1",
                    componentId: nil,
                    instanceId: nil
                )

                let call = await mocks.nuxieApi.lastResponseFieldCall
                expect(call?.responseSchemaId).to(equal("rs-1"))
                expect(call?.key).to(equal("goal"))
                expect(call?.value as? String).to(equal("lose_weight"))
            }

            it("drops $response_set when the flow declares no response schema") {
                let flowId = "flow-response-set-no-schema"
                let screens = makeJourneyDocument(flowId: flowId)
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                await journey.update { $0.executionState.currentScreenId = "screen-1" }
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let outcome = await runner.dispatchScreenEvent(
                    NuxieEvent(
                        name: SystemEventNames.responseSet,
                        distinctId: "user-1",
                        properties: ["field": "goal", "value": "lose_weight"]
                    ),
                    screenId: "screen-1",
                    componentId: nil,
                    instanceId: nil
                )

                expect(outcome).to(beNil())
                let call = await mocks.nuxieApi.lastResponseFieldCall
                expect(call).to(beNil())
            }

            it("handles list_insert and fire_trigger actions") { @MainActor in
                let flowId = "flow-list"
                let listProperty = ViewModelProperty(
                    type: .list,
                    propertyId: 2,
                    defaultValue: AnyCodable([]),
                    required: nil,
                    enumValues: nil,
                    itemType: ViewModelProperty(
                        type: .string,
                        propertyId: 3,
                        defaultValue: nil,
                        required: nil,
                        enumValues: nil,
                        itemType: nil,
                        schema: nil,
                        viewModelId: nil,
                        validation: nil
                    ),
                    schema: nil,
                    viewModelId: nil,
                    validation: nil
                )
                let triggerProperty = ViewModelProperty(
                    type: .trigger,
                    propertyId: 4,
                    defaultValue: nil,
                    required: nil,
                    enumValues: nil,
                    itemType: nil,
                    schema: nil,
                    viewModelId: nil,
                    validation: nil
                )
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "items": listProperty,
                        "pulse": triggerProperty
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "insert-and-fire-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .listInsert(ListInsertAction(
                                        path: vmPath("items"),
                                        index: 0,
                                        value: AnyCodable(["literal": "a"] as [String: Any])
                                    )),
                                    .fireTrigger(FireTriggerAction(path: vmPath("pulse")))
                                ]
                            )
                        ]
                    ],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                var state = await journey.snapshot()
                let snapshot = state.executionState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let items = values?["items"]?.value as? [Any]
                expect(items?.first as? String).to(equal("a"))
                try? await Task.sleep(nanoseconds: 50_000_000)
                state = await journey.snapshot()
                let resetValues = state.executionState.viewModelSnapshot?.viewModelInstances.first?.values
                let pulse = resetValues?["pulse"]?.value as? Int
                expect(pulse).to(equal(0))

                await polling(expect(controller.viewModelListOperations.map(\.operation))).value.toEventually(contain(.insert))
                await polling(expect(controller.viewModelTriggers.map(\.path.normalizedPath))).value.toEventually(
                    contain(vmPath("pulse").normalizedPath)
                )
            }

            it("handles list_move, list_set, and list_clear actions") { @MainActor in
                let flowId = "flow-list-ops"
                let listProperty = ViewModelProperty(
                    type: .list,
                    propertyId: 2,
                    defaultValue: AnyCodable(["a", "b", "c"]),
                    required: nil,
                    enumValues: nil,
                    itemType: ViewModelProperty(
                        type: .string,
                        propertyId: 3,
                        defaultValue: nil,
                        required: nil,
                        enumValues: nil,
                        itemType: nil,
                        schema: nil,
                        viewModelId: nil,
                        validation: nil
                    ),
                    schema: nil,
                    viewModelId: nil,
                    validation: nil
                )
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "items": listProperty
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "list-ops-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    .listMove(ListMoveAction(
                                        path: vmPath("items"),
                                        from: 0,
                                        to: 2
                                    )),
                                    .listSet(ListSetAction(
                                        path: vmPath("items"),
                                        index: 1,
                                        value: AnyCodable(["literal": "z"] as [String: Any])
                                    )),
                                    .listClear(ListClearAction(path: vmPath("items")))
                                ]
                            )
                        ]
                    ],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                let state = await journey.snapshot()
                let snapshot = state.executionState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let items = values?["items"]?.value as? [Any]
                expect(items?.isEmpty).to(equal(true))

                await polling(expect(controller.viewModelListOperations.map(\.operation))).value.toEventually(contain(.move))
                expect(controller.viewModelListOperations.map(\.operation)).to(contain(.set))
                expect(controller.viewModelListOperations.map(\.operation)).to(contain(.clear))
            }

            it("executes system actions on screen shown") { @MainActor in
                let flowId = "flow-system-actions"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "selectedProductId": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: nil,
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        ),
                        "selectedIndex": ViewModelProperty(
                            type: .number,
                            propertyId: 2,
                            defaultValue: nil,
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let instance = ViewModelInstance(
                    viewModelId: "vm-1",
                    instanceId: "vmi-1",
                    name: "Default",
                    values: [
                        "selectedProductId": AnyCodable("prod_1"),
                        "selectedIndex": AnyCodable(2)
                    ]
                )
                let purchaseAction = JourneyAction.purchase(
                    PurchaseAction(
                        placementIndex: AnyCodable([
                            "ref": [
                                "kind": "path",
                                "viewModelName": "VM",
                                "path": "selectedIndex"
                            ]
                        ]),
                        productId: AnyCodable([
                            "ref": [
                                "kind": "path",
                                "viewModelName": "VM",
                                "path": "selectedProductId"
                            ]
                        ])
                    )
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "capability-actions-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [
                                    purchaseAction,
                                    .restore(RestoreAction()),
                                    .requestNotifications(RequestNotificationsAction()),
                                    .requestPermission(RequestPermissionAction(permissionType: "camera")),
                                    .requestTracking(RequestTrackingAction()),
                                    .openLink(OpenLinkAction(url: AnyCodable("https://example.com"), target: "external")),
                                    .dismiss(DismissAction())
                                ]
                            )
                        ]
                    ],
                    viewModels: [viewModel],
                    viewModelInstances: [instance]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

                expect(controller.purchaseRequests.map(\.productId)).to(equal(["prod_1"]))
                expect(controller.purchaseRequests.first?.placementIndex as? Int).to(equal(2))
                expect(controller.restoreRequests).to(equal(1))
                expect(controller.requestNotificationJourneyIds).to(equal([journey.id]))
                expect(controller.requestPermissionRequests.map(\.permissionType)).to(equal(["camera"]))
                expect(controller.requestPermissionRequests.map(\.journeyId)).to(equal([journey.id]))
                expect(controller.requestTrackingJourneyIds).to(equal([journey.id]))
                expect(controller.openLinkRequests.map(\.urlString)).to(equal(["https://example.com"]))
                expect(controller.dismissRequests).to(equal([.userDismissed]))
                await polling(expect { await runner.hasPendingWork() }).value.to(beTrue())

                await runner.handleScopedSystemPermissionEvent(SystemEventNames.notificationsEnabled)
                await runner.handleScopedSystemPermissionEvent(SystemEventNames.permissionGranted)
                await runner.handleScopedSystemPermissionEvent(SystemEventNames.trackingAuthorized)

                await polling(expect { await runner.hasPendingWork() }).value.to(beFalse())
            }

            it("resumes delayed entry action and continues sequence") {
                let flowId = "flow-resume"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "flag": ViewModelProperty(
                            type: .boolean,
                            propertyId: 1,
                            defaultValue: AnyCodable(false),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .delay(DelayAction(durationMs: 500)),
                        .setViewModel(SetViewModelAction(
                            path: vmPath("flag"),
                            value: AnyCodable(["literal": true] as [String: Any])
                        ))
                    ],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let outcome = await runner.handleRuntimeReady()
                var paused = false
                if case .paused(let pending) = outcome {
                    paused = (pending.kind == .delay)
                }
                expect(paused).to(beTrue())

                _ = await runner.resumePendingAction(reason: .timer, event: nil)

                let state = await journey.snapshot()
                let snapshot = state.executionState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let flag = values?["flag"]?.value as? Bool
                expect(flag).to(equal(true))
                expect(state.executionState.pendingAction).to(beNil())
            }

            it("pauses again when a delay immediately follows a resumed delay") {
                let flowId = "flow-consecutive-delays"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "flag": ViewModelProperty(
                            type: .boolean,
                            propertyId: 1,
                            defaultValue: AnyCodable(false),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .delay(DelayAction(durationMs: 500)),
                        .delay(DelayAction(durationMs: 500)),
                        .setViewModel(SetViewModelAction(
                            path: vmPath("flag"),
                            value: AnyCodable(["literal": true] as [String: Any])
                        ))
                    ],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let outcome = await runner.handleRuntimeReady()
                var pausedOnFirstDelay = false
                if case .paused(let pending) = outcome {
                    pausedOnFirstDelay = (pending.kind == .delay)
                }
                expect(pausedOnFirstDelay).to(beTrue())

                // Resuming the first delay must pause on the second delay, not skip it.
                let secondOutcome = await runner.resumePendingAction(reason: .timer, event: nil)
                var pausedOnSecondDelay = false
                if case .paused(let pending) = secondOutcome {
                    pausedOnSecondDelay = (pending.kind == .delay)
                }
                expect(pausedOnSecondDelay).to(beTrue())
                var state = await journey.snapshot()
                expect(state.executionState.pendingAction).toNot(beNil())

                let flagAfterFirstResume = state.executionState.viewModelSnapshot?
                    .viewModelInstances.first?.values["flag"]?.value as? Bool
                expect(flagAfterFirstResume).toNot(equal(true))

                _ = await runner.resumePendingAction(reason: .timer, event: nil)
                state = await journey.snapshot()
                let flag = state.executionState.viewModelSnapshot?
                    .viewModelInstances.first?.values["flag"]?.value as? Bool
                expect(flag).to(equal(true))
                expect(state.executionState.pendingAction).to(beNil())
            }

            it("persists the pending action when pausing inside a purchase outcome outlet chain") { @MainActor in
                let flowId = "flow-outlet-pause"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "flag": ViewModelProperty(
                            type: .boolean,
                            propertyId: 1,
                            defaultValue: AnyCodable(false),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let purchase = JourneyAction.purchase(PurchaseAction(
                    placementIndex: AnyCodable(["literal": 0] as [String: Any]),
                    productId: AnyCodable(["literal": "prod_1"] as [String: Any]),
                    onCompleted: [
                        .delay(DelayAction(durationMs: 500)),
                        .setViewModel(SetViewModelAction(
                            path: vmPath("flag"),
                            value: AnyCodable(["literal": true] as [String: Any])
                        ))
                    ]
                ))
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [purchase],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleRuntimeReady()
                expect(controller.purchaseRequests.map(\.productId)).to(equal(["prod_1"]))

                let outcome = await runner.dispatchEventTrigger(
                    NuxieEvent(name: SystemEventNames.purchaseCompleted, distinctId: "user-1")
                )
                var paused = false
                if case .paused(let pending)? = outcome {
                    paused = (pending.kind == .delay)
                }
                expect(paused).to(beTrue())
                // The pause must be persisted so a scheduled resume can find it.
                var state = await journey.snapshot()
                expect(state.executionState.pendingAction).toNot(beNil())

                _ = await runner.resumePendingAction(reason: .timer, event: nil)
                state = await journey.snapshot()
                let flag = state.executionState.viewModelSnapshot?
                    .viewModelInstances.first?.values["flag"]?.value as? Bool
                expect(flag).to(equal(true))
                expect(state.executionState.pendingAction).to(beNil())
            }

            it("runs a purchase outcome outlet while another action is paused") { @MainActor in
                let flowId = "flow-outlet-during-existing-pause"
                let purchase = JourneyAction.purchase(
                    PurchaseAction(
                        placementIndex: AnyCodable(["literal": 0] as [String: Any]),
                        productId: AnyCodable(["literal": "prod_1"] as [String: Any]),
                        onCompleted: [
                            .sendEvent(
                                SendEventAction(
                                    eventName: "paused_purchase_completed",
                                    properties: nil
                                )
                            )
                        ]
                    )
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        purchase,
                        .delay(DelayAction(durationMs: 5_000)),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )
                let controller = SpyExperienceViewController(content: flow)
                await runner.attach(viewController: controller)

                guard case .paused = await runner.handleRuntimeReady() else {
                    return fail("Expected the entry sequence to pause")
                }

                _ = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.purchaseCompleted,
                        distinctId: "user-1"
                    )
                )

                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .to(contain("paused_purchase_completed"))
                let state = await journey.snapshot()
                expect(state.executionState.pendingPurchaseOutlets).to(beNil())
                expect(state.executionState.pendingAction?.kind).to(equal(.delay))
            }

            it("runs an outcome that arrives while an entry action is suspended") { @MainActor in
                let flowId = "flow-outlet-during-suspended-action"
                let gate = AsyncTestGate()
                let purchase = JourneyAction.purchase(
                    PurchaseAction(
                        placementIndex: AnyCodable(["literal": 0] as [String: Any]),
                        productId: AnyCodable(["literal": "prod_1"] as [String: Any]),
                        onCompleted: [
                            .sendEvent(
                                SendEventAction(
                                    eventName: "concurrent_purchase_completed",
                                    properties: nil
                                )
                            )
                        ]
                    )
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        purchase,
                        .milestone(MilestoneAction(milestoneId: "suspend", label: nil)),
                        .delay(DelayAction(durationMs: 5_000)),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow,
                    onMilestone: { _, _, _, _ in await gate.suspend() }
                )
                let controller = SpyExperienceViewController(content: flow)
                await runner.attach(viewController: controller)

                let entryTask = Task { await runner.handleRuntimeReady() }
                await gate.waitUntilEntered()
                _ = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.purchaseCompleted,
                        distinctId: "user-1"
                    )
                )
                gate.release()

                guard case .paused(let pending)? = await entryTask.value else {
                    return fail("Expected the entry sequence to reach its delay")
                }
                expect(pending.kind).to(equal(.delay))
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .to(contain("concurrent_purchase_completed"))
                let state = await journey.snapshot()
                expect(state.executionState.pendingPurchaseOutlets)
                    .to(beNil())
            }

            it("queues a timer resume without clearing a suspended outlet stack") { @MainActor in
                let flowId = "flow-resume-during-suspended-outlet"
                let gate = AsyncTestGate()
                let purchase = JourneyAction.purchase(
                    PurchaseAction(
                        placementIndex: AnyCodable(["literal": 0] as [String: Any]),
                        productId: AnyCodable(["literal": "prod_1"] as [String: Any]),
                        onCompleted: [
                            .milestone(MilestoneAction(milestoneId: "outlet-suspend", label: nil)),
                            .sendEvent(
                                SendEventAction(
                                    eventName: "outlet_continued",
                                    properties: nil
                                )
                            ),
                        ]
                    )
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        purchase,
                        .delay(DelayAction(durationMs: 5_000)),
                        .sendEvent(
                            SendEventAction(
                                eventName: "entry_resumed",
                                properties: nil
                            )
                        ),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow,
                    onMilestone: { _, _, _, _ in await gate.suspend() }
                )
                let controller = SpyExperienceViewController(content: flow)
                await runner.attach(viewController: controller)

                guard case .paused = await runner.handleRuntimeReady() else {
                    return fail("Expected the entry sequence to pause")
                }
                let outletTask = Task {
                    await runner.dispatchEventTrigger(
                        NuxieEvent(
                            name: SystemEventNames.purchaseCompleted,
                            distinctId: "user-1"
                        )
                    )
                }
                await gate.waitUntilEntered()
                _ = await runner.resumePendingAction(reason: .timer, event: nil)
                gate.release()
                _ = await outletTask.value

                let trackedEvents = mocks.eventLog.trackedEvents.map(\.name)
                expect(trackedEvents).to(contain("entry_resumed"))
                expect(trackedEvents).to(contain("outlet_continued"))
                let state = await journey.snapshot()
                expect(state.executionState.pendingAction).to(beNil())
            }

            it("drains queued priority outlets before an interrupted normal continuation") { @MainActor in
                let flowId = "flow-priority-outlets-before-resume"
                let gate = AsyncTestGate()
                let purchase = JourneyAction.purchase(
                    PurchaseAction(
                        placementIndex: AnyCodable(["literal": 0] as [String: Any]),
                        productId: AnyCodable(["literal": "prod_1"] as [String: Any]),
                        onCompleted: [
                            .milestone(MilestoneAction(milestoneId: "priority-b", label: nil)),
                            .sendEvent(SendEventAction(eventName: "priority_b", properties: nil)),
                        ]
                    )
                )
                let restore = JourneyAction.restore(
                    RestoreAction(
                        onRestored: [
                            .sendEvent(SendEventAction(eventName: "priority_c", properties: nil))
                        ],
                        onNoPurchases: nil,
                        onFailed: nil
                    )
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        purchase,
                        restore,
                        .delay(DelayAction(durationMs: 5_000)),
                        .sendEvent(SendEventAction(eventName: "normal_a", properties: nil)),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow,
                    onMilestone: { _, _, _, _ in await gate.suspend() }
                )
                let controller = SpyExperienceViewController(content: flow)
                await runner.attach(viewController: controller)

                guard case .paused = await runner.handleRuntimeReady() else {
                    return fail("Expected the entry sequence to pause")
                }
                let purchaseTask = Task {
                    await runner.dispatchEventTrigger(
                        NuxieEvent(
                            name: SystemEventNames.purchaseCompleted,
                            distinctId: "user-1"
                        )
                    )
                }
                await gate.waitUntilEntered()
                _ = await runner.resumePendingAction(reason: .timer, event: nil)
                _ = await runner.dispatchEventTrigger(
                    NuxieEvent(
                        name: SystemEventNames.restoreCompleted,
                        distinctId: "user-1"
                    )
                )
                gate.release()
                _ = await purchaseTask.value

                let markers = mocks.eventLog.trackedEvents.map(\.name).filter {
                    ["priority_b", "priority_c", "normal_a"].contains($0)
                }
                expect(markers).to(equal(["priority_b", "priority_c", "normal_a"]))
            }

            it("pauses on time_window when outside configured hours") {
                let flowId = "flow-time-window"
                let action = TimeWindowAction(
                    startTime: "09:00",
                    endTime: "17:00",
                    timezone: "UTC",
                    daysOfWeek: nil
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.timeWindow(action)]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 2, minute: 0))!
                mocks.dateProvider.setCurrentDate(date)

                let outcome = await runner.handleRuntimeReady()

                if case .paused(let pending) = outcome {
                    expect(pending.kind).to(equal(.timeWindow))
                    expect(pending.resumeAt).toNot(beNil())
                } else {
                    fail("Expected time_window to pause")
                }
            }

            it("continues on time_window when inside configured hours") {
                let flowId = "flow-time-window-in"
                let action = TimeWindowAction(
                    startTime: "09:00",
                    endTime: "17:00",
                    timezone: "UTC",
                    daysOfWeek: nil
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.timeWindow(action)]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 10, minute: 0))!
                mocks.dateProvider.setCurrentDate(date)

                _ = await runner.handleRuntimeReady()

                let state = await journey.snapshot()
                expect(state.executionState.pendingAction).to(beNil())
            }

            it("uses the current device timezone token for time_window") { @MainActor in
                let flowId = "flow-time-window-device"
                let action = TimeWindowAction(
                    startTime: "09:00",
                    endTime: "11:00",
                    timezone: "__current_device__",
                    daysOfWeek: nil,
                    successActions: [
                        .navigate(NavigateAction(screenId: "screen-2", transition: nil))
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.timeWindow(action)],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                        JourneyScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)
                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = .current
                let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 10, minute: 0))!
                mocks.dateProvider.setCurrentDate(date)

                _ = await runner.handleRuntimeReady()

                let state = await journey.snapshot()
                expect(state.executionState.pendingAction).to(beNil())
                await polling(expect(controller.navigationRequests.map(\.screenId))).value.toEventually(contain("screen-2"))
            }

            it("resumes nested time_window actions after a delay pause") { @MainActor in
                let flowId = "flow-time-window-delayed-then"
                let action = TimeWindowAction(
                    startTime: "09:00",
                    endTime: "11:00",
                    timezone: "UTC",
                    daysOfWeek: nil,
                    successActions: [
                        .delay(DelayAction(durationMs: 1_000)),
                        .navigate(NavigateAction(screenId: "screen-2", transition: nil)),
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.timeWindow(action)],
                    screens: [
                        JourneyScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                        JourneyScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)
                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 10, minute: 0))!
                mocks.dateProvider.setCurrentDate(date)

                let outcome = await runner.handleRuntimeReady()
                if case .paused(let pending) = outcome {
                    expect(pending.kind).to(equal(.delay))
                } else {
                    fail("Expected nested time_window delay to pause")
                }

                _ = await runner.resumePendingAction(reason: .timer, event: nil)

                let state = await journey.snapshot()
                expect(state.executionState.pendingAction).to(beNil())
                await polling(expect(controller.navigationRequests.map(\.screenId))).value.toEventually(contain("screen-2"))
            }

            it("resumes nested time_window actions and continues outer actions") {
                let flowId = "flow-time-window-delayed-outer"
                let action = TimeWindowAction(
                    startTime: "09:00",
                    endTime: "11:00",
                    timezone: "UTC",
                    daysOfWeek: nil,
                    successActions: [
                        .delay(DelayAction(durationMs: 1_000)),
                        .sendEvent(SendEventAction(
                            eventName: "inside_window",
                            properties: nil
                        )),
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .timeWindow(action),
                        .sendEvent(SendEventAction(
                            eventName: "after_window",
                            properties: nil
                        )),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                let date = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 10, minute: 0))!
                mocks.dateProvider.setCurrentDate(date)

                let outcome = await runner.handleRuntimeReady()
                if case .paused(let pending) = outcome {
                    expect(pending.kind).to(equal(.delay))
                } else {
                    fail("Expected nested time_window delay to pause")
                }

                _ = await runner.resumePendingAction(reason: .timer, event: nil)

                let state = await journey.snapshot()
                expect(state.executionState.pendingAction).to(beNil())
                let trackedEvents = mocks.eventLog.trackedEvents.map(\.name)
                expect(trackedEvents).to(contain("inside_window"))
                expect(trackedEvents).to(contain("after_window"))
            }

            it("preserves a nested sequence root across pause and resume") { @MainActor in
                let flowId = "flow-nested-root-after-pause"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .condition(
                            ConditionAction(
                                branches: [
                                    ConditionBranch(
                                        id: "nested",
                                        label: nil,
                                        condition: TestIRBuilder.alwaysTrue(),
                                        actions: [
                                            .delay(DelayAction(durationMs: 1)),
                                            .navigate(
                                                NavigateAction(
                                                    screenId: "screen-2",
                                                    transition: nil
                                                )
                                            ),
                                        ]
                                    )
                                ]
                            )
                        ),
                        .sendEvent(
                            SendEventAction(
                                eventName: "should_stop_with_nested_root",
                                properties: nil
                            )
                        ),
                    ],
                    screens: [
                        JourneyScreen(
                            id: "screen-1",
                            defaultViewModelName: nil,
                            defaultInstanceId: nil
                        ),
                        JourneyScreen(
                            id: "screen-2",
                            defaultViewModelName: nil,
                            defaultInstanceId: nil
                        ),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )
                let controller = SpyExperienceViewController(content: flow)
                await runner.attach(viewController: controller)

                guard case .paused = await runner.handleRuntimeReady() else {
                    return fail("Expected nested delay to pause")
                }
                _ = await runner.resumePendingAction(reason: .timer, event: nil)

                expect(controller.navigationRequests.map(\.screenId))
                    .to(contain("screen-2"))
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain("should_stop_with_nested_root"))
            }

            it("resumes wait_until when event condition is satisfied") {
                let flowId = "flow-wait"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "flag": ViewModelProperty(
                            type: .boolean,
                            propertyId: 1,
                            defaultValue: AnyCodable(false),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        ),
                        "message": ViewModelProperty(
                            type: .string,
                            propertyId: 2,
                            defaultValue: AnyCodable(""),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let waitAction = WaitUntilAction(
                    condition: TestWaitCondition.event("ready"),
                    maxTimeMs: 10_000,
                    bindResultTo: "matched_event",
                    successActions: [
                        .setViewModel(SetViewModelAction(
                            path: vmPath("message"),
                            value: AnyCodable([
                                "ref": ["kind": "payload", "path": "message"]
                            ] as [String: Any])
                        )),
                        .sendEvent(SendEventAction(
                            eventName: "wait_succeeded"
                        ))
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .waitUntil(waitAction),
                        .setViewModel(SetViewModelAction(
                            path: vmPath("flag"),
                            value: AnyCodable(["literal": true] as [String: Any])
                        ))
                    ],
                    viewModels: [viewModel]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let outcome = await runner.handleRuntimeReady()
                if case .paused(let pending) = outcome {
                    expect(pending.kind).to(equal(.waitUntil))
                } else {
                    fail("Expected wait_until to pause")
                }

                let event = TestEventBuilder(name: "ready")
                    .withDistinctId("user-1")
                    .withProperties(["message": "resumed payload"])
                    .build()
                _ = await runner.resumePendingAction(reason: .event(event), event: event)

                let state = await journey.snapshot()
                let snapshot = state.executionState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let flag = values?["flag"]?.value as? Bool
                expect(flag).to(equal(true))
                expect(values?["message"]?.value as? String).to(equal("resumed payload"))
                let bound = state.context["matched_event"]?.value as? [String: Any]
                expect(bound).toNot(beNil())
                expect(state.executionState.pendingAction).to(beNil())
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .to(contain("wait_succeeded"))
            }

            it("continues wait_until after maxTimeMs deadline") {
                let flowId = "flow-wait-deadline"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "flag": ViewModelProperty(
                            type: .boolean,
                            propertyId: 1,
                            defaultValue: AnyCodable(false),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let waitAction = WaitUntilAction(
                    condition: TestWaitCondition.expression("false"),
                    maxTimeMs: 1_000,
                    timeoutActions: [
                        .sendEvent(SendEventAction(
                            eventName: "wait_timed_out"
                        ))
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .waitUntil(waitAction),
                        .setViewModel(SetViewModelAction(
                            path: vmPath("flag"),
                            value: AnyCodable(["literal": true] as [String: Any])
                        ))
                    ],
                    viewModels: [viewModel]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
                let start = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1, hour: 0, minute: 0, second: 0))!
                mocks.dateProvider.setCurrentDate(start)

                let outcome = await runner.handleRuntimeReady()
                guard case .paused(let pending) = outcome else {
                    fail("Expected wait_until to pause")
                    return
                }
                expect(pending.kind).to(equal(.waitUntil))
                expect(pending.resumeAt).toNot(beNil())

                mocks.dateProvider.setCurrentDate(start.addingTimeInterval(2.0))
                let acceptedExpiredWaitEvent = await runner.acceptsEventTrigger(
                    NuxieEvent(
                        name: "deadline_probe",
                        distinctId: journey.distinctId
                    )
                )
                expect(acceptedExpiredWaitEvent).to(beTrue())
                _ = await runner.resumePendingAction(reason: .timer, event: nil)

                let state = await journey.snapshot()
                let snapshot = state.executionState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let flag = values?["flag"]?.value as? Bool
                expect(flag).to(equal(true))
                expect(state.executionState.pendingAction).to(beNil())
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .to(contain("wait_timed_out"))
            }

            it("executes the first matching condition branch") {
                let flowId = "flow-condition"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "variant": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("none"),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let branchA = ConditionBranch(
                    id: "branch-a",
                    label: nil,
                    condition: TestIRBuilder.alwaysFalse(),
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: vmPath("variant"),
                            value: AnyCodable(["literal": "a"] as [String: Any])
                        ))
                    ]
                )
                let branchB = ConditionBranch(
                    id: "branch-b",
                    label: nil,
                    condition: TestIRBuilder.alwaysTrue(),
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: vmPath("variant"),
                            value: AnyCodable(["literal": "b"] as [String: Any])
                        ))
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .condition(ConditionAction(branches: [branchA, branchB]))
                    ],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                _ = await runner.handleRuntimeReady()

                let state = await journey.snapshot()
                let snapshot = state.executionState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let variant = values?["variant"]?.value as? String
                expect(variant).to(equal("b"))
            }

            it("executes deeply nested sequences without recursive control flow") {
                let flowId = "flow-deeply-nested-sequences"
                var actions: [JourneyAction] = [
                    .sendEvent(
                        SendEventAction(
                            eventName: "deep_sequence_completed",
                            properties: nil
                        )
                    )
                ]

                for depth in 0..<50 {
                    actions = [
                        .condition(
                            ConditionAction(
                                nodeId: "condition-\(depth)",
                                branches: [
                                    ConditionBranch(
                                        id: "branch-\(depth)",
                                        label: nil,
                                        condition: TestIRBuilder.alwaysTrue(),
                                        actions: actions
                                    )
                                ]
                            )
                        )
                    ]
                }

                // Build the signed document directly so the test itself does
                // not recursively normalize the authored action tree.
                let host = JourneyDocument.journeyEventHostKey
                let screens = JourneyDocument(
                    screens: [JourneyScreen(id: "screen-1")],
                    events: [
                        host: [
                            EventDeclaration(
                                id: "start:event",
                                eventName: "$app_opened"
                            )
                        ]
                    ],
                    handlers: [
                        host: [
                            JourneyEventHandler(
                                id: "start",
                                eventName: "$app_opened",
                                enabled: true,
                                actions: actions
                            )
                        ]
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )

                _ = await runner.handleRuntimeReady()

                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .to(contain("deep_sequence_completed"))
            }

            it("applies experiment variant from profile assignment") {
                let flowId = "flow-experiment"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "variant": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("none"),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let variantA = ExperimentVariant(
                    id: "a",
                    name: "A",
                    percentage: 50,
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: vmPath("variant"),
                            value: AnyCodable(["literal": "a"] as [String: Any])
                        ))
                    ]
                )
                let variantB = ExperimentVariant(
                    id: "b",
                    name: "B",
                    percentage: 50,
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: vmPath("variant"),
                            value: AnyCodable(["literal": "b"] as [String: Any])
                        ))
                    ]
                )

                let experiment = ExperimentAction(
                    experimentId: "exp-1",
                    variants: [variantA, variantB]
                )

                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let assignment = ExperimentAssignment(
                    experimentKey: "exp-1",
                    variantKey: "b",
                    status: "running",
                    isHoldout: false
                )
                let profile = ProfileResponse(
                    experiences: [],
                    segments: [],
                    pinnedVersions: [],
                    assetBaseUrl: "https://assets.nuxie.ai/",
                    userProperties: nil,
                    experiments: ["exp-1": assignment],
                    features: nil
                )
                mocks.profileService.setProfileResponse(profile)
                _ = try? await mocks.profileService.refetchProfile(distinctId: journey.distinctId)

                _ = await runner.handleRuntimeReady()

                let state = await journey.snapshot()
                let snapshot = state.executionState.viewModelSnapshot
                let values = snapshot?.viewModelInstances.first?.values
                let variant = values?["variant"]?.value as? String
                expect(variant).to(equal("b"))
                expect(state.context["_experiment_key"]?.value as? String).to(equal("exp-1"))
                expect(state.context["_variant_key"]?.value as? String).to(equal("b"))
            }

            it("does not freeze experiment variant key without a running assignment") {
                let flowId = "flow-experiment-freeze-non-running"
                let variantA = ExperimentVariant(
                    id: "a",
                    name: "A",
                    percentage: 50,
                    actions: []
                )
                let variantB = ExperimentVariant(
                    id: "b",
                    name: "B",
                    percentage: 50,
                    actions: []
                )

                let experiment = ExperimentAction(
                    experimentId: "exp-1",
                    variants: [variantA, variantB]
                )

                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                // No cached profile => no assignment => should not freeze fallback variant.
                _ = await runner.handleRuntimeReady()

                let frozenVariants = await journey.getContext("_experiment_variants")
                expect(frozenVariants).to(beNil())
            }

            it("freezes experiment variant key when assignment is running and matches") {
                let flowId = "flow-experiment-freeze-running"
                let variantA = ExperimentVariant(
                    id: "a",
                    name: "A",
                    percentage: 50,
                    actions: []
                )
                let variantB = ExperimentVariant(
                    id: "b",
                    name: "B",
                    percentage: 50,
                    actions: []
                )

                let experiment = ExperimentAction(
                    experimentId: "exp-1",
                    variants: [variantA, variantB]
                )

                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let assignment = ExperimentAssignment(
                    experimentKey: "exp-1",
                    variantKey: "b",
                    status: "running",
                    isHoldout: false
                )
                let profile = ProfileResponse(
                    experiences: [],
                    segments: [],
                    pinnedVersions: [],
                    assetBaseUrl: "https://assets.nuxie.ai/",
                    userProperties: nil,
                    experiments: ["exp-1": assignment],
                    features: nil
                )
                mocks.profileService.setProfileResponse(profile)
                _ = try? await mocks.profileService.refetchProfile(distinctId: journey.distinctId)

                _ = await runner.handleRuntimeReady()

                let frozen = await journey.getContext("_experiment_variants")?.value
                    as? [String: Any]
                expect(frozen?["exp-1"] as? String).to(equal("b"))
            }

            it("tracks experiment exposure for running assignment") {
                let flowId = "flow-experiment-exposure"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "variant": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("none"),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let variantA = ExperimentVariant(
                    id: "a",
                    name: "A",
                    percentage: 50,
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: vmPath("variant"),
                            value: AnyCodable(["literal": "a"] as [String: Any])
                        ))
                    ]
                )
                let variantB = ExperimentVariant(
                    id: "b",
                    name: "B",
                    percentage: 50,
                    actions: [
                        .setViewModel(SetViewModelAction(
                            path: vmPath("variant"),
                            value: AnyCodable(["literal": "b"] as [String: Any])
                        ))
                    ]
                )

                let experiment = ExperimentAction(
                    experimentId: "exp-1",
                    variants: [variantA, variantB]
                )

                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let assignment = ExperimentAssignment(
                    experimentKey: "exp-1",
                    variantKey: "b",
                    status: "running",
                    isHoldout: true
                )
                let profile = ProfileResponse(
                    experiences: [],
                    segments: [],
                    pinnedVersions: [],
                    assetBaseUrl: "https://assets.nuxie.ai/",
                    userProperties: nil,
                    experiments: ["exp-1": assignment],
                    features: nil
                )
                mocks.profileService.setProfileResponse(profile)
                _ = try? await mocks.profileService.refetchProfile(distinctId: journey.distinctId)

                _ = await runner.handleRuntimeReady()

                let exposure = mocks.eventLog.trackedEvents.first {
                    $0.name == JourneyEvents.experimentExposure
                }
                expect(exposure).toNot(beNil())
                let props = exposure?.properties ?? [:]
                expect(props["experiment_key"] as? String).to(equal("exp-1"))
                expect(props["variant_key"] as? String).to(equal("b"))
                expect(props["experience_id"] as? String).to(equal("camp-1"))
                expect(props["experience_version"] as? String).to(equal(flowId))
                expect(props["journey_id"] as? String).to(equal(journey.id))
                expect(props["is_holdout"] as? Bool).to(beTrue())
            }

            it("tracks experiment exposure errors for missing variants") {
                let flowId = "flow-experiment-missing"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "variant": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("none"),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let variantA = ExperimentVariant(
                    id: "a",
                    name: "A",
                    percentage: 50,
                    actions: []
                )
                let variantB = ExperimentVariant(
                    id: "b",
                    name: "B",
                    percentage: 50,
                    actions: []
                )

                let experiment = ExperimentAction(
                    experimentId: "exp-1",
                    variants: [variantA, variantB]
                )

                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let assignment = ExperimentAssignment(
                    experimentKey: "exp-1",
                    variantKey: "missing",
                    status: "running",
                    isHoldout: false
                )
                let profile = ProfileResponse(
                    experiences: [],
                    segments: [],
                    pinnedVersions: [],
                    assetBaseUrl: "https://assets.nuxie.ai/",
                    userProperties: nil,
                    experiments: ["exp-1": assignment],
                    features: nil
                )
                mocks.profileService.setProfileResponse(profile)
                _ = try? await mocks.profileService.refetchProfile(distinctId: journey.distinctId)

                _ = await runner.handleRuntimeReady()

                let errorEvent = mocks.eventLog.trackedEvents.first {
                    $0.name == "$experiment_exposure_error"
                }
                expect(errorEvent).toNot(beNil())
                let props = errorEvent?.properties ?? [:]
                expect(props["experiment_key"] as? String).to(equal("exp-1"))
                expect(props["variant_key"] as? String).to(equal("missing"))
                expect(props["reason"] as? String).to(equal("variant_not_found"))

                let trackedNames = mocks.eventLog.trackedEvents.map(\.name)
                expect(trackedNames).toNot(contain(JourneyEvents.experimentExposure))
            }

            it("does not execute any variant when a running assignment's variant is missing") {
                let flowId = "flow-experiment-missing-skip"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "variant": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("none"),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                // Variants that would leave an observable mark if executed
                let experiment = ExperimentAction(
                    experimentId: "exp-skip",
                    variants: [
                        ExperimentVariant(id: "a", name: "A", percentage: 50, actions: [
                            .setViewModel(SetViewModelAction(
                                path: vmPath("variant"),
                                value: AnyCodable(["literal": "a"] as [String: Any])
                            ))
                        ])
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let assignment = ExperimentAssignment(
                    experimentKey: "exp-skip",
                    variantKey: "missing",
                    status: "running",
                    isHoldout: false
                )
                let profile = ProfileResponse(
                    experiences: [], segments: [], pinnedVersions: [],
                    assetBaseUrl: "https://assets.nuxie.ai/",
                    userProperties: nil,
                    experiments: ["exp-skip": assignment],
                    features: nil
                )
                mocks.profileService.setProfileResponse(profile)
                _ = try? await mocks.profileService.refetchProfile(distinctId: journey.distinctId)

                _ = await runner.handleRuntimeReady()

                // Error recorded, and the fallback variant's actions did NOT run —
                // exposed-but-invisible users corrupt experiment analysis.
                let trackedNames = mocks.eventLog.trackedEvents.map(\.name)
                expect(trackedNames).to(contain("$experiment_exposure_error"))
                let state = await journey.snapshot()
                let variantValue = state.executionState.viewModelSnapshot?
                    .viewModelInstances.first?.values["variant"]?.value as? String
                expect(variantValue).toNot(equal("a"))
            }

            it("tags fallback execution when no assignment exists") {
                let flowId = "flow-experiment-fallback"
                let viewModel = ViewModel(
                    id: "vm-1",
                    name: "VM",
                    viewModelPathId: 0,
                    properties: [
                        "variant": ViewModelProperty(
                            type: .string,
                            propertyId: 1,
                            defaultValue: AnyCodable("none"),
                            required: nil,
                            enumValues: nil,
                            itemType: nil,
                            schema: nil,
                            viewModelId: nil,
                            validation: nil
                        )
                    ]
                )
                let experiment = ExperimentAction(
                    experimentId: "exp-offline",
                    variants: [
                        ExperimentVariant(id: "control", name: "Control", percentage: 100, actions: [
                            .setViewModel(SetViewModelAction(
                                path: vmPath("variant"),
                                value: AnyCodable(["literal": "control"] as [String: Any])
                            ))
                        ])
                    ]
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.experiment(experiment)],
                    viewModels: [viewModel]
                )

                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-offline", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                // No profile / assignment at all (offline cold start)
                _ = await runner.handleRuntimeReady()

                // The default branch runs (journeys work offline) but the
                // exposure is TAGGED, never silent.
                let fallback = mocks.eventLog.trackedEvents.first {
                    $0.name == "$experiment_exposure_fallback"
                }
                expect(fallback).toNot(beNil())
                let fallbackProps = fallback?.properties ?? [:]
                expect(fallbackProps["experiment_key"] as? String).to(equal("exp-offline"))
                expect(fallbackProps["variant_key"] as? String).to(equal("control"))
                expect(fallbackProps["assignment_source"] as? String).to(equal("no_assignment"))

                let state = await journey.snapshot()
                let variantValue = state.executionState.viewModelSnapshot?
                    .viewModelInstances.first?.values["variant"]?.value as? String
                expect(variantValue).to(equal("control"))
            }

            it("emits a deterministic connector effect request and resumes its success outlet") {
                let flowId = "flow-effect"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .connectorAction(ConnectorAction(
                            nodeId: "entry",
                            accountRef: "account-1",
                            toolKey: "RESEND_SEND_EMAIL",
                            payload: AnyCodable([
                                "to": [
                                    "ref": [
                                        "kind": "context",
                                        "path": "email",
                                    ],
                                ],
                            ] as [String: Any]),
                            onSucceeded: [
                                .sendEvent(SendEventAction(eventName: "effect_succeeded", properties: nil))
                            ],
                            onFailed: [
                                .sendEvent(SendEventAction(eventName: "effect_failed", properties: nil))
                            ],
                            timeoutMs: 10_000
                        ))
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                await journey.setContext(
                    "email",
                    value: AnyCodable("person@example.com"),
                    at: mocks.dateProvider.now()
                )
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let outcome = await runner.handleRuntimeReady()

                if case .paused(let pending) = outcome {
                    expect(pending.kind).to(equal(.waitUntil))
                    expect(pending.resumeAt).toNot(beNil())
                } else {
                    fail("Expected effect completion wait to pause")
                }

                let request = mocks.eventLog.trackedEvents.first {
                    $0.name == JourneyEvents.journeyEffectRequested
                }
                expect(request).toNot(beNil())
                expect(mocks.eventLog.drainCallCount).to(equal(1))
                expect(request?.properties?["journey_id"] as? String).to(equal(journey.id))
                expect(request?.properties?["node_id"] as? String).to(equal("entry"))
                let requestPayload = request?.properties?["payload"]
                let payloadValue: Any?
                if let wrappedPayload = requestPayload as? AnyCodable {
                    payloadValue = wrappedPayload.value
                } else {
                    payloadValue = requestPayload
                }
                let recipientValue =
                    (payloadValue as? [String: Any])?["to"]
                    ?? (payloadValue as? [String: AnyCodable])?["to"]?.value
                let resolvedRecipient = (recipientValue as? AnyCodable)?.value as? String
                    ?? recipientValue as? String
                expect(resolvedRecipient).to(equal("person@example.com"))
                expect(request?.properties?["invocation_id"] as? String).to(equal(
                    JourneyRunner.effectInvocationId(
                        journeyId: journey.id,
                        nodeId: "entry",
                        attempt: 0
                    )
                ))

                let completion = TestEventBuilder(name: JourneyEvents.journeyEffectCompleted)
                    .withDistinctId("user-1")
                    .withProperties([
                        "journey_id": journey.id,
                        "node_id": "entry",
                        "invocation_id": request?.properties?["invocation_id"] as? String ?? "",
                        "status": "ok",
                        "result": ["message_id": "message-1"],
                    ])
                    .build()
                // Rebuild the runner from the persisted journey checkpoint,
                // matching an app relaunch while the durable request is
                // offline or in flight.
                let restoredRunner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow
                )
                _ = await restoredRunner.resumePendingAction(
                    reason: .event(completion),
                    event: completion
                )

                expect(mocks.eventLog.trackedEvents.map(\.name)).to(contain("effect_succeeded"))
                let state = await journey.snapshot()
                let results = state.context["_effect_results"]?.value as? [String: Any]
                expect(results?["entry"]).toNot(beNil())

                _ = await restoredRunner.resumePendingAction(
                    reason: .event(completion),
                    event: completion
                )
                expect(
                    mocks.eventLog.trackedEvents.filter {
                        $0.name == "effect_succeeded"
                    }
                ).to(haveCount(1))
            }

            it("increments authored attempts and ignores a late prior completion") {
                let flowId = "flow-effect-retry"
                let retry = ConnectorAction(
                    nodeId: "send-email",
                    accountRef: "account-1",
                    toolKey: "RESEND_SEND_EMAIL",
                    payload: AnyCodable([:] as [String: Any]),
                    onSucceeded: [
                        .sendEvent(SendEventAction(eventName: "retry_succeeded", properties: nil))
                    ],
                    onFailed: nil,
                    timeoutMs: 10_000
                )
                let first = ConnectorAction(
                    nodeId: "send-email",
                    accountRef: "account-1",
                    toolKey: "RESEND_SEND_EMAIL",
                    payload: AnyCodable([:] as [String: Any]),
                    onSucceeded: [.connectorAction(retry)],
                    onFailed: nil,
                    timeoutMs: 10_000
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.connectorAction(first)]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                _ = await runner.handleRuntimeReady()
                let firstId = JourneyRunner.effectInvocationId(
                    journeyId: journey.id,
                    nodeId: "send-email",
                    attempt: 0
                )
                let firstCompletion = TestEventBuilder(name: JourneyEvents.journeyEffectCompleted)
                    .withDistinctId("user-1")
                    .withProperties([
                        "journey_id": journey.id,
                        "node_id": "send-email",
                        "invocation_id": firstId,
                        "status": "ok",
                    ])
                    .build()
                _ = await runner.resumePendingAction(
                    reason: .event(firstCompletion),
                    event: firstCompletion
                )

                let requests = mocks.eventLog.trackedEvents.filter {
                    $0.name == JourneyEvents.journeyEffectRequested
                }
                expect(requests).to(haveCount(2))
                let secondId = JourneyRunner.effectInvocationId(
                    journeyId: journey.id,
                    nodeId: "send-email",
                    attempt: 1
                )
                expect(requests.last?.properties?["invocation_id"] as? String)
                    .to(equal(secondId))

                _ = await runner.resumePendingAction(
                    reason: .event(firstCompletion),
                    event: firstCompletion
                )
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain("retry_succeeded"))
                let state = await journey.snapshot()
                expect(state.executionState.pendingAction).toNot(beNil())

                let secondCompletion = TestEventBuilder(name: JourneyEvents.journeyEffectCompleted)
                    .withDistinctId("user-1")
                    .withProperties([
                        "journey_id": journey.id,
                        "node_id": "send-email",
                        "invocation_id": secondId,
                        "status": "ok",
                    ])
                    .build()
                _ = await runner.resumePendingAction(
                    reason: .event(secondCompletion),
                    event: secondCompletion
                )
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .to(contain("retry_succeeded"))
            }

            it("selects the failed and no-answer effect outcomes") {
                let flowId = "flow-effect-outcomes"
                let effect = ConnectorAction(
                    nodeId: "entry",
                    accountRef: "account-1",
                    toolKey: "RESEND_SEND_EMAIL",
                    payload: AnyCodable([:] as [String: Any]),
                    onSucceeded: nil,
                    onFailed: [
                        .sendEvent(SendEventAction(eventName: "effect_failed", properties: nil))
                    ],
                    onTimeout: [
                        .sendEvent(SendEventAction(eventName: "effect_timed_out", properties: nil))
                    ],
                    timeoutMs: 1_000
                )
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [.connectorAction(effect)]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                _ = await runner.handleRuntimeReady()
                let failure = TestEventBuilder(name: JourneyEvents.journeyEffectCompleted)
                    .withDistinctId("user-1")
                    .withProperties([
                        "journey_id": journey.id,
                        "node_id": "entry",
                        "invocation_id": JourneyRunner.effectInvocationId(
                            journeyId: journey.id,
                            nodeId: "entry",
                            attempt: 0
                        ),
                        "status": "error",
                        "error": ["message": "provider failed"],
                    ])
                    .build()
                _ = await runner.resumePendingAction(reason: .event(failure), event: failure)
                expect(mocks.eventLog.trackedEvents.map(\.name)).to(contain("effect_failed"))

                let timeoutJourney = Journey(
                    experience: experience,
                    distinctId: "user-2",
                    now: mocks.dateProvider.now()
                )
                let timeoutRunner = makeRunner(
                    journey: timeoutJourney,
                    experience: experience,
                    content: flow
                )
                _ = await timeoutRunner.handleRuntimeReady()
                mocks.dateProvider.advance(by: 2)
                _ = await timeoutRunner.resumePendingAction(reason: .timer, event: nil)
                expect(mocks.eventLog.trackedEvents.map(\.name)).to(contain("effect_timed_out"))
            }

            it("uses explicit back transitions when provided") { @MainActor in
                let flowId = "flow-back-transition"
                let transition = AnyCodable(["type": "push"])
                let screenList = [
                    JourneyScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                    JourneyScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil)
                ]
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "back-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [.back(BackAction(steps: 1, transition: transition))]
                            )
                        ]
                    ],
                    screens: screenList
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                await journey.update { $0.executionState.navigationStack = ["screen-1"] }
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-2")

                await polling(expect(controller.navigationRequests.map(\.screenId))).value.toEventually(contain("screen-1"))
                let transitionPayload = controller.navigationRequests.last?.transition as? [String: Any]
                expect(transitionPayload?["type"] as? String).to(equal("push"))
                expect(transitionPayload?["direction"]).to(beNil())
            }

            it("omits back transitions when not configured") { @MainActor in
                let flowId = "flow-back-no-transition"
                let screenList = [
                    JourneyScreen(id: "screen-1", defaultViewModelName: nil, defaultInstanceId: nil),
                    JourneyScreen(id: "screen-2", defaultViewModelName: nil, defaultInstanceId: nil)
                ]
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "back-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [.back(BackAction(steps: 1))]
                            )
                        ]
                    ],
                    screens: screenList
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                await journey.update { $0.executionState.navigationStack = ["screen-1"] }
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-2")

                await polling(expect(controller.navigationRequests.map(\.screenId))).value.toEventually(contain("screen-1"))
                expect(controller.navigationRequests.last?.transition).to(beNil())
            }

            it("no-ops back when history is empty") {
                let flowId = "flow-back-empty"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    handlers: [
                        JourneyDocument.journeyEventHostKey: [
                            JourneyEventHandler(
                                id: "back-on-show",
                                eventName: SystemEventNames.screenShown,
                                actions: [.back(BackAction(steps: 1))]
                            )
                        ]
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                let controller = await MainActor.run {
                    SpyExperienceViewController(content: flow)
                }
                await runner.attach(viewController: controller)

                _ = await runner.handleScreenChanged("screen-1")

            }

            it("tracks send_event and updates customer properties") {
                let flowId = "flow-send-event"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .updateCustomer(UpdateCustomerAction(attributes: ["plan": AnyCodable("pro")])),
                        .sendEvent(SendEventAction(
                            eventName: "custom_event",
                            properties: ["source": AnyCodable("flow")]
                        ))
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                _ = await runner.handleRuntimeReady()

                let props = mocks.identityService.getUserProperties()
                expect(props["plan"] as? String).to(equal("pro"))

                let trackedEvents = mocks.eventLog.trackedEvents.map(\.name)
                expect(trackedEvents).to(contain("custom_event"))
            }

            it("tracks milestone actions with the canonical property keys") {
                let flowId = "flow-goal-action"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .milestone(MilestoneAction(milestoneId: " signup_complete ", label: " Signed Up "))
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(journey: journey, experience: experience, content: flow)

                _ = await runner.handleRuntimeReady()

                let milestoneEvent = mocks.eventLog.trackWithResponseCalls.last {
                    $0.event == JourneyEvents.journeyMilestone
                }
                expect(milestoneEvent?.properties?["journey_id"] as? String).to(equal(journey.id))
                expect(milestoneEvent?.properties?["milestone_id"] as? String).to(equal("signup_complete"))
                expect(milestoneEvent?.properties?["epoch"] as? Int).to(equal(0))
                expect(milestoneEvent?.properties).to(haveCount(3))
                expect(mocks.eventLog.trackedEvents.map(\.name))
                    .toNot(contain(JourneyEvents.journeyMilestone))
            }

            it("stops executing after goal actions that complete the journey") {
                let flowId = "flow-goal-stop"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .milestone(MilestoneAction(milestoneId: "signup_complete", label: "Signed Up")),
                        .sendEvent(SendEventAction(eventName: "should_not_run", properties: nil)),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow,
                    onMilestone: { _, _, _, _ in
                        await journey.complete(reason: .goalMet, at: Date())
                    }
                )

                _ = await runner.handleRuntimeReady()

                let trackedEvents = mocks.eventLog.trackedEvents.map(\.name)
                expect(trackedEvents).toNot(contain("should_not_run"))
            }

            it("stops executing after goal actions that defer dismissal") {
                let flowId = "flow-goal-deferred-stop"
                let screens = makeJourneyDocument(
                    flowId: flowId,
                    entryActions: [
                        .milestone(MilestoneAction(milestoneId: "signup_complete", label: "Signed Up")),
                        .sendEvent(SendEventAction(eventName: "should_not_run", properties: nil)),
                    ]
                )
                let flow = Experience.test(journey: screens, products: [])
                let experience = makeExperience(flowId: flowId)
                let journey = Journey(experience: experience, distinctId: "user-1", now: Date())
                // Lock-guarded late binding: the @Sendable goal-hit closure needs
                // the runner it is being attached to.
                let runnerBox = LateBound<JourneyRunner>()
                let runner = makeRunner(
                    journey: journey,
                    experience: experience,
                    content: flow,
                    onMilestone: { _, _, _, _ in
                        await runnerBox.get().deferDismiss(reason: .goalMet)
                    }
                )
                runnerBox.set(runner)

                _ = await runner.handleRuntimeReady()

                let trackedEvents = mocks.eventLog.trackedEvents.map(\.name)
                expect(trackedEvents).toNot(contain("should_not_run"))
            }
        }
    }
}

private final class AsyncTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isEntered = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        await withCheckedContinuation { continuation in
            let (entryWaiters, shouldResume): ([CheckedContinuation<Void, Never>], Bool) = lock.withLock {
                isEntered = true
                let waiters = self.entryWaiters
                self.entryWaiters.removeAll()
                if isReleased {
                    return (waiters, true)
                }
                releaseWaiters.append(continuation)
                return (waiters, false)
            }
            entryWaiters.forEach { $0.resume() }
            if shouldResume { continuation.resume() }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if isEntered { return true }
                entryWaiters.append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func release() {
        let waiters = lock.withLock {
            isReleased = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
    }
}

private final class SpyExperienceViewController: ExperienceViewController {
    struct PurchaseRequest {
        let productId: String
        let placementIndex: Any?
    }

    struct OpenLinkRequest {
        let urlString: String
        let target: String?
    }

    struct ViewModelSnapshotRequest {
        let snapshot: ExperienceViewModelSnapshot
        let screenId: String?
    }

    struct ViewModelValueRequest {
        let path: VmPathRef
        let value: Any
        let screenId: String?
        let instanceId: String?
    }

    struct ViewModelListOperationRequest {
        let operation: ExperienceViewModelListOperation
        let path: VmPathRef
        let payload: [String: Any]
        let screenId: String?
        let instanceId: String?
    }

    struct ViewModelTriggerRequest {
        let path: VmPathRef
        let screenId: String?
        let instanceId: String?
    }

    struct NavigationRequest {
        let screenId: String
        let transition: Any?
    }

    private(set) var viewModelSnapshots: [ViewModelSnapshotRequest] = []
    private(set) var viewModelValues: [ViewModelValueRequest] = []
    private(set) var viewModelListOperations: [ViewModelListOperationRequest] = []
    private(set) var viewModelTriggers: [ViewModelTriggerRequest] = []
    private(set) var navigationRequests: [NavigationRequest] = []
    private(set) var purchaseRequests: [PurchaseRequest] = []
    private(set) var restoreRequests = 0
    private(set) var requestNotificationJourneyIds: [String?] = []
    private(set) var requestPermissionRequests: [(permissionType: String, journeyId: String?)] = []
    private(set) var requestTrackingJourneyIds: [String?] = []
    private(set) var dismissRequests: [CloseReason] = []
    private(set) var openLinkRequests: [OpenLinkRequest] = []

    init(content: Experience) {
        let mocks = MockFactory.shared
        let systemEvents = DiscardingSystemEventSink()
        super.init(
            experience: content,
            packageStore: ExperiencePackageStore(),
            eventLog: mocks.eventLog,
            transactionService: TransactionService(
                productService: mocks.productService,
                transactionObserver: MockTransactionObserver(),
                pendingPurchaseStore: InMemoryPendingPurchaseStore(),
                dateProvider: mocks.dateProvider,
                settings: NuxieRuntimeSettings(
                    configuration: NuxieSDK.shared.configuration
                        ?? NuxieConfiguration(apiKey: "test-api-key")
                ),
                eventSink: systemEvents
            ),
            productService: mocks.productService,
            systemEventSink: systemEvents
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func applyViewModelSnapshot(_ snapshot: ExperienceViewModelSnapshot, screenId: String? = nil) {
        viewModelSnapshots.append(ViewModelSnapshotRequest(snapshot: snapshot, screenId: screenId))
    }

    override func applyViewModelValue(
        path: VmPathRef,
        value: Any,
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        viewModelValues.append(
            ViewModelValueRequest(
                path: path,
                value: value,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    override func applyViewModelListOperation(
        _ operation: ExperienceViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        viewModelListOperations.append(
            ViewModelListOperationRequest(
                operation: operation,
                path: path,
                payload: payload,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    override func fireViewModelTrigger(
        path: VmPathRef,
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        viewModelTriggers.append(
            ViewModelTriggerRequest(
                path: path,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    override func navigate(to screenId: String, transition: Any? = nil) {
        navigationRequests.append(NavigationRequest(screenId: screenId, transition: transition))
    }

    override func performPurchase(productId: String, placementIndex: Any? = nil) {
        purchaseRequests.append(PurchaseRequest(productId: productId, placementIndex: placementIndex))
    }

    override func performRestore() {
        restoreRequests += 1
    }

    override func performRequestNotifications(journeyId: String? = nil) {
        requestNotificationJourneyIds.append(journeyId)
    }

    override func performRequestPermission(permissionType: String, journeyId: String? = nil) {
        requestPermissionRequests.append((permissionType: permissionType, journeyId: journeyId))
    }

    override func performRequestTracking(journeyId: String? = nil) {
        requestTrackingJourneyIds.append(journeyId)
    }

    override func performDismiss(reason: CloseReason = .userDismissed) {
        dismissRequests.append(reason)
    }

    override func performOpenLink(urlString: String, target: String? = nil) {
        openLinkRequests.append(OpenLinkRequest(urlString: urlString, target: target))
    }
}

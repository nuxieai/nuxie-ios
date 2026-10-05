#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import XCTest
@testable import Nuxie

final class ExperienceInteractiveEventSourceTests: XCTestCase {
    private let event = ExperienceInteractiveReportedEvent(
        localIndex: 0, coreType: 128, name: "buy", url: "", target: "", delay: 0, properties: []
    )
    private let first = ExperienceInteractiveViewModelReference(rawValue: 20)!
    private let second = ExperienceInteractiveViewModelReference(rawValue: 30)!

    func testSourceFollowsNativeIdentityInsteadOfGraphTraversalOrder() {
        let identities = bindings()
        for (id, alias) in [(UInt64(30), "plan.second"), (20, "plan.first"), (30, "plan.second")] {
            let projected = ExperienceInteractiveEventSource.project(event, nativeID: id,
                rootID: 10, liveIDs: [30, 10, 20], identities: identities)
            XCTAssertNil(projected.sourceRejection)
            XCTAssertEqual(projected.properties, [.init(key: "instanceId", value: .string(alias))])
        }
    }

    func testDetachedReboundUnknownAndAmbiguousSourcesCannotPublishPurchases() {
        var rebound = bindings()
        rebound[.init(viewModelName: "OtherPlan", instanceID: "plan.first")] = second
        var ambiguous = bindings()
        ambiguous[.init(viewModelName: "Plan", instanceID: "another")] = first
        let cases: [(Set<UInt64>, [ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference])] = [
            ([10, 30], bindings()), ([10, 20, 30], rebound), ([10, 20, 30], ambiguous),
        ]
        for (liveIDs, identities) in cases {
            let rejected = ExperienceInteractiveEventSource.project(event, nativeID: 20,
                rootID: 10, liveIDs: liveIDs, identities: identities)
            var router = ExperienceInteractiveEffectRouter()
            let effects = router.project(reportedEvents: [rejected, event], viewModelChanges: [],
                hostCommands: [], controlActionIds: ["buy"], declaredEventNames: [], correlationID: 1)
            guard case .rejectedHostCommand = effects[0].kind else {
                XCTFail("Invalid source reached purchase routing")
                continue
            }
            guard case .controlAction = effects[1].kind else {
                XCTFail("Source rejection discarded a sibling effect")
                continue
            }
            XCTAssertEqual(effects.map(\.sequence), [0, 1])
        }
    }

    func testConflictingOrDuplicateDeclaredSourceIsRejected() {
        for properties: [ExperienceInteractiveField] in [
            [.init(key: "instanceId", value: .string("plan.second"))],
            [.init(key: "instanceId", value: .string("plan.first")),
             .init(key: "instance_id", value: .string("plan.first"))],
        ] {
            let declared = ExperienceInteractiveReportedEvent(localIndex: 0, coreType: 128,
                name: "buy", url: "", target: "", delay: 0, properties: properties)
            XCTAssertNotNil(ExperienceInteractiveEventSource.project(declared, nativeID: 20,
                rootID: 10, liveIDs: [10, 20, 30], identities: bindings()).sourceRejection)
        }
    }

    func testUnnamedRootAndEventsWithoutNativeSourcePreserveExistingScope() {
        XCTAssertEqual(ExperienceInteractiveEventSource.project(event, nativeID: 10,
            rootID: 10, liveIDs: [10], identities: [:]), event)
        XCTAssertEqual(ExperienceInteractiveEventSource.project(event, nativeID: nil,
            rootID: nil, liveIDs: [], identities: [:]), event)
    }

    func testSharedSourcesPublishOnlyLiveEventsWithContiguousSequences() async throws {
        struct Fixture: Decodable {
            struct Case: Decodable {
                struct Alias: Decodable { let model: String; let name: String; let native: UInt64 }
                let name: String
                let source: UInt64?
                let live: [UInt64]
                let aliases: [Alias]
                let declared: String?
                let accepted: Bool
                let alias: String?
            }
            let cases: [Case]
        }
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/events/runtime-event-sources.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        for vector in fixture.cases {
            var properties = [ExperienceInteractiveField(key: "value", value: .string("literal"))]
            if let declared = vector.declared {
                properties.append(.init(key: "instanceId", value: .string(declared)))
            }
            let reported = ExperienceInteractiveReportedEvent(localIndex: 0, coreType: 128,
                name: "selected", url: "", target: "", delay: 0, properties: properties)
            let identities = Dictionary(uniqueKeysWithValues: vector.aliases.map {
                (ExperienceInteractiveViewModelIdentity(viewModelName: $0.model, instanceID: $0.name),
                 ExperienceInteractiveViewModelReference(rawValue: $0.native)!)
            })
            let projected = ExperienceInteractiveEventSource.project(reported, nativeID: vector.source,
                rootID: 1, liveIDs: Set(vector.live), identities: identities)
            var router = ExperienceInteractiveEffectRouter()
            let sibling = ExperienceInteractiveReportedEvent(localIndex: 1, coreType: 128,
                name: "sibling", url: "", target: "", delay: 0, properties: [])
            let effects = router.project(reportedEvents: [projected, sibling], viewModelChanges: [],
                hostCommands: [], declaredEventNames: [], correlationID: 1)
            let drafts: [ScreenEmissionDraft] = effects.compactMap {
                guard case .reportedEvent(let value) = $0.kind else { return nil }
                let payload = Dictionary(uniqueKeysWithValues: value.properties.compactMap { field -> (String, ScreenEmissionValue)? in
                    guard case .string(let text) = field.value else { return nil }
                    return (field.key, .string(text))
                })
                return .event(name: value.name, payload: payload)
            }
            let dispatcher = ScreenEmissionDispatcher(createId: { UUID().uuidString },
                now: { "2026-10-04T12:00:00.000Z" }, executeScriptAction: { _ in [] })
            let result = await dispatcher.dispatch(
                run: ScreenEmissionRun(journeyId: "journey", executionOwnershipEpoch: 0,
                    lifecycleGeneration: 0, presentationEpoch: 0),
                source: ScreenEmissionSource(screenId: "screen", actionId: "runtime:1",
                    componentId: nil, instanceId: vector.alias), drafts: drafts)
            guard case .success(let batch) = result else {
                XCTFail("Publication failed: \(vector.name)"); continue
            }
            XCTAssertEqual(batch.emissions.map(\.name), vector.accepted ? ["selected", "sibling"] : ["sibling"], vector.name)
            XCTAssertEqual(batch.emissions.map(\.sequence), vector.accepted ? [0, 1] : [0], vector.name)
            if vector.accepted {
                XCTAssertEqual(batch.emissions[0].payload["value"], .string("literal"), vector.name)
                XCTAssertEqual(batch.emissions[0].payload["instanceId"], vector.alias.map(ScreenEmissionValue.string), vector.name)
            }
        }
    }

    func testFrameSourcesAreHeldOnlyForTheirInvocation() {
        let source = ExperienceResolvedEventSource(nativeID: 3,
            snapshot: .init(rootInstanceID: 1, instances: [], values: []), schemaNames: [:])
        let sources = ExperienceEventSources()
        sources.put(ExperienceEmissionSources(control: source), invocationID: "first")
        XCTAssertNil(sources.take(invocationID: "second"))
        XCTAssertEqual(sources.take(invocationID: "first")?.control, source)
        XCTAssertNil(sources.take(invocationID: "first"))
    }

    private func bindings() -> [ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference] {
        [.init(viewModelName: "Plan", instanceID: "plan.first"): first,
         .init(viewModelName: "Plan", instanceID: "plan.second"): second]
    }
}
#endif

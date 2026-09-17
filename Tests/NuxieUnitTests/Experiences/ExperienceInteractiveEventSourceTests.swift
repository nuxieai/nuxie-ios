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
        rebound[.init(viewModelName: "Plan", instanceID: "plan.first")] = second
        var ambiguous = bindings()
        ambiguous[.init(viewModelName: "Plan", instanceID: "another")] = first
        let cases: [(Set<UInt64>, [ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference])] = [
            ([10, 30], bindings()), ([10, 20, 30], rebound), ([10, 20], [:]), ([10, 20, 30], ambiguous),
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

    private func bindings() -> [ExperienceInteractiveViewModelIdentity: ExperienceInteractiveViewModelReference] {
        [.init(viewModelName: "Plan", instanceID: "plan.first"): first,
         .init(viewModelName: "Plan", instanceID: "plan.second"): second]
    }
}
#endif

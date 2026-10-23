#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import NuxieRuntime
@_spi(Testing) @testable import Nuxie

final class ExperiencePageHostContractTests: XCTestCase {
    func testPublishedPageNamesAndMissingArtboardRefusal() throws {
        XCTAssertEqual(NativeExperiencePageHost.published.artboardName, "$nuxie.page")
        XCTAssertEqual(NativeExperiencePageHost.published.listPath, "screens")
        XCTAssertEqual(ExperiencePageHostContract.modelName, "$nuxie.Page")
        XCTAssertThrowsError(try ExperiencePageHostContract.requirePage(in: []))
        XCTAssertThrowsError(try ExperiencePageHostContract.requirePage(in: [.init(index: 0, name: "Screen", stateMachines: [], animations: [])]))
        XCTAssertNoThrow(try ExperiencePageHostContract.requirePage(in: [.init(index: 2, name: "$nuxie.page", stateMachines: ["$nuxie.page"], animations: [])]))
    }

    func testV1AcceptsPublishedReferencesPrimitivesAndModals() throws {
        let accepted: [[String: Any]] = [
            ["type": "none"], ["type": "fade"], ["type": "push"],
            ["type": "magic-move", "transitionId": "ab"], ["type": "fade", "transitionId": "ab"],
            ["type": "none", "transitionId": "ab"], ["type": "magic-move", "transitionIds": ["A": "ab"]],
            ["type": "fade", "transitionIds": ["A": "ab"]], ["type": "none", "transitionIds": ["A": "ab"]],
            ["type": "modal"], ["type": "modal", "present": "sheet", "height": "fit-content", "closedby": "none"],
            ["type": "modal", "present": "fullscreen"]
        ]
        for value in accepted { XCTAssertNoThrow(try JourneyReleaseSchemaPrimitives.validateJourneyTransition(value, path: "transition"), "\(value)") }
    }

    func testV1RefusesCustomAndMalformedReferences() {
        let rejected: [[String: Any]] = [
            ["type": "custom", "transitionId": "ab"], ["type": "magic-move"],
            ["type": "magic-move", "transitionId": ""], ["type": "magic-move", "transitionIds": [:]],
            ["type": "fade", "transitionIds": ["A": 1]],
            ["type": "fade", "transitionId": "ab", "transitionIds": ["A": "ab"]],
            ["type": "push", "transitionId": "ab"], ["type": "fade", "durationMs": 400],
            ["type": "modal", "present": "fullscreen", "height": "large"]
        ]
        for value in rejected { XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validateJourneyTransition(value, path: "transition"), "\(value)") }
    }

    func testV2JourneyRouteSelectsIDAtExecutionSourceAndMissingSourceCuts() {
        let raw: [String: Any] = ["type": "magic-move", "transitionIds": ["A": "ab", "C": "cb"]]
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: raw, sourceScreenID: "A").transitionId, "ab")
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: raw, sourceScreenID: "C").transitionId, "cb")
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: raw, sourceScreenID: "missing"), .none)
    }

    func testV3AcceptsOnlyPageKindAndOptionalBooleanMarkers() throws {
        for marker in [nil, false, true] as [Bool?] {
            var transition = validTransition
            transition["defaultPair"] = marker
            transition["incomingKept"] = marker
            XCTAssertNoThrow(try validate(transition))
            let decoded = try JSONDecoder().decode(ExperiencePageHostContract.Transition.self,
                from: JSONSerialization.data(withJSONObject: transition))
            XCTAssertEqual(decoded.planKind, .page)
            XCTAssertEqual(decoded.isDefaultPair, marker == true)
            XCTAssertEqual(decoded.isIncomingKept, marker == true)
        }
        for kind in ["layer", "choreographed", "unknown"] {
            var transition = validTransition; transition["kind"] = kind
            XCTAssertThrowsError(try validate(transition))
        }
        for field in ["defaultPair", "incomingKept"] {
            var transition = validTransition; transition[field] = 1
            XCTAssertThrowsError(try validate(transition))
        }
        var transition = validTransition; transition["incomingOnTop"] = true
        XCTAssertThrowsError(try validate(transition))
        transition = validTransition; transition.removeValue(forKey: "reverse")
        XCTAssertNoThrow(try validate(transition))
    }

    func testV4DurationIsTotalAndReverseUsesCanonicalCompletionNames() throws {
        var transition = validTransition
        transition["durationMs"] = 450
        let decoded = try JSONDecoder().decode(ExperiencePageHostContract.Transition.self,
            from: JSONSerialization.data(withJSONObject: transition))
        XCTAssertEqual(decoded.durationMs, 450)
        XCTAssertEqual(decoded.reverse?.destination.completeEventName, "nx_enter_done:transition.native-contract.reverse")
        transition["destination"] = ["completeEventName": "wrong"]
        XCTAssertThrowsError(try validate(transition))
        transition = validTransition; transition["durationMs"] = -1
        XCTAssertThrowsError(try validate(transition))
        transition = validTransition
        var reverse = try XCTUnwrap(transition["reverse"] as? [String: Any]); reverse["incomingOnTop"] = false
        transition["reverse"] = reverse
        XCTAssertThrowsError(try validate(transition))
    }

    func testInterimHostMetadataIsRefused() throws {
        for field in ["layerHost", "pageHost"] {
            var descriptor = try sourceDescriptor()
            var render = try XCTUnwrap(descriptor["render"] as? [String: Any])
            render[field] = ["artboardName": "LayerList", "list": "screens"]
            descriptor["render"] = render
            XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(descriptor))
        }
    }

    func testMagicMoveWithoutPublishedIDFallsBackToCut() {
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: ["type": "magic-move"]), .none)
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: ["type": "magic-move", "transitionId": ""]), .none)
    }

    func testNavigateToKeptRowUsesUnderAndBackKeepsActualForwardID() {
        XCTAssertEqual(ExperiencePageHostContract.stepID("ab", incomingKept: false, isBack: false), "ab")
        XCTAssertEqual(ExperiencePageHostContract.stepID("ba", incomingKept: true, isBack: false), "ba.under")
        XCTAssertEqual(ExperiencePageHostContract.stepID("ba.under", incomingKept: true, isBack: true), "ba.under")
        XCTAssertNil(ExperiencePageHostContract.stepID(nil, incomingKept: true, isBack: false))
    }

    func testMoveHostCommandsArriveOnNextStepInOrderExactlyOnce() {
        struct FakeNative {
            var pending: [NuxieNativeHostCommand] = []
            mutating func begin() { pending.append(.init(name: "begin", value: .null)) }
            mutating func end() { pending.append(.init(name: "end", value: .null)) }
            mutating func step() -> [NuxieNativeHostCommand] {
                defer { pending.removeAll() }
                return pending
            }
        }
        var native = FakeNative()
        native.begin(); native.end()
        let result = native.step()
        let delivered = ["A", "B"].flatMap { ExperiencePageHostContract.hostCommands(result, row: $0, active: "B") }
        XCTAssertEqual(delivered.map(\.name), ["begin", "end"])
        XCTAssertTrue(native.step().isEmpty)
        let duplicate = NuxieNativeHostCommand(name: "same", value: .null)
        XCTAssertEqual(ExperiencePageHostContract.hostCommands([duplicate, duplicate], row: "B", active: "B").count, 2)
    }

    private var validTransition: [String: Any] {
        ["id": "transition.native-contract", "kind": "page", "sourceScreenId": "screen_1", "destinationScreenId": "screen_2", "durationMs": 450,
         "source": ["completeEventName": "nx_exit_done:transition.native-contract"],
         "destination": ["completeEventName": "nx_enter_done:transition.native-contract"],
         "reverse": ["source": ["completeEventName": "nx_exit_done:transition.native-contract.reverse"],
                     "destination": ["completeEventName": "nx_enter_done:transition.native-contract.reverse"]]]
    }

    private func validate(_ transition: [String: Any]) throws {
        var descriptor = try sourceDescriptor()
        var render = try XCTUnwrap(descriptor["render"] as? [String: Any])
        render["transitions"] = [transition]
        descriptor["render"] = render
        try JourneyReleaseSchemaValidator.validate(descriptor)
    }

    private func sourceDescriptor() throws -> [String: Any] {
        let path = experiencePreparationRepositoryRoot().appendingPathComponent("fixtures/journeys/rendered-custom-transition/release-entry.json")
        let entry = try JSONDecoder().decode(JourneyReleaseProfileEntry.self, from: Data(contentsOf: path))
        let bytes = try XCTUnwrap(Data(base64Encoded: entry.envelope.descriptorBytesBase64))
        func pageForm(_ value: Any) -> Any {
            if var record = value as? [String: Any] {
                if record["type"] as? String == "custom" { record["type"] = "magic-move" }
                return record.mapValues(pageForm)
            }
            if let array = value as? [Any] { return array.map(pageForm) }
            return value
        }
        var descriptor = try XCTUnwrap(pageForm(JSONSerialization.jsonObject(with: bytes)) as? [String: Any])
        var render = try XCTUnwrap(descriptor["render"] as? [String: Any])
        render["transitions"] = [validTransition]
        descriptor["render"] = render
        return descriptor
    }
}
#endif

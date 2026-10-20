#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import NuxieRuntime
@_spi(Testing) @testable import Nuxie

final class ExperienceLayerHostContractTests: XCTestCase {
    private struct Render: Decodable {
        let host: NativeExperienceLayerHost?
        init(from decoder: Decoder) throws { host = try ExperienceLayerHostContract.decode(from: decoder) }
    }

    func testLayerHostIsOptionalAndDecodesThroughTheThinReader() throws {
        XCTAssertNil(try JSONDecoder().decode(Render.self, from: Data("{}".utf8)).host)
        let data = Data(#"{"layerHost":{"artboardName":"LayerList","list":"screens"}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(Render.self, from: data).host,
            NativeExperienceLayerHost(artboardName: "LayerList", listPath: "screens"))
    }

    func testStrictLayerHostAndTransitionKindValidation() throws {
        var descriptor = try sourceDescriptor()
        var render = try XCTUnwrap(descriptor["render"] as? [String: Any])
        render["layerHost"] = ["artboardName": "LayerList", "list": "screens"]
        var transitions = try XCTUnwrap(render["transitions"] as? [[String: Any]])
        for kind in ["layer", "choreographed"] {
            transitions[0]["kind"] = kind
            render["transitions"] = transitions
            descriptor["render"] = render
            XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(descriptor))
            let decoded = try JSONDecoder().decode(ExperienceLayerHostContract.Transition.self,
                from: JSONSerialization.data(withJSONObject: transitions[0]))
            XCTAssertEqual(decoded.planKind, kind == "layer" ? .layer : .choreographed)
        }
        for entry in try cases("layerHosts") {
            render["layerHost"] = entry["value"]
            descriptor["render"] = render
            if entry["accept"] as? Bool == true {
                XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(descriptor))
            } else {
                XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(descriptor), "\(entry)")
            }
        }
        render.removeValue(forKey: "layerHost")
        for entry in try cases("transitionKinds") {
            transitions[0]["kind"] = entry["value"]
            render["transitions"] = transitions
            descriptor["render"] = render
            if entry["accept"] as? Bool == true {
                XCTAssertNoThrow(try JourneyReleaseSchemaValidator.validate(descriptor))
            } else {
                XCTAssertThrowsError(try JourneyReleaseSchemaValidator.validate(descriptor), "\(entry)")
            }
        }
    }

    func testJourneyStylesAcceptOnlyThePublishedFields() throws {
        for entry in try cases("journeyTransitions") {
            let transition = try XCTUnwrap(entry["value"] as? [String: Any])
            if entry["accept"] as? Bool == true {
                XCTAssertNoThrow(try JourneyReleaseSchemaPrimitives.validateJourneyTransition(transition, path: "transition"))
                let spec = ExperienceScreenTransitionSpec(raw: transition)
                XCTAssertEqual(spec.kind.rawValue, transition["type"] as? String)
                XCTAssertEqual(spec.transitionId, transition["transitionId"] as? String)
            } else {
                XCTAssertThrowsError(try JourneyReleaseSchemaPrimitives.validateJourneyTransition(transition, path: "transition"))
            }
        }
    }

    func testMagicMoveWithoutAPublishedIDFallsBackToNone() {
        for id: Any in [NSNull(), "", "  ", 1] {
            XCTAssertEqual(ExperienceScreenTransitionSpec(raw: ["type": "magic-move", "transitionId": id]), .none)
        }
        XCTAssertEqual(ExperienceScreenTransitionSpec(raw: ["type": "magic-move"]), .none)
    }

    func testRowSelectionConvertsACatalogDefaultToASchemaLocalIndex() throws {
        let catalog = NuxieNativeViewModelCatalog(schemas: [
            .init(index: 0, name: "Other", propertyRange: 0..<0,
                authoredInstanceRange: 0..<2, defaultAuthoredInstance: 0, isGlobal: false),
            .init(index: 5, name: "Row", propertyRange: 0..<0,
                authoredInstanceRange: 2..<3, defaultAuthoredInstance: 2, isGlobal: false),
        ], properties: [], authoredInstances: [
            .init(schemaIndex: 0, index: 0, name: "first"),
            .init(schemaIndex: 0, index: 1, name: "second"),
            .init(schemaIndex: 5, index: 0, name: "row"),
        ])
        let selection = try ExperienceLayerHostContract.rowSelection(
            screen: .init(id: "b", defaultViewModelName: "Row"), catalog: catalog)
        XCTAssertEqual(selection.schemaIndex, 5)
        XCTAssertEqual(selection.authoredInstanceIndex, 0)
    }

    func testEachStyleResolvesItsPlanInBothDirections() throws {
        let declaration = interimLayerTransition()
        for style in ["magic-move", "push", "fade", "none"] {
            let spec = ExperienceScreenTransitionSpec(raw: ["type": style, "transitionId": declaration.id])
            let id = try XCTUnwrap(spec.transitionId)
            let forward = try XCTUnwrap(ExperienceScreenCustomTransitionPlan.resolve(transitionId: id,
                sourceScreenId: "screen_1", destinationScreenId: "screen_2", declarations: [declaration]))
            XCTAssertEqual(forward.incomingCompletionEventName, "nx_enter_done:transition.native-contract")
            let reverse = try XCTUnwrap(ExperienceScreenCustomTransitionPlan.resolve(transitionId: id,
                sourceScreenId: "screen_2", destinationScreenId: "screen_1", declarations: [declaration]))
            XCTAssertTrue(reverse.incomingCompletionEventName.hasSuffix(".reverse"))
        }
    }

    private func cases(_ key: String) throws -> [[String: Any]] {
        let path = experiencePreparationRepositoryRoot()
            .appendingPathComponent("fixtures/runtime/layer-host-interim/format-cases.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        return try XCTUnwrap(root[key] as? [[String: Any]])
    }

    private func sourceDescriptor() throws -> [String: Any] {
        let path = experiencePreparationRepositoryRoot().appendingPathComponent("fixtures/journeys/rendered-custom-transition/release-entry.json")
        let entry = try JSONDecoder().decode(JourneyReleaseProfileEntry.self, from: Data(contentsOf: path))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Data(base64Encoded: entry.envelope.descriptorBytesBase64))) as? [String: Any])
    }
}
#endif

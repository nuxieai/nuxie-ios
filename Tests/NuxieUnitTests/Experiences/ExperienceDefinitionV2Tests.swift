import Foundation
import XCTest
@testable import Nuxie

final class ExperienceDefinitionV2Tests: XCTestCase {
    func testGoldenReleaseBuildsRoutesResponsesAndControlActionsDirectly() throws {
        let envelope = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelopeV2.self,
            from: fixtureData("envelope.json")
        )
        let bytes = try XCTUnwrap(Data(base64Encoded: envelope.descriptorBytesBase64))
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        try ExperienceReleaseDescriptorSchemaValidator.validate(object)
        let descriptor = try JSONDecoder().decode(
            ExperienceReleaseDescriptorV2.self,
            from: bytes
        )
        let definition = try ExperienceDefinitionV2(descriptor: descriptor)

        XCTAssertEqual(definition.entryRouteEventName, "$app_opened")
        let route = try XCTUnwrap(
            definition.route(
                host: .screen("screen_welcome"),
                eventName: "continue"
            )
        )
        let actions = try definition.compiledProgram(for: route)
        XCTAssertEqual(actions.count, 3)
        guard case .submitResponse = actions[0],
              case .sendEvent = actions[1],
              case .dismiss = actions[2] else {
            return XCTFail("survey completion must submit, emit, then dismiss")
        }
        XCTAssertEqual(
            definition.responseSchema?.capturesByScreen["screen_welcome"],
            ["plan"]
        )
        guard case .declarative(let controlProgram) = try XCTUnwrap(
            definition.control(screenId: "screen_welcome", actionId: "continue")
        ).binding else {
            return XCTFail("expected declarative Control Action")
        }
        XCTAssertEqual(controlProgram.count, 2)
        guard case .responseSet(field: "plan", value: .invocationValue) = controlProgram[0],
              case .emit(eventName: "continue", payload: [:]) = controlProgram[1] else {
            return XCTFail("response mutation must precede the route event")
        }
    }

    func testDeviceAvailableSelectsAvailableProgramOnDevice() throws {
        let route = JourneyRouteV2(
            key: JourneyRouteKeyV2(host: .journey, eventName: "device-work"),
            revisionSHA256: String(repeating: "a", count: 64),
            program: [.object([
                "type": .string("device_available"),
                "claimWithinMs": .number(1_000),
                "onAvailable": .array([.object([
                    "type": .string("navigate"),
                    "screenId": .string("checkout"),
                ])]),
                "onUnavailable": .array([.object([
                    "type": .string("send_event"),
                    "eventName": .string("device_unavailable"),
                ])]),
            ])]
        )
        let definition = ExperienceDefinitionV2(
            entryRouteEventName: "$app_opened",
            screens: [],
            viewModelValues: [],
            routes: [:],
            executionPlans: [],
            responseSchema: nil,
            controlsByScreen: [:]
        )

        let actions = try definition.compiledProgram(for: route)
        XCTAssertEqual(actions.count, 1)
        guard case .navigate(let navigate) = actions[0] else {
            return XCTFail("device runtime must admit onAvailable")
        }
        XCTAssertEqual(navigate.screenId, "checkout")
    }

    private func fixtureData(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(
            contentsOf: root
                .appendingPathComponent("fixtures/experience-release-descriptor-v2")
                .appendingPathComponent(name)
        )
    }
}

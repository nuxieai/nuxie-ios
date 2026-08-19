import Foundation
import XCTest
@testable import Nuxie

final class ExperienceDefinitionV2Tests: XCTestCase {
    private func goldenDescriptorObject() throws -> [String: Any] {
        let envelope = try JSONDecoder().decode(
            ExperienceReleaseDescriptorEnvelopeV2.self,
            from: fixtureData("envelope.json")
        )
        let bytes = try XCTUnwrap(Data(base64Encoded: envelope.descriptorBytesBase64))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }

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
        let serverStartedPlan = try XCTUnwrap(
            definition.executionPlans.first(where: { $0.startPlane == .server })
        )
        XCTAssertFalse(serverStartedPlan.deviceRegions.isEmpty)
        XCTAssertNotNil(
            definition.executionPlan(id: serverStartedPlan.id)?.deviceRegions.first
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
        guard case .deviceAvailable(let deviceAvailable) = actions[0] else {
            return XCTFail("canonical device_available action must remain intact")
        }
        XCTAssertEqual(deviceAvailable.claimWithinMs, 1_000)
        XCTAssertEqual(deviceAvailable.onAvailable.count, 1)
        XCTAssertEqual(deviceAvailable.onUnavailable.count, 1)
    }

    func testSignedDeviceRegionProjectionInsertsCompilerHandoffAtCursor() throws {
        let route = JourneyRouteV2(
            key: JourneyRouteKeyV2(host: .journey, eventName: "handoff"),
            revisionSHA256: String(repeating: "b", count: 64),
            program: [
                .object(["type": .string("navigate"), "screenId": .string("next")]),
                .object(["type": .string("connector_action"), "accountRef": .string("a"), "toolKey": .string("t"), "payload": .object(["value": .string("x")]), "onSucceeded": .array([]), "onFailed": .array([]), "onTimeout": .array([])])
            ]
        )
        let deviceRegion = JourneyExecutionRegionV2(
            id: "device",
            plane: .device,
            entryCursor: JourneyExecutionCursorV2(programPath: "/program", actionIndex: 0),
            actionPaths: ["/program/0"]
        )
        let serverRegion = JourneyExecutionRegionV2(
            id: "server",
            plane: .server,
            entryCursor: JourneyExecutionCursorV2(programPath: "/program", actionIndex: 1),
            actionPaths: ["/program/1"]
        )
        let plan = JourneyExecutionPlanV2(
            id: "plan",
            route: route.key,
            revisionSHA256: route.revisionSHA256,
            startPlane: .device,
            entryRegionId: deviceRegion.id,
            entryCursor: deviceRegion.entryCursor,
            deviceRegions: [deviceRegion],
            serverRegions: [serverRegion],
            handoffEdges: [JourneyExecutionHandoffEdgeV2(
                id: "edge",
                fromRegionId: deviceRegion.id,
                fromCursor: JourneyExecutionCursorV2(programPath: "/program", actionIndex: 1),
                toRegionId: serverRegion.id,
                toCursor: serverRegion.entryCursor,
                direction: "device_to_server",
                deviceClaimTimeoutMs: nil,
                onDeviceUnavailableRegionId: nil,
                onDeviceUnavailableCursor: nil
            )]
        )
        let definition = ExperienceDefinitionV2(
            entryRouteEventName: "$app_opened",
            screens: [],
            viewModelValues: [],
            routes: [route.key: route],
            executionPlans: [plan],
            responseSchema: nil,
            controlsByScreen: [:]
        )

        let actions = try definition.compiledDeviceRegionProgram(route, plan: plan, region: deviceRegion)
        XCTAssertEqual(actions.count, 2)
        guard case .navigate = actions[0], case .handoff(let handoff) = actions[1] else {
            return XCTFail("device projection must terminate at the signed handoff edge")
        }
        XCTAssertEqual(handoff.edgeId, "edge")
        XCTAssertEqual(handoff.toRegionId, "server")
        XCTAssertEqual(handoff.toNodeId, "/program/1")
    }

    func testSignedDeviceRegionProjectionEmitsTerminalHandoffAtEndOfProgram() throws {
        let route = JourneyRouteV2(
            key: JourneyRouteKeyV2(host: .journey, eventName: "terminal-handoff"),
            revisionSHA256: String(repeating: "c", count: 64),
            program: [
                .object(["type": .string("navigate"), "screenId": .string("next")]),
            ]
        )
        let deviceRegion = JourneyExecutionRegionV2(
            id: "device-terminal",
            plane: .device,
            entryCursor: JourneyExecutionCursorV2(programPath: "/program", actionIndex: 0),
            actionPaths: ["/program/0"]
        )
        let serverRegion = JourneyExecutionRegionV2(
            id: "server-terminal",
            plane: .server,
            entryCursor: JourneyExecutionCursorV2(programPath: "/program", actionIndex: 1),
            actionPaths: []
        )
        let plan = JourneyExecutionPlanV2(
            id: "terminal-plan",
            route: route.key,
            revisionSHA256: route.revisionSHA256,
            startPlane: .device,
            entryRegionId: deviceRegion.id,
            entryCursor: deviceRegion.entryCursor,
            deviceRegions: [deviceRegion],
            serverRegions: [serverRegion],
            handoffEdges: [JourneyExecutionHandoffEdgeV2(
                id: "terminal-edge",
                fromRegionId: deviceRegion.id,
                fromCursor: JourneyExecutionCursorV2(programPath: "/program", actionIndex: 1),
                toRegionId: serverRegion.id,
                toCursor: serverRegion.entryCursor,
                direction: "device_to_server",
                deviceClaimTimeoutMs: nil,
                onDeviceUnavailableRegionId: nil,
                onDeviceUnavailableCursor: nil
            )]
        )
        let definition = ExperienceDefinitionV2(
            entryRouteEventName: "$app_opened",
            screens: [],
            viewModelValues: [],
            routes: [route.key: route],
            executionPlans: [plan],
            responseSchema: nil,
            controlsByScreen: [:]
        )

        let actions = try definition.compiledDeviceRegionProgram(route, plan: plan, region: deviceRegion)
        XCTAssertEqual(actions.count, 2)
        guard case .navigate = actions[0], case .handoff(let handoff) = actions[1] else {
            return XCTFail("terminal device region must hand off after the final authored action")
        }
        XCTAssertEqual(handoff.edgeId, "terminal-edge")
        XCTAssertEqual(handoff.toNodeId, "/program/1")
    }

    func testCanonicalNestedActionsDecodeWithoutLegacyLowering() throws {
        let json: [String: Any] = [
            "type": "condition",
            "branches": [[
                "id": "has-plan",
                "condition": [
                    "type": "Compare",
                    "op": "==",
                    "left": ["type": "Response.Field", "key": "plan"],
                    "right": ["type": "String", "value": "pro"],
                ],
                "program": [[
                    "type": "wait_until",
                    "trigger": ["kind": "event", "eventName": "billing_ready"],
                    "condition": ["type": "Truthy", "value": ["type": "Event.Field", "key": "enabled"]],
                    "maxTimeMs": 10_000,
                    "onSatisfied": [["type": "submit_response"]],
                    "onTimeout": [["type": "exit", "reason": "timeout"]],
                ]],
            ]],
            "defaultProgram": [["type": "dismiss", "reason": "not eligible"]],
        ]

        let actions = try JSONDecoder().decode(
            [JourneyAction].self,
            from: JSONSerialization.data(withJSONObject: [json])
        )
        guard case .condition(let condition) = try XCTUnwrap(actions.first),
              case .compare(let op, let left, let right) = try XCTUnwrap(condition.branches.first?.condition),
              case .responseField("plan") = left,
              case .string("pro") = right,
              op == "==",
              case .waitUntil(let wait) = try XCTUnwrap(condition.branches.first?.program.first),
              case .event(let eventName, _) = wait.trigger,
              eventName == "billing_ready",
              case .truthy(.eventField("enabled")) = try XCTUnwrap(wait.condition),
              case .submitResponse(let submit) = wait.onSatisfied.first else {
            return XCTFail("canonical nested action program did not decode")
        }
        XCTAssertNil(submit.responseSchemaId)
    }

    func testCanonicalActionUnionDecodesEveryPublishedShape() throws {
        let actions: [[String: Any]] = [
            ["type": "navigate", "screenId": "next"],
            ["type": "back", "steps": 1],
            ["type": "delay", "durationMs": 10],
            [
                "type": "time_window", "startTime": "09:00", "endTime": "17:00",
                "timezone": ["kind": "iana", "identifier": "UTC"],
                "daysOfWeek": [1, 2], "onInside": [],
            ],
            [
                "type": "wait_until", "trigger": ["kind": "response_change"],
                "condition": ["type": "Truthy", "value": ["type": "Response.Field", "key": "plan"]],
                "maxTimeMs": 100, "onSatisfied": [], "onTimeout": [],
            ],
            ["type": "condition", "branches": [], "defaultProgram": []],
            [
                "type": "experiment", "experimentId": "exp", "name": "Test", "variants": [[
                    "id": "control", "name": "Control", "percentage": 100,
                    "isHoldout": true, "program": [],
                ]],
            ],
            ["type": "device_available", "claimWithinMs": 100, "onAvailable": [], "onUnavailable": []],
            ["type": "send_event", "eventName": "emitted", "payload": [
                "value": ["type": "String", "value": "ok"],
            ]],
            ["type": "update_customer", "attributes": [
                "plan": ["type": "String", "value": "pro"],
            ]],
            ["type": "milestone", "milestoneId": "done"],
            ["type": "submit_response"],
            [
                "type": "purchase", "placementId": ["literal": "golden:monthly"],
                "onCompleted": [], "onFailed": [], "onCancelled": [],
            ],
            ["type": "restore", "onRestored": [], "onNoPurchases": [], "onFailed": []],
            ["type": "request_notifications"],
            ["type": "request_permission", "permissionType": "camera"],
            ["type": "request_tracking"],
            [
                "type": "open_link", "url": ["type": "String", "value": "https://example.com"],
                "target": "external",
            ],
            ["type": "dismiss"],
            ["type": "exit", "reason": "finished"],
            [
                "type": "call_delegate", "message": "finished", "payload": [
                    "source": ["type": "String", "value": "journey"],
                ],
            ],
            [
                "type": "connector_action", "accountRef": "acct", "toolKey": "tool",
                "payload": ["value": ["type": "Boolean", "value": true]],
                "timeoutMs": 100, "onSucceeded": [], "onFailed": [], "onTimeout": [],
            ],
            [
                "type": "grant_entitlement", "featureId": "pro", "unlimited": true,
                "onSucceeded": [], "onFailed": [], "onTimeout": [],
            ],
        ]

        let decoded = try JSONDecoder().decode(
            [JourneyAction].self,
            from: JSONSerialization.data(withJSONObject: actions)
        )
        XCTAssertEqual(decoded.count, actions.count)
        guard case .updateCustomer(let update) = decoded[9],
              case .string("pro") = update.journeyAttributes["plan"],
              case .purchase(let purchase) = decoded[12],
              let placement = purchase.placementId.value as? [String: Any],
              placement["literal"] as? String == "golden:monthly" else {
            return XCTFail("canonical typed action values were not retained")
        }
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

    func testValidatorRejectsLegacyJourneyActionMetadata() throws {
        var descriptor = try goldenDescriptorObject()
        var journey = try XCTUnwrap(descriptor["journey"] as? [String: Any])
        var routes = try XCTUnwrap(journey["routes"] as? [[String: Any]])
        routes[0]["program"] = [[
            "type": "set_view_model",
            "path": ["kind": "path", "path": "selectedPlan"],
            "value": ["type": "String", "value": "yearly"],
        ]]
        journey["routes"] = routes
        descriptor["journey"] = journey

        XCTAssertThrowsError(try ExperienceReleaseDescriptorSchemaValidator.validate(descriptor))
    }

    func testValidatorRejectsLegacyScreenScriptManifest() throws {
        var descriptor = try goldenDescriptorObject()
        descriptor["screenBehaviors"] = [[
            "screenId": "screen_welcome",
            "controls": [[
                "actionId": "continue",
                "behavior": ["kind": "script"],
            ]],
            "script": [
                "protocol": "listenerAction",
                "artifact": [
                    "key": "assets/sha256/\(String(repeating: "a", count: 64)).bin",
                    "sha256": String(repeating: "a", count: 64),
                    "sizeBytes": 1,
                    "contentType": "application/octet-stream",
                ],
                "exportedActionIds": ["continue"],
            ],
        ]]

        XCTAssertThrowsError(try ExperienceReleaseDescriptorSchemaValidator.validate(descriptor))
    }
}

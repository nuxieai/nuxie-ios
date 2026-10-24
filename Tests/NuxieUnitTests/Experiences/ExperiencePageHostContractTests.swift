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
            XCTAssertNoThrow(try validate(transition))
            let decoded = try JSONDecoder().decode(ExperiencePageHostContract.Transition.self,
                from: JSONSerialization.data(withJSONObject: transition))
            XCTAssertEqual(decoded.planKind, .page)
            XCTAssertEqual(decoded.isDefaultPair, marker == true)
        }
        for kind in ["layer", "choreographed", "unknown"] {
            var transition = validTransition; transition["kind"] = kind
            XCTAssertThrowsError(try validate(transition))
        }
        for field in ["defaultPair"] {
            var transition = validTransition; transition[field] = 1
            XCTAssertThrowsError(try validate(transition))
        }
        for marker in [false, true] {
            var transition = validTransition; transition["incomingKept"] = marker
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
        XCTAssertEqual(decoded.reverse?.durationMs, 900)
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

    func testReverseRequiresBoundedIntegerDuration() throws {
        let root = experiencePreparationRepositoryRoot()
        let bytes = try Data(contentsOf: root.appendingPathComponent("fixtures/runtime/layer-host-interim/format-cases.json"))
        let vectors = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for item in try XCTUnwrap(vectors["reverseDurations"] as? [[String: Any]]) {
            var transition = validTransition
            var reverse = try XCTUnwrap(transition["reverse"] as? [String: Any])
            if item["omit"] as? Bool == true { reverse.removeValue(forKey: "durationMs") }
            else { reverse["durationMs"] = item["value"] }
            transition["reverse"] = reverse
            if item["accept"] as? Bool == true { XCTAssertNoThrow(try validate(transition)) }
            else { XCTAssertThrowsError(try validate(transition)) }
            if item["omit"] as? Bool == true {
                XCTAssertThrowsError(try JSONDecoder().decode(ExperiencePageHostContract.Transition.self,
                    from: JSONSerialization.data(withJSONObject: transition)))
            }
        }
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
         "reverse": ["durationMs": 900, "source": ["completeEventName": "nx_exit_done:transition.native-contract.reverse"],
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
        // Schema-only descriptor. No publisher bytes or retired transition family.
        let bytes = Data(#"""
{
  "identity": {
    "appId": "app-page-contract",
    "buildId": "page-contract-build",
    "environment": "test",
    "experienceId": "page-contract",
    "experienceVersionId": "page-contract-v1",
    "publishedAt": "2026-08-13T00:00:00.000Z",
    "publishedAtSeq": 1811,
    "versionNumber": 1
  },
  "leg": {
    "completionOutputs": {},
    "entryCondition": {
      "type": "app_foregrounded"
    },
    "entryStepId": "entry",
    "facts": {
      "experimentIds": [],
      "propertyKeys": [],
      "segmentIds": []
    },
    "id": "0000000000000000000000000000000000000000000000000000000000000000",
    "inputs": {
      "eventFields": [],
      "responseFields": []
    },
    "offers": [],
    "outputs": [],
    "policy": {
      "entry": {
        "frequency": {
          "type": "every_match"
        },
        "trigger": {
          "eventName": "$app_opened",
          "type": "event"
        }
      },
      "exitWhenAny": []
    },
    "routes": [],
    "schemaVersion": "nuxie.experience-planes.v1",
    "screens": [
      {
        "id": "screen_1",
        "responseCaptures": []
      },
      {
        "id": "screen_2",
        "responseCaptures": []
      }
    ],
    "steps": [
      {
        "id": "entry",
        "kind": "action",
        "action": {
          "type": "navigate",
          "screenId": "screen_1"
        },
        "outlets": {}
      }
    ]
  },
  "metadata": {
    "appDefaultTimezone": "UTC",
    "name": "Inline page contract"
  },
  "placements": [],
  "presentation": {
    "backgroundColor": "#00000000",
    "orientation": "portrait"
  },
  "products": [],
  "provenance": {
    "compilerCommit": "inline-test",
    "compilerVersion": "inline-test"
  },
  "render": {
    "assets": [],
    "nux": {
      "contentType": "application/vnd.nuxie.scene",
      "key": "renders/sha256/0000000000000000000000000000000000000000000000000000000000000000.nux",
      "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
      "sizeBytes": 1
    },
    "renderer": "nux",
    "screens": [
      {
        "id": "screen_1",
        "artboardId": "screen_1",
        "artboardName": "screen_1",
        "width": 390,
        "height": 844
      },
      {
        "id": "screen_2",
        "artboardId": "screen_2",
        "artboardName": "screen_2",
        "width": 390,
        "height": 844
      }
    ],
    "textInputs": [],
    "transitions": []
  },
  "requirements": {
    "luau": {
      "bytecodeVersions": [
        3,
        6
      ],
      "revision": "rive_0_36"
    },
    "minimumSdkVersion": "0.1.0",
    "requiredCapabilities": [
      "nux"
    ],
    "runtimeRevision": "753fcb19fc1d6219cabbd95a7694ca1d13ae2bd8",
    "sceneFormat": {
      "major": 7,
      "minor": 3
    },
    "timezoneData": {
      "format": "iana-tzdb",
      "revision": "2026c",
      "sha256": "d4ad5c12a6be491076f333c9b4f96f60cb8ab552495bbfae0d8cdc9730ecb198"
    }
  },
  "responses": {},
  "ruleGroups": [],
  "schemaVersion": "nuxie.journey-release.v3",
  "screenBehaviors": [
    {
      "controls": [],
      "screenId": "screen_1"
    },
    {
      "controls": [],
      "screenId": "screen_2"
    }
  ],
  "state": {},
  "viewModelValues": []
}
"""#.utf8)
        var descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var render = try XCTUnwrap(descriptor["render"] as? [String: Any])
        render["transitions"] = [validTransition]
        descriptor["render"] = render
        return descriptor
    }
}
#endif

import Foundation
import XCTest

@_spi(Testing) @testable import Nuxie

final class AppActionEncodingTests: XCTestCase {
    func testEveryAppActionMatchesTheEncodingFixture() throws {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        XCTAssertEqual(root["suite"] as? String, "encodings/app-action")
        XCTAssertEqual((root["version"] as? NSNumber)?.intValue, 1)
        let description = try XCTUnwrap(root["description"] as? String)
        for binding in ["RN", "Flutter", "Unity", "UE", "Godot"] {
            XCTAssertTrue(description.contains(binding), "missing \(binding) binding description")
        }

        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        XCTAssertEqual(
            Set(vectors.compactMap { $0["name"] as? String }),
            Set([
                "resolved payload covers every scalar and nested containers",
                "absent payload and optional identifiers remain null",
            ])
        )

        let scalarVector = try XCTUnwrap(vectors.first)
        let scalarAction = try XCTUnwrap(scalarVector["action"] as? [String: Any])
        let scalarPayload = try XCTUnwrap(scalarAction["payload"] as? [String: Any])
        XCTAssertEqual(
            Set(scalarPayload.keys),
            Set(["integer", "boolean", "string", "double", "null", "object", "array"])
        )
        XCTAssertEqual(
            AppActionValue.resolvedRecord(scalarPayload).mapValues(appActionValueCase),
            [
                "integer": "int",
                "boolean": "bool",
                "string": "string",
                "double": "double",
                "object": "string",
                "array": "string",
            ]
        )

        for vector in vectors {
            let vectorName = try XCTUnwrap(vector["name"] as? String)
            let input = try XCTUnwrap(vector["action"] as? [String: Any])
            let experience = try XCTUnwrap(input["experience"] as? [String: Any])
            let rawPayload = input["payload"] as? [String: Any]
            let action = AppAction(
                name: try XCTUnwrap(input["name"] as? String),
                payload: rawPayload.map(AppActionValue.resolvedRecord),
                experience: ExperienceRef(
                    experienceId: try XCTUnwrap(experience["experienceId"] as? String),
                    experienceVersion: experience["experienceVersion"] as? String,
                    journeyId: experience["journeyId"] as? String
                )
            )

            let encoded = try JSONEncoder().encode(action.wireValue)
            let actual = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            )
            let expected = try XCTUnwrap(vector["expect"] as? [String: Any])
            XCTAssertEqual(
                try canonicalJSON(actual),
                try canonicalJSON(expected),
                vectorName
            )
        }
    }

    private func appActionValueCase(_ value: AppActionValue) -> String {
        switch value {
        case .string: "string"
        case .int: "int"
        case .double: "double"
        case .bool: "bool"
        }
    }

    private func canonicalJSON(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/encodings/app-action.json")
    }
}

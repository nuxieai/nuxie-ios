import Foundation
import XCTest

@_spi(Testing) @testable import Nuxie

final class FeatureUsageEncodingTests: XCTestCase {
    func testEveryFeatureUsageAndAccessValueMatchesTheEncodingFixture() throws {
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any]
        )
        XCTAssertEqual(root["suite"] as? String, "encodings/feature-usage")
        XCTAssertEqual((root["version"] as? NSNumber)?.intValue, 1)
        let description = try XCTUnwrap(root["description"] as? String)
        for binding in ["RN", "Flutter", "Unity", "UE", "Godot"] {
            XCTAssertTrue(description.contains(binding), "missing \(binding) binding description")
        }

        let vectors = try XCTUnwrap(root["vectors"] as? [[String: Any]])
        XCTAssertEqual(
            Set(vectors.compactMap { $0["name"] as? String }),
            Set([
                "usage result preserves fractional counters and authoritative access",
                "usage result pins absent optional fields",
                "usage result pins absent nested usage fields",
                "cache-first metered access preserves fractional balance",
                "remote boolean access pins a null balance",
                "remote unlimited access preserves true",
            ])
        )
        var coveredPolicies = Set<String>()
        var coveredFeatureTypes = Set<String>()
        for vector in vectors {
            let vectorName = try XCTUnwrap(vector["name"] as? String)
            let kind = try XCTUnwrap(vector["kind"] as? String)
            let wireValue: [String: AnyCodable]
            switch kind {
            case "featureUsage":
                let result = try XCTUnwrap(vector["result"] as? [String: Any])
                if let access = result["authoritativeAccess"] as? [String: Any] {
                    coveredFeatureTypes.insert(try XCTUnwrap(access["type"] as? String))
                }
                wireValue = try featureUsageResult(from: vector).wireValue
            case "featureAccess":
                let policyName = try XCTUnwrap(vector["policy"] as? String)
                let policy: NuxieSDK.FeatureCheckPolicy
                switch policyName {
                case "cacheFirst": policy = .cacheFirst
                case "remote": policy = .remote
                default: return XCTFail("[\(vectorName)] unknown policy \(policyName)")
                }
                XCTAssertEqual(policy.wireValue, policyName, vectorName)
                coveredPolicies.insert(policyName)
                let access = try XCTUnwrap(vector["access"] as? [String: Any])
                coveredFeatureTypes.insert(try XCTUnwrap(access["type"] as? String))
                wireValue = try featureAccess(from: vector, key: "access").wireValue
            default:
                return XCTFail("[\(vectorName)] unknown vector kind \(kind)")
            }

            let encoded = try JSONEncoder().encode(wireValue)
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

        XCTAssertEqual(coveredPolicies, Set(["cacheFirst", "remote"]))
        XCTAssertEqual(coveredFeatureTypes, Set(["boolean", "metered", "creditSystem"]))
    }

    private func featureUsageResult(from vector: [String: Any]) throws -> FeatureUsageResult {
        let result = try XCTUnwrap(vector["result"] as? [String: Any])
        let usage: FeatureUsageResult.UsageInfo?
        if let value = result["usage"] as? [String: Any] {
            usage = FeatureUsageResult.UsageInfo(
                current: try double(value, key: "current"),
                limit: optionalDouble(value, key: "limit"),
                remaining: optionalDouble(value, key: "remaining")
            )
        } else {
            usage = nil
        }

        let authoritativeAccess: FeatureAccess?
        if result["authoritativeAccess"] is NSNull {
            authoritativeAccess = nil
        } else {
            authoritativeAccess = try featureAccess(from: result, key: "authoritativeAccess")
        }

        return FeatureUsageResult(
            success: try XCTUnwrap(result["success"] as? Bool),
            featureId: try XCTUnwrap(result["featureId"] as? String),
            amountUsed: try double(result, key: "amountUsed"),
            message: result["message"] as? String,
            usage: usage,
            authoritativeAccess: authoritativeAccess
        )
    }

    private func featureAccess(
        from container: [String: Any],
        key: String
    ) throws -> FeatureAccess {
        let value = try XCTUnwrap(container[key] as? [String: Any])
        let rawType = try XCTUnwrap(value["type"] as? String)
        return FeatureAccess(
            allowed: try XCTUnwrap(value["allowed"] as? Bool),
            unlimited: try XCTUnwrap(value["unlimited"] as? Bool),
            balance: optionalDouble(value, key: "balance"),
            type: try XCTUnwrap(FeatureType(rawValue: rawType))
        )
    }

    private func double(_ container: [String: Any], key: String) throws -> Double {
        try XCTUnwrap(container[key] as? NSNumber).doubleValue
    }

    private func optionalDouble(_ container: [String: Any], key: String) -> Double? {
        (container[key] as? NSNumber)?.doubleValue
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
            .appendingPathComponent("fixtures/encodings/feature-usage.json")
    }
}

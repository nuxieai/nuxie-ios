import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie

struct DeviceLegPlaneProfileTestFixture {
    let data: Data
    let profile: JourneyPlaneProfile
    let publicKey: Data
    let root: [String: Any]

    var deliveryAuthority: ProfileDeliveryAuthority {
        let identity = profile.releases[0].locator.identity
        return ProfileDeliveryAuthority(
            appId: identity.appId,
            environment: identity.environment
        )
    }

    static func load(entryKey: String = "entry") throws -> Self {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/release.json")
        let releaseFixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL))
                as? [String: Any]
        )
        let entry = try XCTUnwrap(releaseFixture[entryKey] as? [String: Any])
        let locator = try XCTUnwrap(entry["locator"] as? [String: Any])
        let envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
        let root: [String: Any] = [
            "schemaVersion": "nuxie.journey-plane-profile.v1",
            "status": "ok",
            "delivery": [
                "renderBaseUrl": "https://renders.example.com/",
                "assetBaseUrl": "https://assets.example.com/",
            ],
            "features": [],
            "facts": [
                "properties": ["ready": ["present": true, "value": true]],
                "memberships": [:],
                "assignments": [:],
            ],
            "releases": [entry],
            "armedLegs": [[
                "reference": [
                    "experienceId": locator["experienceId"]!,
                    "versionId": locator["experienceVersionId"]!,
                    "legId": locator["legId"]!,
                    "descriptorSha256": envelope["descriptorSha256"]!,
                ],
                "binding": ["type": "new"],
                "entryCondition": ["type": "app_foregrounded"],
                "context": ["event": [:], "responses": [:]],
            ]],
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        return Self(
            data: data,
            profile: try JourneyPlaneProfile.decode(data),
            publicKey: try XCTUnwrap(Data(base64Encoded: XCTUnwrap(
                releaseFixture["publicKeyBase64"] as? String
            ))),
            root: root
        )
    }

    func invalidSignatureProfile() throws -> JourneyPlaneProfile {
        var changedRoot = root
        var releases = try XCTUnwrap(changedRoot["releases"] as? [[String: Any]])
        var entry = releases[0]
        var envelope = try XCTUnwrap(entry["envelope"] as? [String: Any])
        var signature = try XCTUnwrap(envelope["signature"] as? [String: Any])
        let encoded = try XCTUnwrap(signature["signatureBase64"] as? String)
        signature["signatureBase64"] = (encoded.first == "A" ? "B" : "A")
            + encoded.dropFirst()
        envelope["signature"] = signature
        entry["envelope"] = envelope
        releases[0] = entry
        changedRoot["releases"] = releases
        return try JourneyPlaneProfile.decode(
            JSONSerialization.data(withJSONObject: changedRoot)
        )
    }

    func continuationProfile() throws -> JourneyPlaneProfile {
        var changedRoot = root
        var arms = try XCTUnwrap(changedRoot["armedLegs"] as? [[String: Any]])
        arms[0]["binding"] = [
            "type": "continue",
            "journeyId": "00000000-0000-7000-8000-000000000001",
            "generation": 4,
        ]
        changedRoot["armedLegs"] = arms
        return try JourneyPlaneProfile.decode(
            JSONSerialization.data(withJSONObject: changedRoot)
        )
    }
}

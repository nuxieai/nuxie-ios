import Foundation
@testable import Nuxie

enum TestJourneyProfile {
    static func response(
        features: [Feature] = [],
        properties: ExactJSONObject<JourneyFactTable.Property> = [:],
        memberships: ExactJSONObject<Bool> = [:],
        assignments: ExactJSONObject<JourneyFactTable.Assignment?> = [:]
    ) -> ProfileResponse {
        ProfileResponse(planeProfile: JourneyPlaneProfile(
            schemaVersion: "nuxie.journey-plane-profile.v1",
            status: "ok",
            delivery: JourneyReleaseDelivery(
                renderBaseUrl: "https://renders.example.com/",
                assetBaseUrl: "https://assets.example.com/"
            ),
            features: features,
            facts: JourneyFactTable(
                properties: properties,
                memberships: memberships,
                assignments: assignments
            ),
            armedLegs: [],
            releases: []
        ))
    }
}

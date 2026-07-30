import Foundation
@testable import Nuxie

extension Experience {
    static func test(
        journey: JourneyDocument,
        experienceId: String = "test-experience",
        versionId: String = "test-version",
        products: [ExperienceProduct] = []
    ) -> Experience {
        Experience(
            id: experienceId,
            versionId: versionId,
            name: "Test Experience",
            reentry: .everyTime,
            publishedAt: "2026-07-29T00:00:00Z",
            trigger: nil,
            goal: nil,
            exitPolicy: nil,
            conversionAnchor: nil,
            experienceType: nil,
            journey: journey,
            products: products
        )
    }
}

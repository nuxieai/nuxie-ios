import Foundation

/// Renderer input projected from one authenticated Journey release.
struct Experience: Sendable {
    let id: String
    let versionId: String
    let buildId: String
    let artifactContentHash: String?
    let authenticatedReleaseID: AuthenticatedJourneyReleaseID?
    let behaviorPresentation: ExperienceBehaviorPresentation
    let behaviorPresentationScreens: [String: ExperienceBehaviorScreenGeometry]
    let assetBaseURL: URL
    let journey: JourneyDocument
    let definition: ExperienceDefinition?
    var products: [StoreProduct]
    var introEligibilityAuthorization: IntroEligibilityAuthorizationContext?

    var behaviorPresentationStyle: ExperienceBehaviorPresentationStyle {
        behaviorPresentation.style
    }
    var screens: JourneyDocument { journey }
    var screensId: String { versionId }

    init(
        id: String,
        versionId: String,
        buildId: String,
        artifactContentHash: String?,
        authenticatedReleaseID: AuthenticatedJourneyReleaseID?,
        behaviorPresentation: ExperienceBehaviorPresentation,
        behaviorPresentationScreens: [String: ExperienceBehaviorScreenGeometry],
        assetBaseURL: URL,
        journey: JourneyDocument,
        definition: ExperienceDefinition?,
        products: [StoreProduct] = [],
        introEligibilityAuthorization: IntroEligibilityAuthorizationContext? = nil
    ) {
        self.id = id
        self.versionId = versionId
        self.buildId = buildId
        self.artifactContentHash = artifactContentHash
        self.authenticatedReleaseID = authenticatedReleaseID
        self.behaviorPresentation = behaviorPresentation
        self.behaviorPresentationScreens = behaviorPresentationScreens
        self.assetBaseURL = assetBaseURL
        self.journey = journey
        self.definition = definition
        self.products = products
        self.introEligibilityAuthorization = introEligibilityAuthorization
    }

    func scopedForPresentation(
        products: [StoreProduct] = [],
        introEligibilityAuthorization: IntroEligibilityAuthorizationContext?
    ) -> Self {
        var scoped = self
        scoped.products = products
        scoped.introEligibilityAuthorization = introEligibilityAuthorization
        return scoped
    }

    func shellContract(screenId: String?) -> ExperienceShellContract? {
        guard let screenId = screenId
                ?? (behaviorPresentationScreens.count == 1
                    ? behaviorPresentationScreens.keys.first
                    : nil),
              let screen = behaviorPresentationScreens[screenId] else {
            return nil
        }
        return ExperienceShellContract(
            presentation: behaviorPresentation,
            screen: screen
        )
    }
}

enum CloseReason: Equatable, Sendable {
    case userDismissed
    case goalMet
    case hostDismissed
    case error(Error)

    static func == (lhs: CloseReason, rhs: CloseReason) -> Bool {
        switch (lhs, rhs) {
        case (.userDismissed, .userDismissed),
             (.goalMet, .goalMet),
             (.hostDismissed, .hostDismissed):
            return true
        case let (.error(lhs), .error(rhs)):
            return (lhs as NSError) == (rhs as NSError)
        default:
            return false
        }
    }
}

public enum ProductPeriod: String, Codable, Equatable, Sendable {
    case day
    case week
    case month
    case year
    case lifetime
}

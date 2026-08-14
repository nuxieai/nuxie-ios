import Foundation

enum ExperienceReleaseInitialPresentationResolver {
    enum ResolverError: LocalizedError {
        case invalidURL
        case entryDidNotPresent

        var errorDescription: String? {
            switch self {
            case .invalidURL: "Signed release fixture URL is invalid"
            case .entryDidNotPresent: "Signed release entry did not select a screen"
            }
        }
    }

    static func resolve(
        definition: AuthenticatedExperienceReleaseDefinition,
        cacheRootURL: URL,
        environment: Environment
    ) async throws -> String {
        guard let apiEndpoint = URL(string: "http://127.0.0.1"),
              let assetBaseURL = URL(string: definition.delivery.assetBaseUrl) else {
            throw ResolverError.invalidURL
        }
        let configuration = NuxieConfiguration(apiKey: "fixture-entry")
        configuration.environment = environment
        configuration.apiEndpoint = apiEndpoint
        configuration.customStoragePath = cacheRootURL
        let core = NuxieCore(configuration: configuration)
        let experience = Experience(
            behavior: definition.behavior,
            journey: definition.journey,
            assetBaseURL: assetBaseURL,
            authenticatedReleaseID: definition.releaseID
        )
        let journey = Journey(
            experience: experience,
            distinctId: core.identity.getDistinctId(),
            now: core.dateProvider.now()
        )
        let runner = JourneyRunner(
            journey: journey,
            experience: experience,
            eventLog: core.eventLog,
            identity: core.identity,
            segments: core.segments,
            features: core.features,
            profile: core.profile,
            apiClient: core.api,
            dateProvider: core.dateProvider,
            irRuntime: core.irRuntime,
            persistEntryActionClaim: { _ in true },
            emitsTransitionEvents: false
        )
        try await core.eventLog.configure(configuration: configuration)
        _ = await core.profile.getCachedProfile(
            distinctId: core.identity.getDistinctId()
        )
        let outcome = await runner.advanceUntilPresentation()
        await core.eventLog.close()
        guard case .present(let pending) = outcome else {
            throw ResolverError.entryDidNotPresent
        }
        return pending.screenId
    }
}

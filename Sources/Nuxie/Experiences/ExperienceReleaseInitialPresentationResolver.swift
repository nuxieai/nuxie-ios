import Foundation

enum ExperienceReleaseInitialPresentationResolver {
    enum ResolverError: LocalizedError {
        case entryDidNotPresent

        var errorDescription: String? {
            "Signed release entry did not select a screen"
        }
    }

    static func resolve(
        definition: AuthenticatedExperienceReleaseDefinition,
        cacheRootURL _: URL,
        environment _: Environment
    ) async throws -> String {
        guard let route = definition.definition.route(
            host: .journey,
            eventName: definition.definition.entryRouteEventName
        ) else {
            throw ResolverError.entryDidNotPresent
        }
        for value in route.program {
            guard case .object(let action) = value,
                  case .string("navigate") = action["type"],
                  case .string(let screenId) = action["screenId"] else {
                continue
            }
            return screenId
        }
        throw ResolverError.entryDidNotPresent
    }
}

import Foundation
import NuxieRuntimeSupport

enum ExperiencePackageAuthenticationError: LocalizedError, Sendable {
    case unsupportedPlatform

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "Signed experience packages cannot be authenticated on this platform"
        }
    }
}

protocol ExperiencePackageAuthenticating: Sendable {
    @MainActor
    func authenticate(_ package: AcquiredExperiencePackage) async throws
        -> LoadedExperiencePackage
}

struct AuthenticatedExperienceRuntimeContext {
    let package: LoadedExperiencePackage
    let context: ExperienceRuntimeContext
}

/// Performs the mandatory package import before signed journey content can
/// hydrate the SDK domain model.
struct NativeExperiencePackageAuthenticator: ExperiencePackageAuthenticating {
}

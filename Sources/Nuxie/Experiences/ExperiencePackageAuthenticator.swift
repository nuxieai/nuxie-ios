import Foundation

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
    func authenticate(_ package: LoadedExperiencePackage) async throws
}

/// Performs the mandatory package import before signed journey content can
/// hydrate the SDK domain model.
struct NativeExperiencePackageAuthenticator: ExperiencePackageAuthenticating {
    @MainActor
    func authenticate(_ package: LoadedExperiencePackage) async throws {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let request = try ExperienceRuntimePackageAdapter.makeImportRequest(from: package)
        let attachment = try await NuxieRuntimeAdapter().makeContext(for: request)
        defer { attachment.driver.dispose() }
        try attachment.importResult.validateAuthorizationBinding(to: request)
        #else
        throw ExperiencePackageAuthenticationError.unsupportedPlatform
        #endif
    }
}

import Foundation
import NuxieRuntimeSupport

#if os(iOS) && !targetEnvironment(macCatalyst)
import NuxieRuntimeLegacy
#endif

struct AuthenticatedExperienceRuntimeContext {
    let package: LoadedExperiencePackage
    let context: ExperienceRuntimeContext
}

struct NativeExperiencePackageAuthenticator {}

/// Transitional presentation compatibility only. Product loading authenticates
/// in Swift; UNIV-1831 removes this second native context import at cutover.
extension NativeExperiencePackageAuthenticator {
    @MainActor
    func authenticate(_ package: AcquiredExperiencePackage) async throws
        -> LoadedExperiencePackage {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let authenticated = try await authenticateRetainingContext(package)
        return authenticated.package
        #else
        throw ExperiencePackageAuthenticationError.unsupportedPlatform
        #endif
    }

    @MainActor
    func authenticateRetainingContext(_ package: AcquiredExperiencePackage) async throws
        -> AuthenticatedExperienceRuntimeContext {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let request = try ExperienceRuntimePackageAdapter.makeImportRequest(from: package)
        let context = try await ExperienceRuntimeContextFactory(adapter: NuxieRuntimeAdapter())
            .makeContext(for: request)
        let contents = try LegacyOnlyNuxPackageAuthenticatedHydrator.hydrate(
            package.acquisition
        )
        return AuthenticatedExperienceRuntimeContext(
            package: LoadedExperiencePackage(
                acquired: package,
                manifest: contents.manifest,
                journey: contents.journey
            ),
            context: context
        )
        #else
        throw ExperiencePackageAuthenticationError.unsupportedPlatform
        #endif
    }
}

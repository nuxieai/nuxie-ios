import Nuxie
import XCTest

/// This file intentionally uses a normal import, not `@testable`, so these
/// examples fail to compile if the supported application facade is narrowed.
final class PublicFacadeCompileTests: XCTestCase {
    func testSupportedFacadeTypesRemainVisible() {
        let configuration = NuxieConfiguration(apiKey: "public-api-compile-check")
        configuration.environment = .production
        configuration.logLevel = .warning

        let sdk = NuxieSDK.shared
        _ = sdk.version
        _ = sdk.isSetup
        _ = TriggerResult.self
        _ = TriggerUpdate.self
        _ = FeatureAccessUpdate.self
        _ = ExperienceRef.self
        _ = TriggerError.Code.self
        _ = FeatureAccess.self
        _ = FeatureUsageResult.self
    }

    private func applicationUsageExample(_ sdk: NuxieSDK) async throws {
        let _: TriggerResult = await sdk.triggerAndWait("checkout_started")
        let _: FeatureAccess = try await sdk.hasFeature("premium")
        let _: FeatureUsageResult = try await sdk.useFeatureAndWait("credits")
        try await sdk.setLocaleIdentifier(nil)
        await sdk.dismiss()
    }
}

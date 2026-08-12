import XCTest
@testable import Nuxie
@testable import NuxieTestSupport

final class NuxieConfigurationLifecycleTests: XCTestCase {
    func testSetupSnapshotDoesNotFollowBuilderMutation() {
        let configuration = NuxieConfiguration(apiKey: "snapshot-key")
        configuration.environment = .staging
        configuration.flushAt = 7
        configuration.featureCacheTTL = 42
        configuration.localeIdentifier = "en_US"
        configuration.purchaseHandlingMode = .observer
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let snapshot = NuxieSetupConfiguration(configuration)

        configuration.environment = .development
        configuration.flushAt = 99
        configuration.featureCacheTTL = 999
        configuration.localeIdentifier = "es_ES"
        configuration.purchaseHandlingMode = .full

        XCTAssertEqual(snapshot.environment, .staging)
        XCTAssertEqual(snapshot.flushAt, 7)
        XCTAssertEqual(snapshot.featureCacheTTL, 42)
        XCTAssertEqual(settings.localeIdentifier(), "en_US")
        if case .observer = settings.purchaseHandlingMode() {} else {
            XCTFail("runtime purchase mode should keep its setup value")
        }
    }

    func testRuntimeSettingsApplyOnlyThroughExplicitControls() async {
        let configuration = NuxieConfiguration(apiKey: "runtime-key")
        let firstDelegate = MockPurchaseDelegate()
        let secondDelegate = MockPurchaseDelegate()
        configuration.localeIdentifier = "en_US"
        configuration.purchaseDelegate = firstDelegate
        let settings = NuxieRuntimeSettings(configuration: configuration)

        settings.setLocaleIdentifier("fr_FR")
        settings.setPurchaseDelegate(secondDelegate)
        settings.setPurchaseHandlingMode(.observer)

        XCTAssertEqual(settings.localeIdentifier(), "fr_FR")
        XCTAssertTrue(settings.purchaseDelegate() === secondDelegate)
        if case .observer = settings.purchaseHandlingMode() {} else {
            XCTFail("expected observer mode")
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    settings.setLocaleIdentifier("locale-\(index)")
                    _ = settings.localeIdentifier()
                    settings.setPurchaseHandlingMode(index.isMultiple(of: 2) ? .full : .observer)
                    _ = settings.purchaseHandlingMode()
                }
            }
        }
        XCTAssertTrue(settings.localeIdentifier().hasPrefix("locale-"))
    }

    func testSDKLocaleControlRefreshesWhileBuilderMutationIsIgnored() async throws {
        let sdk = NuxieSDK.shared
        await sdk.shutdown()
        let mocks = MockFactory.shared
        await mocks.resetAll()
        let configuration = NuxieConfiguration(apiKey: "runtime-key")
        configuration.localeIdentifier = "en_US"
        var overrides = mocks.unitTestOverrides()
        overrides.profile = nil
        try sdk.setup(with: configuration, overrides: overrides)
        defer { Task { await sdk.shutdown() } }

        configuration.localeIdentifier = "es_ES"
        _ = try await sdk.refreshProfile()
        let localeAfterBuilderMutation = await mocks.nuxieApi.lastProfileLocale
        XCTAssertEqual(localeAfterBuilderMutation, "en_US")

        _ = try await sdk.setLocaleIdentifier("fr_FR")
        let localeAfterRuntimeControl = await mocks.nuxieApi.lastProfileLocale
        XCTAssertEqual(localeAfterRuntimeControl, "fr_FR")
    }
}

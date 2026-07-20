import Foundation
import FactoryKit
@testable import Nuxie

/// Shared helper for SDK-backed integration tests that need isolated storage.
struct SDKTestHarness {
    let config: NuxieConfiguration
    let storageURL: URL
    let mockApi: MockNuxieApi

    static func make(
        prefix: String,
        trackLifecycleEvents: Bool = false,
        environment: Environment = .development,
        configure: ((inout NuxieConfiguration) -> Void)? = nil
    ) throws -> SDKTestHarness {
        let testId = UUID().uuidString
        let baseURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let storageURL = baseURL.appendingPathComponent("\(prefix)_\(testId)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)

        var config = NuxieConfiguration(apiKey: "test-key-\(testId)")
        config.customStoragePath = storageURL
        config.environment = environment
        config.trackApplicationLifecycleEvents = trackLifecycleEvents
        configure?(&config)

        let mockApi = MockNuxieApi()
        Container.shared.nuxieApi.register { mockApi }

        return SDKTestHarness(config: config, storageURL: storageURL, mockApi: mockApi)
    }

    func setupSDK() throws {
        try NuxieSDK.shared.setup(with: config)
    }

    func cleanup() {
        if NuxieSDK.shared.configuration != nil {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await NuxieSDK.shared.shutdown()
                semaphore.signal()
            }
            let result = semaphore.wait(timeout: .now() + 15.0)
            if result == .timedOut {
                print("WARN: Timed out waiting for NuxieSDK.shutdown (SDKTestHarness.cleanup)")
            }
        }
        try? FileManager.default.removeItem(at: storageURL)
    }
}

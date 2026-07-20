import Foundation
import Quick
import XCTest
import FactoryKit
@testable import Nuxie

/// Global Quick configuration to centralize test setup/teardown.
final class GlobalQuickConfiguration: QuickConfiguration {
  private static let processStoragePath: URL = {
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    return base.appendingPathComponent(
      "nuxie-tests-\(ProcessInfo.processInfo.globallyUniqueString)",
      isDirectory: true
    )
  }()

  override class func configure(_ configuration: QCKConfiguration) {
    configuration.beforeEach {
      MockFactory.resetUsageFlag()

      if NuxieSDK.shared.configuration != nil {
        runAsyncAndWait(description: "NuxieSDK.shutdown (pre)") {
          await NuxieSDK.shared.shutdown()
        }
      }

      if NuxieSDK.shared.configuration == nil {
        Container.shared.sdkConfiguration.register { makeTestConfiguration() }
      }
    }

    configuration.afterEach {
      // Clear any registered network stubs between examples.
      TestURLSessionProvider.reset()

      // Ensure a configuration exists so EventLog resolution doesn't crash in tests
      // that don't call NuxieSDK.setup.
      if NuxieSDK.shared.configuration == nil {
        Container.shared.sdkConfiguration.register { makeTestConfiguration() }
      }

      // Drain queued event work to reduce async noise between tests.
      runAsyncAndWait(description: "EventLog.drain") {
        await Container.shared.eventLog().drain()
      }

      // Shut down the SDK if it was configured during the test.
      if NuxieSDK.shared.configuration != nil {
        runAsyncAndWait(description: "NuxieSDK.shutdown") {
          await NuxieSDK.shared.shutdown()
        }
      }

      if MockFactory.wasUsed {
        runAsyncAndWait(description: "MockFactory.resetAll") {
          await MockFactory.shared.resetAll()
        }
      }

      Container.shared.reset()
      Container.shared.sdkConfiguration.register { makeTestConfiguration() }
    }
  }

  private class func makeTestConfiguration() -> NuxieConfiguration {
    let config = NuxieConfiguration(apiKey: "test-api-key")
    config.customStoragePath = processStoragePath
    return config
  }

  private class func runAsyncAndWait(
    description: String,
    timeout: TimeInterval = 5.0,
    operation: @escaping @Sendable () async -> Void
  ) {
    let lock = NSLock()
    var finished = false

    Task.detached {
      await operation()
      lock.lock()
      finished = true
      lock.unlock()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while true {
      lock.lock()
      let isFinished = finished
      lock.unlock()

      if isFinished {
        return
      }

      if Date() >= deadline {
        break
      }

      // Avoid blocking the main runloop (some tests involve UIKit work).
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }

	    print("WARN: Timed out waiting for \(description)")
	  }
}

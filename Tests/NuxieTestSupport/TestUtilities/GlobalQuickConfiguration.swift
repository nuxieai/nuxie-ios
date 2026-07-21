import Foundation
import Quick
import XCTest
@testable import Nuxie

/// Global Quick configuration to centralize test setup/teardown.
final class GlobalQuickConfiguration: QuickConfiguration {
  override class func configure(_ configuration: QCKConfiguration) {
    configuration.beforeEach {
      MockFactory.resetUsageFlag()

      if NuxieSDK.shared.configuration != nil {
        runAsyncAndWait(description: "NuxieSDK.shutdown (pre)") {
          await NuxieSDK.shared.shutdown()
        }
      }
    }

    configuration.afterEach {
      // Clear any registered network stubs between examples.
      TestURLSessionProvider.reset()

      // Shut down the SDK if it was configured during the test.
      // Shutdown closes the event log, draining queued event work.
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
    }
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

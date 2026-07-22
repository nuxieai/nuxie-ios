import Foundation
import Nimble
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

  /// Lock-guarded completion flag shared between the waiting test thread and
  /// the detached task.
  // @unchecked Sendable: `value` is only accessed under `lock`.
  private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func markFinished() {
      lock.withLock { value = true }
    }

    var isFinished: Bool {
      lock.withLock { value }
    }
  }

  private class func runAsyncAndWait(
    description: String,
    timeout: TimeInterval = 5.0,
    operation: @escaping @Sendable () async -> Void
  ) {
    let flag = CompletionFlag()

    Task.detached {
      await operation()
      flag.markFinished()
    }

    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if flag.isFinished {
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


/// Box that launders a Nimble expectation built inside a @MainActor example
/// across to Nimble's nonisolated async polling/matching methods.
// @unchecked Sendable: Nimble evaluates polled expressions on the main actor,
// so handing the expectation across isolation domains cannot race.
public struct PollingBox<Value>: @unchecked Sendable {
  public let value: Value

  public init(_ value: Value) {
    self.value = value
  }
}

/// Wrap a sync expectation for use with `await ... .toEventually(...)` from a
/// @MainActor example under Swift 6.
public func polling<T>(_ expectation: SyncExpectation<T>) -> PollingBox<SyncExpectation<T>> {
  PollingBox(expectation)
}

/// Wrap an async expectation for use with `await ... .toEventually(...)` from
/// a @MainActor example under Swift 6.
public func polling<T>(_ expectation: AsyncExpectation<T>) -> PollingBox<AsyncExpectation<T>> {
  PollingBox(expectation)
}

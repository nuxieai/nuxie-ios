#if canImport(UIKit)
import XCTest
@testable import Nuxie

final class ExperienceSemanticFrameCompletionTests: XCTestCase {
    func testPresentationWorkWaitsForBothSignalsInEitherOrderAndRunsOnce() {
        for observationFirst in [false, true] {
            let count = Counter()
            let completion = ExperienceRuntimePresentationFrameCompletion({})
            completion.recordPresentedWork { count.increment() }
            if observationFirst {
                completion.signalDrawablePresented(at: 1, provenance: .injectedTestObserver)
            } else {
                completion.recordRenderOutcome(outcome(.presented))
            }
            XCTAssertEqual(count.value, 0)
            if observationFirst {
                completion.recordRenderOutcome(outcome(.presented))
            } else {
                completion.signalDrawablePresented(at: 1, provenance: .injectedTestObserver)
            }
            XCTAssertEqual(count.value, 1)
            completion.signalDrawablePresented(at: 2, provenance: .injectedTestObserver)
            completion.signalFromNative()
            completion.recordPresentedWork { count.increment() }
            XCTAssertEqual(count.value, 1)
        }
    }

    func testLateRegistrationAndFailedRendering() {
        let count = Counter()
        let completion = ExperienceRuntimePresentationFrameCompletion({})
        completion.recordRenderOutcome(outcome(.presented))
        completion.signalDrawablePresented(at: 1, provenance: .injectedTestObserver)
        completion.recordPresentedWork { count.increment() }
        XCTAssertEqual(count.value, 1)
        for disposition: ExperienceRuntimePresentationRenderOutcome.Disposition in [.skippedOccluded, .skippedTimeout, .deviceLost] {
            let failed = ExperienceRuntimePresentationFrameCompletion({})
            failed.recordPresentedWork { count.increment() }
            failed.signalDrawablePresented(at: 1, provenance: .injectedTestObserver)
            failed.recordRenderOutcome(outcome(disposition))
            XCTAssertEqual(count.value, 1)
        }
    }

    private func outcome(_ disposition: ExperienceRuntimePresentationRenderOutcome.Disposition)
        -> ExperienceRuntimePresentationRenderOutcome {
        .init(disposition: disposition, health: .healthy, pixelWidth: 64, pixelHeight: 64, drawCalls: 1)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    }
}
#endif

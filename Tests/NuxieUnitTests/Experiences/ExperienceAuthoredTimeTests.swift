import XCTest
@testable import Nuxie

/// A close's limit counts native time only: authored waits have their own watchdogs.
final class ExperienceAuthoredTimeTests: XCTestCase {
    func testAnAuthoredSpanLongerThanTheNativeLimitFits() async throws {
        let time = ExperienceAuthoredTime()
        let value = try await ExperienceRuntimeRetirement.wait(timeoutNanoseconds: 100_000_000, authoredTime: time) {
            await ExperienceAuthoredTime.during(time) { try? await Task.sleep(nanoseconds: 300_000_000) }
            return 7
        }
        XCTAssertEqual(value, 7)
    }

    func testUnmarkedWorkFailsAtTheNativeLimit() async {
        let time = ExperienceAuthoredTime()
        let started = Date()
        do {
            // The work runs far past the limit, so a loaded host's late timer still wins by a wide margin.
            _ = try await ExperienceRuntimeRetirement.wait(timeoutNanoseconds: 100_000_000, authoredTime: time) {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                return 7
            }
            XCTFail("Unmarked work counts as native time")
        } catch {
            XCTAssertEqual(error as? ExperienceRuntimeRetirementError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "The wait ends at the limit, not when the work does")
    }
}

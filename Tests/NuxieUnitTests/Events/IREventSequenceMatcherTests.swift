import Foundation
import XCTest
@testable import Nuxie

final class IREventSequenceMatcherTests: XCTestCase {
    func testMatchesExhaustiveSubsequenceOracle() throws {
        let schedules: [[TimeInterval]] = [[0, 1, 2, 3, 4], [0, 0, 1, 3, 4]]
        let limits: [TimeInterval?] = [nil, 1, 3]
        for times in schedules {
            for eventMask in 0..<32 {
                let events = try times.indices.map { index in
                    try StoredEvent(id: String(index), name: eventMask & (1 << index) == 0 ? "a" : "b",
                        timestamp: Date(timeIntervalSince1970: times[index]), distinctId: "person")
                }
                for stepCount in 0...3 {
                    let selections = combinations(Array(events.indices), taking: stepCount)
                    for stepMask in 0..<(1 << stepCount) {
                        let steps = (0..<stepCount).map { index in
                            StepQuery(name: stepMask & (1 << index) == 0 ? "a" : "b", predicate: nil)
                        }
                        for overall in limits {
                            for perStep in limits {
                                // Enumerate complete distinct-event subsequences, then check
                                // their constraints. This oracle has no streaming state.
                                let expected = selections.contains { indices in
                                    guard zip(indices, steps).allSatisfy({ events[$0.0].name == $0.1.name }) else { return false }
                                    if indices.count < 2 { return true }
                                    if let overall, times[indices.last!] - times[indices.first!] > overall { return false }
                                    return zip(indices, indices.dropFirst()).allSatisfy {
                                        perStep == nil || times[$0.1] - times[$0.0] <= perStep!
                                    }
                                }
                                XCTAssertEqual(try IREventSequenceMatcher.matches(events: events, steps: steps,
                                    overallWithin: overall, perStepWithin: perStep), expected,
                                    "times=\(times), events=\(eventMask), steps=\(stepCount):\(stepMask), overall=\(String(describing: overall)), perStep=\(String(describing: perStep))")
                            }
                        }
                    }
                }
            }
        }
    }

    private func combinations(_ indices: [Int], taking count: Int) -> [[Int]] {
        if count == 0 { return [[]] }
        guard indices.count >= count else { return [] }
        return indices.enumerated().flatMap { offset, index in
            combinations(Array(indices.dropFirst(offset + 1)), taking: count - 1).map { [index] + $0 }
        }
    }
}

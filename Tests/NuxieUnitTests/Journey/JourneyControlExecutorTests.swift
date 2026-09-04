import Foundation
import XCTest
@testable import Nuxie

final class JourneyControlExecutorTests: XCTestCase {
    func testSharedFlatControlTransitions() throws {
        struct Suite: Decodable {
            struct Vector: Decodable {
                struct Event: Decodable { let name: String; let occurredAtMillis: Int64; let properties: ExactJSONObject<JourneyReleaseJSONValue> }
                struct Signal: Decodable { let event: Event?; let responsesChanged: Bool? }
                struct Expected: Decodable {
                    let kind: String; let stepId: String?; let anchorAtMillis: Int64?; let wakeAtMillis: Int64?
                    let outcome: String?; let actionType: String?; let event: ExactJSONObject<JourneyReleaseJSONValue>?
                }
                let id: String; let step: Journey.Step; let nowMillis: Int64
                let checkpoint: JourneyControlExecutor.Checkpoint?; let signal: Signal?; let expected: Expected
            }
            let context: ArmedJourney.Context
            let assignments: ExactJSONObject<JourneyFactTable.Assignment?>
            let cases: [Vector]
        }
        let suite = try ExactJSONCodec.decode(Suite.self, from: Data(contentsOf: fixture("executor-controls.json")))
        let executor = JourneyControlExecutor(timezones: try SignedTimezoneBundle.load(),
                                                currentDeviceTimezone: TimeZone(identifier: "Etc/UTC")!,
                                                appDefaultTimezone: "Etc/UTC")
        for vector in suite.cases {
            let signal = vector.signal.map { value in
                JourneyControlExecutor.Signal(event: value.event.map {
                    .init(name: $0.name, occurredAtMillis: $0.occurredAtMillis, properties: $0.properties)
                }, responsesChanged: value.responsesChanged == true)
            } ?? .init()
            let result = executor.evaluate(step: vector.step, context: suite.context, assignments: suite.assignments,
                                           nowMillis: vector.nowMillis, checkpoint: vector.checkpoint, signal: signal)
            switch (vector.expected.kind, result) {
            case ("advance", .advance(let stepId, let context, _)):
                XCTAssertEqual(stepId, vector.expected.stepId, vector.id)
                if let event = vector.expected.event {
                    XCTAssertEqual(try ExactJSONCodec.encode(context.event), try ExactJSONCodec.encode(event), vector.id)
                }
            case ("park", .park(let stepId, let checkpoint)):
                XCTAssertEqual(stepId, vector.expected.stepId, vector.id)
                XCTAssertEqual(checkpoint.anchorAtMillis, vector.expected.anchorAtMillis, vector.id)
                XCTAssertEqual(checkpoint.wakeAtMillis, vector.expected.wakeAtMillis, vector.id)
            case ("complete", .complete(let outcome)): XCTAssertEqual(outcome, vector.expected.outcome, vector.id)
            case ("dispatch", .dispatch(let stepId, let action)):
                XCTAssertEqual(stepId, vector.expected.stepId, vector.id)
                if case .string(let type)? = action["type"] { XCTAssertEqual(type, vector.expected.actionType, vector.id) }
                else { XCTFail(vector.id) }
            default: XCTFail("Unexpected result for \(vector.id)")
            }
        }
    }

    func testInvalidOutletsAndDeadlineOverflowFailClosed() throws {
        let executor = JourneyControlExecutor(timezones: try SignedTimezoneBundle.load(),
                                                currentDeviceTimezone: TimeZone(identifier: "Etc/UTC")!,
                                                appDefaultTimezone: "Etc/UTC")
        let context = ArmedJourney.Context(event: [:], responses: [:])
        let delay = Journey.Step(kind: .action, id: "delay",
                                   action: ["type": .string("delay"), "durationMs": .number(1)], outlets: [:], outcome: nil)
        if case .invalid = executor.evaluate(step: delay, context: context, assignments: [:], nowMillis: .max) {} else { XCTFail() }
        for type in ["future_action", "connector_action"] {
            let step = Journey.Step(kind: .action, id: type,
                                    action: ["type": .string(type)], outlets: [:], outcome: nil)
            if case .invalid = executor.evaluate(step: step, context: context, assignments: [:], nowMillis: 0) {}
            else { XCTFail(type) }
        }
        let purchase = Journey.Step(kind: .action, id: "purchase", action: ["type": .string("purchase")],
                                      outlets: ["completed": "done"], outcome: nil)
        if case .advance(let step, _, _) = executor.selectOutlet(purchase, outlet: "completed", context: context) {
            XCTAssertEqual(step, "done")
        } else { XCTFail() }
        if case .invalid = executor.selectOutlet(purchase, outlet: "failed", context: context) {} else { XCTFail() }
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/journeys/planes/\(name)")
    }
}

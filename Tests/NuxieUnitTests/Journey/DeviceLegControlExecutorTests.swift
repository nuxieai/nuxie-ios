import Foundation
import XCTest
@testable import Nuxie

final class DeviceLegControlExecutorTests: XCTestCase {
    func testSharedFlatControlTransitions() throws {
        struct Suite: Decodable {
            struct Vector: Decodable {
                struct Event: Decodable { let name: String; let occurredAtMillis: Int64; let properties: ExactJSONObject<ExperienceReleaseJSONValue> }
                struct Signal: Decodable { let event: Event?; let responsesChanged: Bool? }
                struct Expected: Decodable {
                    struct ExperimentSelection: Decodable {
                        let experimentId: String
                        let variantId: String?
                        let assignedVariantId: String?
                        let source: String
                    }
                    let kind: String; let stepId: String?; let anchorAtMillis: Int64?; let wakeAtMillis: Int64?
                    let outcome: String?; let actionType: String?; let event: ExactJSONObject<ExperienceReleaseJSONValue>?
                    let experimentSelection: ExperimentSelection?
                }
                let id: String; let step: DeviceLeg.Step; let nowMillis: Int64
                let checkpoint: DeviceLegControlExecutor.Checkpoint?; let signal: Signal?; let expected: Expected
            }
            let context: ArmedDeviceLeg.Context
            let assignments: ExactJSONObject<DeviceLegFactTable.Assignment?>
            let cases: [Vector]
        }
        let suite = try ExactJSONCodec.decode(Suite.self, from: Data(contentsOf: fixture("executor-controls.json")))
        let executor = DeviceLegControlExecutor(timezones: try SignedTimezoneBundle.load(),
                                                currentDeviceTimezone: TimeZone(identifier: "Etc/UTC")!,
                                                appDefaultTimezone: "Etc/UTC")
        for vector in suite.cases {
            let signal = vector.signal.map { value in
                DeviceLegControlExecutor.Signal(event: value.event.map {
                    .init(name: $0.name, occurredAtMillis: $0.occurredAtMillis, properties: $0.properties)
                }, responsesChanged: value.responsesChanged == true)
            } ?? .init()
            let result = executor.evaluate(step: vector.step, context: suite.context, assignments: suite.assignments,
                                           nowMillis: vector.nowMillis, checkpoint: vector.checkpoint, signal: signal)
            switch (vector.expected.kind, result) {
            case ("advance", .advance(let stepId, let context, let selection)):
                XCTAssertEqual(stepId, vector.expected.stepId, vector.id)
                if let event = vector.expected.event {
                    XCTAssertEqual(try ExactJSONCodec.encode(context.event), try ExactJSONCodec.encode(event), vector.id)
                }
                if let expected = vector.expected.experimentSelection {
                    let selection = try XCTUnwrap(selection, vector.id)
                    XCTAssertEqual(selection.experimentId, expected.experimentId, vector.id)
                    XCTAssertEqual(selection.variantId, expected.variantId, vector.id)
                    switch selection.source {
                    case .profile:
                        XCTAssertEqual(expected.source, "profile", vector.id)
                        XCTAssertEqual(selection.variantId, expected.assignedVariantId, vector.id)
                    case .noAssignment:
                        XCTAssertEqual(expected.source, "no_assignment", vector.id)
                        XCTAssertNil(expected.assignedVariantId, vector.id)
                    case .invalidAssignment(let assignedVariantId):
                        XCTAssertEqual(expected.source, "invalid_assignment", vector.id)
                        XCTAssertEqual(assignedVariantId, expected.assignedVariantId, vector.id)
                    }
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
        let executor = DeviceLegControlExecutor(timezones: try SignedTimezoneBundle.load(),
                                                currentDeviceTimezone: TimeZone(identifier: "Etc/UTC")!,
                                                appDefaultTimezone: "Etc/UTC")
        let context = ArmedDeviceLeg.Context(event: [:], responses: [:])
        let delay = DeviceLeg.Step(kind: .action, id: "delay",
                                   action: ["type": .string("delay"), "durationMs": .number(1)], outlets: [:], outcome: nil)
        if case .invalid = executor.evaluate(step: delay, context: context, assignments: [:], nowMillis: .max) {} else { XCTFail() }
        let purchase = DeviceLeg.Step(kind: .action, id: "purchase", action: ["type": .string("purchase")],
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

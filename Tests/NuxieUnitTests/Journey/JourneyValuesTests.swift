import Foundation
import XCTest
@testable import Nuxie

final class JourneyValuesTests: XCTestCase {
    func testFormFieldWithoutAnswersDoesNotReadSameNamedState() async throws {
        let bytes = Data(#"{"type":"Response.Field","form":"onboarding","key":"trip_days"}"#.utf8)
        let expression = try JSONDecoder().decode(JourneyValue.self, from: bytes)
        let context = ArmedJourney.Context(event: [:], responses: ["trip_days": .number(99)])
        XCTAssertNil(JourneyValues.resolve(expression, context: context))
        let ir = try JSONDecoder().decode(IRExpr.self, from: bytes)
        let actual = try await IRInterpreter(ctx: EvalContext(now: Date(), responseValues: ["trip_days": .number(99)])).evalValue(ir)
        XCTAssertEqual(actual, .null)
    }

    func testFormQualifiedValuesAndConditionsKeepStateSeparate() async throws {
        let bytes = Data(#"{"type":"Response.Field","form":"onboarding","key":"trip_days"}"#.utf8)
        let expression = try JSONDecoder().decode(JourneyValue.self, from: bytes)
        let ir = try JSONDecoder().decode(IRExpr.self, from: bytes)
        for (answer, expected) in [(21.0, true), (7.0, false)] {
            let context = ArmedJourney.Context(event: [:], responses: ["trip_days": .number(99)],
                formAnswers: ["onboarding": ["trip_days": .number(answer)]])
            XCTAssertEqual(JourneyValues.evaluate(.compare(op: ">", left: expression, right: .number(14)), context: context), expected)
            XCTAssertEqual(JourneyValues.resolve(.responseField("trip_days"), context: context), .number(99))
            XCTAssertNil(JourneyValues.resolve(.responseField("trip_days", form: "unknown"), context: context))
            let interpreter = IRInterpreter(ctx: EvalContext(now: Date(), responseValues: ["trip_days": .number(99)],
                formAnswers: ["onboarding": ["trip_days": .number(answer)]]))
            let actual = try await interpreter.evalValue(ir)
            XCTAssertEqual(actual, .number(answer))
            let state = try await interpreter.evalValue(.responseField(key: "trip_days"))
            XCTAssertEqual(state, .number(99))
            let missing = try await interpreter.evalValue(.responseField(key: "trip_days", form: "unknown"))
            XCTAssertEqual(missing, .null)
            let restored = try JSONDecoder().decode(ArmedJourney.Context.self, from: JSONEncoder().encode(context))
            XCTAssertTrue(restored.formAnswers.isEmpty)
            XCTAssertEqual(restored.responses, context.responses)
        }
        let empty = ArmedJourney.Context(event: [:], responses: [:], formAnswers: ["onboarding": [:]])
        XCTAssertNil(JourneyValues.evaluate(.compare(op: ">", left: expression, right: .number(14)), context: empty))
        XCTAssertEqual(try JSONDecoder().decode(JourneyValue.self, from: JSONEncoder().encode(expression)), expression)
        let encodedIR = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ir)) as? [String: String])
        XCTAssertEqual(encodedIR, ["type": "Response.Field", "form": "onboarding", "key": "trip_days"])
    }

    func testContainsHandlesLongRepeatedPrefixes() {
        let prefix = String(repeating: "a", count: 125_000)
        let context = ArmedJourney.Context(event: [:], responses: [:])
        XCTAssertEqual(JourneyValues.evaluate(.contains(collection: .string(prefix + prefix),
                                                         value: .string(prefix + "b")), context: context), false)
        XCTAssertEqual(JourneyValues.evaluate(.contains(collection: .string(prefix + prefix + "b"),
                                                         value: .string(prefix + "b")), context: context), true)
    }

    func testSharedValueAndThreeValuedConditionVectors() throws {
        struct Vectors: Decodable {
            struct Value: Decodable {
                let id: String
                let expression: JourneyValue
                let known: Bool
                let expected: JourneyReleaseJSONValue
            }
            struct Condition: Decodable {
                let id: String
                let expression: JourneyCondition
                let expected: Bool?
            }
            let context: ArmedJourney.Context
            let customer: ExactJSONObject<JourneyReleaseJSONValue>
            let values: [Value]
            let conditions: [Condition]
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let vectors = try ExactJSONCodec.decode(Vectors.self, from: Data(contentsOf: root.appendingPathComponent("fixtures/journeys/planes/values.json")))
        for vector in vectors.values {
            let actual = JourneyValues.resolve(vector.expression, context: vectors.context, customer: vectors.customer)
            XCTAssertEqual(actual != nil, vector.known, vector.id)
            if let actual {
                XCTAssertEqual(try ExactJSONCodec.encode(actual), try ExactJSONCodec.encode(vector.expected), vector.id)
            }
        }
        for vector in vectors.conditions {
            XCTAssertEqual(JourneyValues.evaluate(vector.expression, context: vectors.context, customer: vectors.customer), vector.expected, vector.id)
        }
    }
}

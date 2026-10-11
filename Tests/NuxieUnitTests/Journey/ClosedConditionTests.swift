import Foundation
import XCTest

@testable import Nuxie

final class ClosedConditionTests: XCTestCase {
  func testAllReviewedSharedVectors() throws {
    struct Vector: Decodable {
      let name: String
      let tree: JourneyReleaseJSONValue
      let facts: ExactJSONObject<JourneyReleaseJSONValue>?
      let now: String
      let zone: String?
      let expect: JourneyReleaseJSONValue?
      let nextClockChange: String?
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let vectors = try ExactJSONCodec.decode(
      [Vector].self,
      from: Data(
        contentsOf: root.appendingPathComponent("fixtures/conditions/condition-vectors.json")))
    XCTAssertEqual(vectors.count, 244)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    for vector in vectors {
      let tree: ClosedCondition
      do {
        tree = try ClosedCondition(json: vector.tree)
      } catch {
        XCTFail("\(vector.name): \(error)")
        continue
      }
      let now = try XCTUnwrap(formatter.date(from: vector.now))
      let facts = ClosedConditionFacts(snapshot: vector.facts ?? [:], now: now, zone: vector.zone)
      if let expected = vector.expect {
        XCTAssertEqual(tree.evaluate(facts).jsonValue, expected, vector.name)
      } else {
        XCTAssertEqual(
          tree.nextClockChange(now: now, zone: vector.zone).map(formatter.string),
          vector.nextClockChange, vector.name)
      }
    }
  }
  func testClosedSchemaRefusesOldOrExtraNodesAndWindowBelowOneMinute() throws {
    for text in [
      #"{"type":"User","key":"tier","op":"eq"}"#, #"{"type":"Bool","value":true,"extra":1}"#,
      #"{"type":"Events.Count","name":"read","within":{"type":"Duration","value":59}}"#,
      #"{"type":"Run.Value","path":"state.tier"}"#,
    ] {
      let raw = try ExactJSONCodec.decode(JourneyReleaseJSONValue.self, from: Data(text.utf8))
      XCTAssertThrowsError(try ClosedCondition(json: raw), text)
    }
  }
}

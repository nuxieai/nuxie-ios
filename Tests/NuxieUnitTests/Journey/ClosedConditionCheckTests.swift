import Foundation
import XCTest

@testable import Nuxie

final class ClosedConditionCheckTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_783_619_940)
  private func tree(_ text: String) throws -> ClosedCondition {
    try ClosedCondition(
      json: ExactJSONCodec.decode(JourneyReleaseJSONValue.self, from: Data(text.utf8)))
  }
  private func facts(_ access: JourneyReleaseJSONValue, after: TimeInterval = 0)
    -> ClosedConditionFacts
  {
    ClosedConditionFacts(
      snapshot: ["access": .object(["pro": access]), "platform": .string("ios")],
      now: now.addingTimeInterval(after), zone: "UTC")
  }
  func testExactAccessDeadlineAndConservativeSubstitution() throws {
    let noPro = try tree(#"{"type":"Not","arg":{"type":"Feature","op":"has","id":"pro"}}"#)
    var check = ClosedConditionCheck()
    let start = check.start(noPro, facts: facts(.null), identity: "a:profile1", mode: .admission)
    XCTAssertEqual(start.outcome, .pending)
    XCTAssertEqual(start.nextWake, now.addingTimeInterval(5))
    XCTAssertEqual(
      check.advance(start.token, facts: facts(.null, after: 4.999), identity: "a:profile1").outcome,
      .pending)
    XCTAssertEqual(
      check.advance(start.token, facts: facts(.null, after: 5), identity: "a:profile1").outcome,
      .refused)
    let early = check.start(noPro, facts: facts(.null), identity: "a:profile1", mode: .admission)
    XCTAssertEqual(
      check.advance(early.token, facts: facts(.bool(false), after: 0.1), identity: "a:profile1")
        .outcome, .satisfied)
    let composite = try tree(
      #"{"type":"And","args":[{"type":"Feature","op":"has","id":"pro"},{"type":"Bool","value":false}]}"#
    )
    let nested = check.start(
      composite, facts: facts(.null), identity: "a:profile1", mode: .admission)
    XCTAssertEqual(
      check.advance(nested.token, facts: facts(.null, after: 5), identity: "a:profile1").outcome,
      .refused)
  }
  func testServerContinuationAndStaleProfileTimers() throws {
    var check = ClosedConditionCheck()
    XCTAssertEqual(try check.continueServer(nil, facts: facts(.bool(true))).outcome, .satisfied)
    let device = try tree(
      #"{"type":"Compare","op":"==","left":{"type":"Env.Platform"},"right":{"type":"String","value":"ios"}}"#
    )
    XCTAssertEqual(try check.continueServer(device, facts: facts(.bool(true))).outcome, .satisfied)
    let noPro = try tree(#"{"type":"Not","arg":{"type":"Feature","op":"has","id":"pro"}}"#)
    let admission = check.start(
      noPro, facts: facts(.null), identity: "a:profile1", mode: .admission)
    XCTAssertEqual(try check.continueServer(nil, facts: facts(.bool(true))).outcome, .satisfied)
    XCTAssertEqual(check.current.outcome, .satisfied)
    XCTAssertEqual(
      check.advance(admission.token, facts: facts(.null, after: 5), identity: "a:profile1").outcome,
      .cancelled)
    XCTAssertEqual(check.current.outcome, .satisfied)
    XCTAssertThrowsError(try check.continueServer(noPro, facts: facts(.bool(true))))
    let old = check.start(noPro, facts: facts(.null), identity: "a:profile1", mode: .admission)
    XCTAssertEqual(
      check.advance(old.token, facts: facts(.bool(false)), identity: "a:profile2").outcome,
      .cancelled)
    let current = check.start(noPro, facts: facts(.null), identity: "b:profile1", mode: .admission)
    XCTAssertEqual(
      check.advance(old.token, facts: facts(.bool(false)), identity: "a:profile1").outcome,
      .cancelled)
    XCTAssertEqual(check.current.outcome, .pending)
    check.cancel()
    XCTAssertEqual(
      check.advance(current.token, facts: facts(.bool(false)), identity: "b:profile1").outcome,
      .cancelled)
  }
  func testImmediateClockAndEventDeadline() throws {
    var check = ClosedConditionCheck()
    let clock = try tree(
      #"{"type":"Compare","op":">=","left":{"type":"Time.Hour"},"right":{"type":"Number","value":18}}"#
    )
    let start = check.start(
      clock, facts: facts(.null), identity: "a", mode: .wait(timeout: 60, eventName: nil))
    XCTAssertEqual(start.outcome, .pending)
    XCTAssertEqual(start.nextWake, now.addingTimeInterval(60))
    XCTAssertEqual(
      check.advance(start.token, facts: facts(.null, after: 60), identity: "a").outcome, .satisfied)
    XCTAssertEqual(
      check.start(
        clock, facts: facts(.null), identity: "a", mode: .wait(timeout: 0, eventName: nil)
      ).outcome, .timeout)
    let yes = try tree(#"{"type":"Bool","value":true}"#)
    XCTAssertEqual(
      check.start(yes, facts: facts(.null), identity: "a", mode: .wait(timeout: 0, eventName: nil))
        .outcome, .satisfied)
    let event = check.start(
      yes, facts: facts(.null), identity: "a", mode: .wait(timeout: 2, eventName: "selected"))
    XCTAssertEqual(
      check.advance(
        event.token, facts: facts(.null, after: 1.999), identity: "a", eventName: "other"
      ).outcome, .pending)
    XCTAssertEqual(
      check.advance(
        event.token, facts: facts(.null, after: 1.999), identity: "a", eventName: "selected"
      ).outcome, .satisfied)
  }
}

import Foundation
import XCTest

@testable import Nuxie

final class ClosedConditionPolicyTests: XCTestCase {
  private func read(_ text: String) throws -> JourneyReleaseJSONValue {
    try ExactJSONCodec.decode(JourneyReleaseJSONValue.self, from: Data(text.utf8))
  }
  func testOneFilterOnEveryTriggerAndNoRetiredEligibility() throws {
    for trigger in [
      #"{"type":"event","eventName":"start"}"#, #"{"type":"api"}"#,
      #"{"type":"server_event","connectorKey":"store","triggerKey":"paid"}"#,
      #"{"type":"segment_enter","segmentId":"gold"}"#,
      #"{"type":"segment_leave","segmentId":"gold"}"#,
    ] {
      let filtered =
        String(trigger.dropLast())
        + #", "condition":{"type":"Not","arg":{"type":"Feature","op":"has","id":"pro"}}}"#
      let policy =
        #"{"entry":{"trigger":TRIGGER,"frequency":{"type":"every_match"}},"exitWhenAny":[]}"#
        .replacingOccurrences(of: "TRIGGER", with: filtered)
      XCTAssertNoThrow(try ClosedConditionPolicy(json: read(policy)))
      XCTAssertThrowsError(
        try ClosedConditionPolicy(
          json: read(
            policy.replacingOccurrences(
              of: #""frequency":"#,
              with: #""eligibility":{"type":"Bool","value":true},"frequency":"#))))
      XCTAssertThrowsError(
        try ClosedConditionPolicy(
          json: read(
            policy.replacingOccurrences(
              of: #""exitWhenAny":[]"#, with: #""exitWhenAny":[{"type":"eligibility_lost"}]"#))))
    }
  }
  func testEntryRunAndSegmentGoalOrExitFiltersStayRefused() throws {
    for extra in [
      #""goal":{"criterion":{"type":"segment_enter","segmentId":"gold","condition":{"type":"Bool","value":true}},"attribution":{"basis":"entry","window":{"amount":1,"unit":"day"}}},"#,
      #""exitWhenAny":[{"type":"segment_leave","segmentId":"gold","condition":{"type":"Bool","value":true}}],"#,
    ] {
      XCTAssertThrowsError(
        try ClosedConditionPolicy(
          json: read(
            "{" + (extra.contains("goal") ? #""exitWhenAny":[],"# : "") + extra
              + #""entry":{"trigger":{"type":"api"},"frequency":{"type":"one_time"}}}"#)))
    }
    XCTAssertThrowsError(
      try ClosedConditionPolicy(
        json: read(
          #"{"entry":{"trigger":{"type":"api","condition":{"type":"Run.Value","path":"responses.onboarding.done"}},"frequency":{"type":"one_time"}},"exitWhenAny":[]}"#
        )))
  }
  func testGoalConditionsReadOccurrenceEvidenceOnly() throws {
    for (node, accepted) in [
      (#"{"type":"Customer.Field","key":"plan"}"#, false),
      (#"{"type":"Event.Field","key":"plan"}"#, true), (#"{"type":"Env.Platform"}"#, true),
      (#"{"type":"Time.Minute"}"#, true),
    ] {
      let policy =
        #"{"entry":{"trigger":{"type":"api"},"frequency":{"type":"one_time"}},"goal":{"criterion":{"type":"event","eventName":"paid","condition":{"type":"Compare","op":"==","left":NODE,"right":{"type":"String","value":"ios"}}},"attribution":{"basis":"entry","window":{"amount":1,"unit":"day"}}},"exitWhenAny":[]}"#
        .replacingOccurrences(of: "NODE", with: node)
      if accepted {
        XCTAssertNoThrow(try ClosedConditionPolicy(json: read(policy)))
      } else {
        XCTAssertThrowsError(try ClosedConditionPolicy(json: read(policy)))
      }
    }
  }
}

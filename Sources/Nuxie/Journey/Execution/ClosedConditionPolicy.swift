import Foundation

/// Prepared signed policy reader, selected with the conditions protocol.
struct ClosedConditionPolicy: Sendable {
  let json: JourneyReleaseJSONValue
  let filter: ClosedCondition?
  private enum Invalid: Error { case policy }
  private typealias Object = ExactJSONObject<JourneyReleaseJSONValue>
  private static func object(
    _ raw: JourneyReleaseJSONValue?, required: Set<String>, optional: Set<String> = []
  ) throws -> Object {
    guard case .object(let value)? = raw, required.isSubset(of: Set(value.keys)),
      Set(value.keys).isSubset(of: required.union(optional))
    else { throw Invalid.policy }
    return value
  }
  private static func text(_ raw: JourneyReleaseJSONValue?) throws -> String {
    guard case .string(let value)? = raw else { throw Invalid.policy }
    return value
  }
  private static func identifier(_ raw: JourneyReleaseJSONValue?) throws {
    let value = try text(raw)
    guard !value.isEmpty, value.utf16.count <= 128,
      value.trimmingCharacters(in: .whitespacesAndNewlines) == value
    else { throw Invalid.policy }
  }
  private static func duration(_ raw: JourneyReleaseJSONValue?) throws -> Double {
    let value = try object(raw, required: ["amount", "unit"])
    guard case .number(let amount)? = value["amount"], amount.isFinite, amount > 0,
      amount.rounded() == amount
    else { throw Invalid.policy }
    let multipliers: [String: Double] = ["minute": 60, "hour": 3600, "day": 86400, "week": 604800]
    guard let multiplier = multipliers[try text(value["unit"])],
      amount * multiplier * 1000 <= 9_007_199_254_740_991
    else { throw Invalid.policy }
    return amount * multiplier
  }
  private static func criterion(
    _ raw: JourneyReleaseJSONValue?, trigger: Bool = false, goal: Bool = false
  ) throws -> ClosedCondition? {
    guard case .object(let value)? = raw else { throw Invalid.policy }
    let kind = try text(value["type"])
    switch kind {
    case "event":
      _ = try object(raw, required: ["type", "eventName"], optional: ["condition"])
      try JourneyReleaseSchemaValidator.policyEvent(text(value["eventName"]))
    case "segment_enter", "segment_leave":
      _ = try object(raw, required: ["type", "segmentId"], optional: trigger ? ["condition"] : [])
      try identifier(value["segmentId"])
    case "api" where trigger:
      _ = try object(raw, required: ["type"], optional: ["condition"])
    case "server_event" where trigger:
      _ = try object(
        raw, required: ["type", "connectorKey", "triggerKey"],
        optional: ["identityField", "condition"])
      for key in ["connectorKey", "triggerKey", "identityField"] where value[key] != nil {
        try identifier(value[key])
      }
    default: throw Invalid.policy
    }
    guard let rawCondition = value["condition"] else { return nil }
    let condition = try ClosedCondition(json: rawCondition)
    let occurrence: Set<String> = [
      "Event.Field", "Time.Hour", "Time.Minute", "Time.Weekday", "Time.Date", "Env.Platform",
    ]
    let mutable: Set<String> = [
      "Customer.Field", "Run.Value", "Feature", "Segment", "Events.Count",
    ]
    for node in condition.nodes() {
      let type = try text(node["type"])
      if trigger && type == "Run.Value" { throw Invalid.policy }
      if goal && mutable.contains(type) && !occurrence.contains(type) { throw Invalid.policy }
      if type == "Events.Count" {
        try JourneyReleaseSchemaValidator.policyEvent(text(node["name"]))
      }
    }
    return condition
  }
  init(json: JourneyReleaseJSONValue) throws {
    let policy = try Self.object(json, required: ["entry", "exitWhenAny"], optional: ["goal"])
    let entry = try Self.object(policy["entry"], required: ["trigger", "frequency"])
    self.filter = try Self.criterion(entry["trigger"], trigger: true)
    guard case .object(let frequency)? = entry["frequency"] else { throw Invalid.policy }
    switch try Self.text(frequency["type"]) {
    case "one_time", "every_match": _ = try Self.object(entry["frequency"], required: ["type"])
    case "once_per_window":
      _ = try Self.object(entry["frequency"], required: ["type", "window"])
      _ = try Self.duration(frequency["window"])
    default: throw Invalid.policy
    }
    if let rawGoal = policy["goal"] {
      let goal = try Self.object(rawGoal, required: ["criterion", "attribution"])
      _ = try Self.criterion(goal["criterion"], goal: true)
      let attribution = try Self.object(goal["attribution"], required: ["basis", "window"])
      guard ["entry", "first_shown"].contains(try Self.text(attribution["basis"])),
        try Self.duration(attribution["window"]) <= 90 * 86400
      else { throw Invalid.policy }
    }
    guard case .array(let exits)? = policy["exitWhenAny"] else { throw Invalid.policy }
    for raw in exits {
      if case .object(let value) = raw, try Self.text(value["type"]) == "goal_met" {
        _ = try Self.object(raw, required: ["type"])
        guard policy["goal"] != nil else { throw Invalid.policy }
      } else {
        _ = try Self.criterion(raw)
      }
    }
    self.json = json
  }
}

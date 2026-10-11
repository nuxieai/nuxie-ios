import Foundation

struct ClosedConditionFacts: Sendable {
  var snapshot: ExactJSONObject<JourneyReleaseJSONValue>
  let now: Date
  let zone: String?
}
enum ClosedConditionResult: Equatable, Sendable {
  case answer(Bool)
  case unavailable
  var jsonValue: JourneyReleaseJSONValue {
    switch self {
    case .answer(let value): return .bool(value)
    case .unavailable: return .string("unavailable")
    }
  }
}

/// The bare Experience tree. Segment IR retains its separate interpreter.
/// Empty snapshots mean missing values; JSON null means a failed snapshot.
struct ClosedCondition: Sendable {
  let json: JourneyReleaseJSONValue
  init(json: JourneyReleaseJSONValue) throws {
    try Self.validate(json)
    self.json = json
  }
  private enum Invalid: Error { case tree }
  private static func record(_ node: JourneyReleaseJSONValue) throws -> ExactJSONObject<
    JourneyReleaseJSONValue
  > {
    guard case .object(let object) = node else { throw Invalid.tree }
    return object
  }
  private static func text(_ value: JourneyReleaseJSONValue?) -> String? {
    guard case .string(let text)? = value else { return nil }
    return text
  }
  private static func validate(_ node: JourneyReleaseJSONValue) throws {
    let object = try record(node)
    guard let kind = text(object["type"]) else { throw Invalid.tree }
    let required: Set<String>
    var optional: Set<String> = []
    var children: [JourneyReleaseJSONValue] = []
    switch kind {
    case "And", "Or":
      required = ["type", "args"]
      guard case .array(let args)? = object["args"] else { throw Invalid.tree }
      children = args
    case "Not":
      required = ["type", "arg"]
      children = [object["arg"] ?? .null]
    case "Compare":
      required = ["type", "op", "left", "right"]
      guard ["==", "!=", "<", "<=", ">", ">="].contains(text(object["op"]) ?? "") else {
        throw Invalid.tree
      }
      children = [object["left"] ?? .null, object["right"] ?? .null]
    case "Contains":
      required = ["type", "collection", "value"]
      children = [object["collection"] ?? .null, object["value"] ?? .null]
    case "List":
      required = ["type", "value"]
      guard case .array(let items)? = object["value"] else { throw Invalid.tree }
      children = items
    case "String":
      required = ["type", "value"]
      guard text(object["value"]) != nil else { throw Invalid.tree }
    case "Number":
      required = ["type", "value"]
      guard case .number(let value)? = object["value"], value.isFinite else { throw Invalid.tree }
    case "Bool":
      required = ["type", "value"]
      guard case .bool? = object["value"] else { throw Invalid.tree }
    case "Event.Field", "Customer.Field":
      required = ["type", "key"]
      guard let key = text(object["key"]), !key.isEmpty else { throw Invalid.tree }
    case "Run.Value":
      required = ["type", "path"]
      guard let path = text(object["path"]),
        ["experience.", "responses."].contains(where: {
          path.utf8.starts(with: $0.utf8) && path.utf16.count > $0.utf16.count
        })
      else { throw Invalid.tree }
    case "Feature", "Segment":
      required = ["type", "op", "id"]
      guard let id = text(object["id"]), !id.isEmpty,
        text(object["op"]) == (kind == "Feature" ? "has" : "is_member")
      else { throw Invalid.tree }
    case "Events.Count":
      required = ["type", "name"]
      optional = ["within"]
      guard let name = text(object["name"]), !name.isEmpty else { throw Invalid.tree }
      if let window = object["within"] {
        let duration = try record(window)
        guard Set(duration.keys) == ["type", "value"], text(duration["type"]) == "Duration",
          case .number(let value)? = duration["value"], value.rounded() == value, value >= 60,
          value <= 31_622_400
        else { throw Invalid.tree }
      }
    case "Null", "Time.Hour", "Time.Minute", "Time.Weekday", "Time.Date", "Env.Platform":
      required = ["type"]
    default: throw Invalid.tree
    }
    let keys = Set(object.keys)
    guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
      throw Invalid.tree
    }
    try children.forEach(validate)
  }
  func nodes() -> [ExactJSONObject<JourneyReleaseJSONValue>] {
    func visit(_ json: JourneyReleaseJSONValue) -> [ExactJSONObject<JourneyReleaseJSONValue>] {
      guard case .object(let object) = json else { return [] }
      let kind = Self.text(object["type"])
      let children: [JourneyReleaseJSONValue]
      switch kind {
      case "And", "Or":
        if case .array(let values)? = object["args"] { children = values } else { children = [] }
      case "List":
        if case .array(let values)? = object["value"] { children = values } else { children = [] }
      case "Not": children = [object["arg"] ?? .null]
      case "Compare": children = [object["left"] ?? .null, object["right"] ?? .null]
      case "Contains": children = [object["collection"] ?? .null, object["value"] ?? .null]
      default: children = []
      }
      return [object] + children.flatMap(visit)
    }
    return visit(json)
  }
  func featureIds() -> [String] {
    nodes().filter { Self.text($0["type"]) == "Feature" }.compactMap { Self.text($0["id"]) }
  }

  func evaluate(_ facts: ClosedConditionFacts) -> ClosedConditionResult {
    var unavailable = false
    func failed() -> JourneyReleaseJSONValue {
      unavailable = true
      return .null
    }
    func field(_ snapshot: JourneyReleaseJSONValue?, _ key: String) -> JourneyReleaseJSONValue {
      if case .null? = snapshot { return failed() }
      guard case .object(let values)? = snapshot else { return .null }
      return values[key] ?? .null
    }
    func read(_ raw: JourneyReleaseJSONValue) -> JourneyReleaseJSONValue {
      guard case .object(let node) = raw, let kind = Self.text(node["type"]) else {
        return failed()
      }
      switch kind {
      case "Null": return .null
      case "String", "Number", "Bool": return node["value"] ?? .null
      case "List":
        guard case .array(let values)? = node["value"] else { return failed() }
        return .array(values.map(read))
      case "Event.Field": return field(facts.snapshot["event"], Self.text(node["key"])!)
      case "Customer.Field": return field(facts.snapshot["customer"], Self.text(node["key"])!)
      case "Feature": return field(facts.snapshot["access"], Self.text(node["id"])!)
      case "Segment":
        guard case .object(let memberships)? = facts.snapshot["memberships"],
          let value = memberships[Self.text(node["id"])!]
        else { return failed() }
        return value
      case "Run.Value":
        if case .null? = facts.snapshot["run"] { return failed() }
        var value = facts.snapshot["run"] ?? .null
        for key in Self.text(node["path"])!.utf8.split(
          separator: 46, omittingEmptySubsequences: false)
        {
          guard case .object(let values) = value else { return .null }
          value = values[String(decoding: key, as: UTF8.self)] ?? .null
        }
        return value
      case "Events.Count":
        let wanted: JourneyReleaseJSONValue
        if case .object(let duration)? = node["within"] {
          wanted = duration["value"] ?? .null
        } else {
          wanted = .null
        }
        guard case .array(let counts)? = facts.snapshot["counts"] else { return failed() }
        for raw in counts.reversed() {
          guard case .object(let count) = raw, Self.equal(count["name"] ?? .null, node["name"]!),
            Self.equal(count["withinSeconds"] ?? .null, wanted)
          else { continue }
          guard case .number(let value)? = count["count"], value.isFinite, value.rounded() == value,
            value >= 0, value <= 9_007_199_254_740_991
          else { return failed() }
          return .number(value)
        }
        return failed()
      case "Env.Platform":
        guard let platform = Self.text(facts.snapshot["platform"]),
          ["ios", "android", "macos", "web"].contains(platform)
        else { return failed() }
        return .string(platform)
      case "Time.Hour", "Time.Minute", "Time.Weekday", "Time.Date":
        return Self.clock(now: facts.now, zone: facts.zone)?[kind] ?? failed()
      case "Not": return .bool(read(node["arg"]!) != .bool(true))
      case "And", "Or":
        guard case .array(let args)? = node["args"] else { return failed() }
        let answers = args.map(read)
        return .bool(
          kind == "And" ? answers.allSatisfy { $0 == .bool(true) } : answers.contains(.bool(true)))
      case "Contains":
        let collection = read(node["collection"]!)
        let value = read(node["value"]!)
        if collection == .null || value == .null { return .bool(false) }
        if case .array(let items) = collection {
          return .bool(items.contains { Self.equal($0, value) })
        }
        if case .string(let text) = collection, case .string(let needle) = value {
          return .bool(
            (text as NSString).range(of: needle, options: .literal).location != NSNotFound)
        }
        return .bool(false)
      case "Compare":
        let left = read(node["left"]!)
        let right = read(node["right"]!)
        let op = Self.text(node["op"])!
        let explicitNull = [node["left"], node["right"]].contains { raw in
          if case .object(let value)? = raw { return Self.text(value["type"]) == "Null" }
          return false
        }
        if ["==", "!="].contains(op), explicitNull {
          let bothNull = left == .null && right == .null
          return .bool(op == "==" ? bothNull : !bothNull)
        }
        if left == .null || right == .null { return .bool(false) }
        if op == "==" { return .bool(Self.equal(left, right)) }
        if op == "!=" { return .bool(!Self.equal(left, right)) }
        let order: Int
        switch (left, right) {
        case (.number(let a), .number(let b)): order = a == b ? 0 : a < b ? -1 : 1
        case (.string(let a), .string(let b)):
          order =
            a.utf16.elementsEqual(b.utf16) ? 0 : a.utf16.lexicographicallyPrecedes(b.utf16) ? -1 : 1
        default: return .bool(false)
        }
        switch op {
        case "<": return .bool(order < 0)
        case "<=": return .bool(order <= 0)
        case ">": return .bool(order > 0)
        default: return .bool(order >= 0)
        }
      default: return failed()
      }
    }
    let answer = read(json)
    return unavailable ? .unavailable : .answer(answer == .bool(true))
  }
  private static func equal(_ a: JourneyReleaseJSONValue, _ b: JourneyReleaseJSONValue) -> Bool {
    switch (a, b) {
    case (.string(let x), .string(let y)): return x.utf16.elementsEqual(y.utf16)
    case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy(equal)
    case (.object(let x), .object(let y)):
      return x.count == y.count
        && x.allSatisfy { key, value in y[key].map { equal(value, $0) } ?? false }
    default: return a == b
    }
  }
  private static func clock(now: Date, zone: String?) -> [String: JourneyReleaseJSONValue]? {
    guard now.timeIntervalSince1970.isFinite, let zone, let bundle = SignedTimezoneBundle.installed,
      let timezone = try? bundle.resolveDeviceIdentifier(zone),
      let offset = try? bundle.offsetSeconds(for: timezone, at: now)
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let c = calendar.dateComponents(
      [.year, .month, .day, .weekday, .hour, .minute, .second],
      from: now.addingTimeInterval(TimeInterval(offset)))
    guard let year = c.year, let month = c.month, let day = c.day, let weekday = c.weekday,
      let hour = c.hour, let minute = c.minute, let second = c.second
    else { return nil }
    return [
      "Time.Hour": .number(Double(hour)), "Time.Minute": .number(Double(minute)),
      "Time.Weekday": .string(["sun", "mon", "tue", "wed", "thu", "fri", "sat"][weekday - 1]),
      "Time.Date": .string(String(format: "%04d-%02d-%02d", year, month, day)),
      "second": .number(Double(second)),
    ]
  }
  func nextClockChange(now: Date, zone: String?) -> Date? {
    let keys = Set(
      nodes().compactMap { Self.text($0["type"]) }.filter {
        ["Time.Hour", "Time.Minute", "Time.Weekday", "Time.Date"].contains($0)
      })
    guard !keys.isEmpty, let initial = Self.clock(now: now, zone: zone),
      case .number(let second)? = initial["second"]
    else { return nil }
    let first = floor(now.timeIntervalSince1970) + (60 - second)
    for instant in stride(from: first, through: now.timeIntervalSince1970 + 48 * 3_600, by: 60) {
      let date = Date(timeIntervalSince1970: instant)
      guard let current = Self.clock(now: date, zone: zone) else { return nil }
      if keys.contains(where: { initial[$0] != current[$0] }) { return date }
    }
    return nil
  }
}

import Foundation

/// Prepared continuation. The owner arms nextWake and fences the token by
/// person and profile revision. Starting a new check invalidates prior timers.
struct ClosedConditionCheck: Sendable {
  enum Outcome: Equatable, Sendable {
    case pending, satisfied, refused, timeout, unavailable, cancelled
  }
  enum Mode: Sendable {
    case admission
    case wait(timeout: TimeInterval, eventName: String?)
  }
  struct State: Equatable, Sendable {
    let token: UInt64
    let outcome: Outcome
    let nextWake: Date?
  }
  private struct Check: Sendable {
    let tree: ClosedCondition
    let identity: String
    let mode: Mode
    let deadline: Date
  }
  private var generation: UInt64 = 0
  private var check: Check?
  private(set) var current = State(token: 0, outcome: .cancelled, nextWake: nil)
  mutating func cancel() {
    generation &+= 1
    check = nil
    current = State(token: generation, outcome: .cancelled, nextWake: nil)
  }
  mutating func start(
    _ tree: ClosedCondition, facts: ClosedConditionFacts, identity: String, mode: Mode
  ) -> State {
    generation &+= 1
    let timeout: TimeInterval
    switch mode {
    case .admission: timeout = 5
    case .wait(let duration, _): timeout = duration
    }
    guard timeout.isFinite, timeout >= 0, facts.now.timeIntervalSince1970.isFinite,
      (facts.now.timeIntervalSince1970 + timeout).isFinite
    else {
      check = nil
      current = State(token: generation, outcome: .unavailable, nextWake: nil)
      return current
    }
    let deadline = facts.now.addingTimeInterval(timeout)
    check = Check(tree: tree, identity: identity, mode: mode, deadline: deadline)
    current = State(token: generation, outcome: .pending, nextWake: deadline)
    return advance(generation, facts: facts, identity: identity)
  }
  mutating func advance(
    _ token: UInt64, facts input: ClosedConditionFacts, identity: String, eventName: String? = nil
  ) -> State {
    let cancelled = State(token: token, outcome: .cancelled, nextWake: nil)
    guard token == generation, let check else { return cancelled }
    guard check.identity.utf8.elementsEqual(identity.utf8) else {
      cancel()
      return cancelled
    }
    guard current.outcome == .pending else { return current }
    let expired = input.now >= check.deadline
    if case .wait(_, let expected?) = check.mode,
      !expected.utf8.elementsEqual((eventName ?? "").utf8)
    {
      if expired { current = State(token: token, outcome: .timeout, nextWake: nil) }
      return current
    }
    var facts = input
    if case .admission = check.mode {
      let unknown = check.tree.featureIds().filter { id in
        if case .object(let access)? = facts.snapshot["access"] { return access[id] == .null }
        return false
      }
      if !unknown.isEmpty && !expired { return current }
      if !unknown.isEmpty, case .object(var access)? = facts.snapshot["access"] {
        for id in unknown { access[id] = .bool(true) }
        facts.snapshot["access"] = .object(access)
      }
    }
    let outcome: Outcome
    switch check.tree.evaluate(facts) {
    case .answer(true): outcome = .satisfied
    case .unavailable: outcome = .unavailable
    case .answer(false):
      switch check.mode {
      case .admission: outcome = .refused
      case .wait: outcome = expired ? .timeout : .pending
      }
    }
    current = State(
      token: token, outcome: outcome,
      nextWake: outcome == .pending
        ? min(
          check.deadline,
          check.tree.nextClockChange(now: facts.now, zone: facts.zone) ?? check.deadline) : nil)
    return current
  }
  enum InvalidContinuation: Error { case personFact }
  mutating func continueServer(_ deviceRemainder: ClosedCondition?, facts: ClosedConditionFacts)
    throws
    -> State
  {
    let allowed: Set<String> = [
      "And", "Or", "Not", "Compare", "Contains", "String", "Number", "Bool", "List", "Null",
      "Env.Platform",
    ]
    if let deviceRemainder {
      guard
        deviceRemainder.nodes().allSatisfy({ node in
          if case .string(let kind)? = node["type"] { return allowed.contains(kind) }
          return false
        })
      else { throw InvalidContinuation.personFact }
    }
    let outcome: Outcome
    switch deviceRemainder?.evaluate(facts) {
    case .answer(true), nil: outcome = .satisfied
    case .answer(false): outcome = .refused
    case .unavailable: outcome = .unavailable
    }
    generation &+= 1
    check = nil
    current = State(token: generation, outcome: outcome, nextWake: nil)
    return current
  }
}

import Foundation

/// An input the device has captured but not yet put in the ordered queue,
/// such as a renderer emission waiting for its publication to commit.
struct StagedJourneyInput: Sendable {
  let eventId: String
  let distinctId: String
  let occurredAt: Date
}

/// Each customer's input watermark W: the latest time up to which every input
/// the device has captured is committed and in the ordered queue.
///
/// A deadline at D runs only once W has passed D. W is worked out afresh each
/// time a deadline asks: it is now, or just before the earliest input of that
/// customer still in flight, so an input at exactly D holds the deadline (the
/// wait window is inclusive). While that customer's recovery is pending, or a
/// read of committed routes has failed, W does not pass any deadline. A
/// deadline's answer is final once it runs; nothing here reopens it.
final class CustomerInputWatermark: @unchecked Sendable {
  /// How long a staged input may hold its customer's deadlines, on the
  /// monotonic clock. iOS has no separate renderer flush interval: a renderer
  /// batch is handed to its Journey as soon as its frame's native step returns
  /// (`ExperienceScreenViewController.deliverStep`), then staged until its
  /// events commit.
  /// The bound is the ordered queue's retry interval, so a deadline that waits
  /// on a staged input is asked again exactly once before that input counts as
  /// late.
  static let stagingBound: TimeInterval = OrderedCustomerQueue.retryInterval

  private struct Input {
    var distinctId: String
    var occurredAt: Date
    let stagedAt: TimeInterval
  }

  private let lock = NSLock()
  private var inputs: [String: Input] = [:]
  private var recovering: Set<String> = []
  private var uptime: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

  /// Tests replace the monotonic clock that times the staging bound.
  func setUptime(_ uptime: @escaping @Sendable () -> TimeInterval) {
    lock.withLock { self.uptime = uptime }
  }

  func stage(_ input: StagedJourneyInput) {
    lock.withLock {
      guard inputs[input.eventId] == nil else { return }
      inputs[input.eventId] = .init(distinctId: input.distinctId, occurredAt: input.occurredAt,
                                    stagedAt: uptime())
    }
  }

  /// A capture staged before its event id was known keeps its staging time.
  func rename(_ token: String, to eventId: String, occurredAt: Date) {
    lock.withLock {
      guard var input = inputs.removeValue(forKey: token) else { return }
      input.occurredAt = occurredAt
      if inputs[eventId] == nil { inputs[eventId] = input }
    }
  }

  /// The input entered the ordered queue, or was dropped.
  func release(_ eventId: String) {
    _ = lock.withLock { inputs.removeValue(forKey: eventId) }
  }

  /// On sign-in the captured inputs move with the customer.
  func reassign(from oldDistinctId: String, to newDistinctId: String) {
    lock.withLock {
      for (eventId, input) in inputs where input.distinctId == oldDistinctId {
        inputs[eventId]?.distinctId = newDistinctId
      }
    }
  }

  func beginRecovery(_ distinctId: String) {
    _ = lock.withLock { recovering.insert(distinctId) }
  }

  func endRecovery(_ distinctId: String) {
    _ = lock.withLock { recovering.remove(distinctId) }
  }

  /// The earliest occurrence time of this customer's live staged inputs, or
  /// nil when nothing is in flight. Inputs staged longer than the bound no
  /// longer count and are forgotten.
  private func earliestInFlight(_ distinctId: String) -> Date? {
    let now = uptime()
    inputs = inputs.filter { now - $0.value.stagedAt < Self.stagingBound }
    return inputs.values.filter { $0.distinctId == distinctId }.map(\.occurredAt).min()
  }

  /// Where W stands: at now, or just before an input still in flight.
  enum Watermark: Equatable, Sendable {
    case at(Date)
    case justBefore(Date)
  }

  /// W for this customer, worked out now. Nil while its recovery is pending
  /// or a read of committed routes has failed: W does not advance then.
  func watermark(for distinctId: String, now: Date, readFailed: Bool) -> Watermark? {
    lock.withLock {
      guard !readFailed, !recovering.contains(distinctId) else { return nil }
      guard let earliest = earliestInFlight(distinctId), earliest <= now else { return .at(now) }
      return .justBefore(earliest)
    }
  }

  /// Whether W has passed a deadline at `deadline`, so it may run now.
  func hasPassed(_ deadline: Date, distinctId: String, now: Date, readFailed: Bool) -> Bool {
    switch watermark(for: distinctId, now: now, readFailed: readFailed) {
    case nil: return false
    case .at(let time): return time >= deadline
    // An in-flight input at exactly D is in time, so it holds D.
    case .justBefore(let time): return time > deadline
    }
  }
}

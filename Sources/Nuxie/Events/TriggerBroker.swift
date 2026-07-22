import Foundation

public protocol TriggerBrokerProtocol: Actor {
  func register(eventId: String, handler: @escaping @Sendable (TriggerUpdate) -> Void) async
  func emit(eventId: String, update: TriggerUpdate) async
  func complete(eventId: String) async
  func reset() async
}

public actor TriggerBroker: TriggerBrokerProtocol {
  private var handlers: [String: @Sendable (TriggerUpdate) -> Void] = [:]

  public init() {}

  public func register(eventId: String, handler: @escaping @Sendable (TriggerUpdate) -> Void) async {
    handlers[eventId] = handler
  }

  public func emit(eventId: String, update: TriggerUpdate) async {
    guard let handler = handlers[eventId] else { return }
    await MainActor.run {
      handler(update)
    }
  }

  public func complete(eventId: String) async {
    handlers.removeValue(forKey: eventId)
  }

  public func reset() async {
    handlers.removeAll()
  }
}

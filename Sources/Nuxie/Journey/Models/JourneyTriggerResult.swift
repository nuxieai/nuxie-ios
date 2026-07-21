import Foundation

public enum JourneyTriggerResult: Sendable {
  case started(Journey)
  case suppressed(SuppressReason)
}

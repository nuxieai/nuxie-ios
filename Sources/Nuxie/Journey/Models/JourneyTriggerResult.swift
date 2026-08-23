import Foundation

enum JourneyTriggerResult: Sendable {
  case started(Journey)
  case suppressed(SuppressReason)
  case error(TriggerError)
}

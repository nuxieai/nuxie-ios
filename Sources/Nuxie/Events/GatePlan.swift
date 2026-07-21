import Foundation

public struct GatePlan: Codable, Sendable {
  public enum Decision: String, Codable, Sendable {
    case allow
    case deny
    case showFlow = "show_flow"
    case requireFeature = "require_feature"
  }

  public enum Policy: String, Codable, Sendable {
    case hard
    case soft
    case cacheOnly = "cache_only"
  }

  public let decision: Decision
  public let featureId: String?
  public let requiredBalance: Int?
  public let entityId: String?
  public let flowId: String?
  public let policy: Policy?
  public let timeoutMs: Int?
}

extension EventResponse {
  func gatePlan() -> GatePlan? {
    guard let payload = payload else { return nil }

    let raw: Any
    if let gate = payload["gate"]?.value {
      raw = gate
    } else {
      raw = payload.mapValues { $0.value }
    }

    guard JSONSerialization.isValidJSONObject(raw),
          let data = try? JSONSerialization.data(withJSONObject: raw, options: []) else {
      return nil
    }

    return try? JSONDecoder().decode(GatePlan.self, from: data)
  }
}

import Foundation

/// A type-erased Codable value for flexible JSON handling
public struct AnyCodable: Codable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let float = try? container.decode(Float.self) {
            self.value = float
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable value cannot be decoded"
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let float as Float:
            try container.encode(float)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "AnyCodable value cannot be encoded"
                )
            )
        }
    }
}

extension AnyCodable: Equatable {
    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case is (NSNull, NSNull):
            return true
        case let (lhs as Bool, rhs as Bool):
            return lhs == rhs
        case let (lhs as Int, rhs as Int):
            return lhs == rhs
        case let (lhs as Double, rhs as Double):
            return lhs == rhs
        case let (lhs as Float, rhs as Float):
            return lhs == rhs
        case let (lhs as String, rhs as String):
            return lhs == rhs
        case let (lhs as [Any], rhs as [Any]):
            return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy {
                AnyCodable($0.0) == AnyCodable($0.1)
            }
        case let (lhs as [String: Any], rhs as [String: Any]):
            return lhs.count == rhs.count && lhs.keys == rhs.keys &&
                lhs.allSatisfy { key, value in
                    guard let rhsValue = rhs[key] else { return false }
                    return AnyCodable(value) == AnyCodable(rhsValue)
                }
        default:
            return false
        }
    }
}

extension AnyCodable: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch value {
        case let bool as Bool:
            hasher.combine(bool)
        case let int as Int:
            hasher.combine(int)
        case let double as Double:
            hasher.combine(double)
        case let string as String:
            hasher.combine(string)
        default:
            hasher.combine(0)
        }
    }
}
// Values are set once at init and never mutated; consumers treat the wrapped
// value as immutable plist/JSON-like data.
extension AnyCodable: @unchecked Sendable {}


/// Immutable box that carries a write-once payload across isolation domains.
/// Loading `.value` from the Sendable box yields a fresh disconnected region,
/// letting the same snapshot be handed to multiple isolation domains.
// @unchecked Sendable: `value` is immutable and never mutated after init by
// convention (all payloads boxed here are write-once snapshots).
struct UncheckedSendable<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}


/// Lock-guarded late-bound reference used to break construction cycles in
/// composition roots. Set exactly once at the end of init; read afterwards.
// @unchecked Sendable: `value` is only accessed under `lock`.
final class LateBound<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value?

  func set(_ newValue: Value) {
    lock.withLock { value = newValue }
  }

  func get() -> Value {
    lock.withLock {
      guard let value else {
        preconditionFailure("LateBound value read before it was set")
      }
      return value
    }
  }
}

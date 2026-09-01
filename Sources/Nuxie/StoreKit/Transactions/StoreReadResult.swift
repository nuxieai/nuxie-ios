import Foundation

enum StoreReadResult<Value> {
    case absent
    case value(Value)
    case unreadable

    var readableValue: Value? {
        guard case .value(let value) = self else { return nil }
        return value
    }

    /// Absent is legitimate emptiness; unreadable is not. For call sites
    /// where an absent store and an empty store are equivalent.
    func valueTreatingAbsentAsEmpty(_ empty: @autoclosure () -> Value) -> Value? {
        switch self {
        case .absent: return empty()
        case .value(let value): return value
        case .unreadable: return nil
        }
    }

    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}

extension StoreReadResult: Sendable where Value: Sendable {}

/// Unreadable durable transaction evidence must surface as a retryable failure,
/// never as authoritative absence (internal review A12).
enum TransactionEvidenceError: Error, Equatable, Sendable {
    case unreadable
}

final class StoreReadFailureLogger {
    private let lock = NSLock()
    private var didLog = false

    func shouldLog() -> Bool {
        lock.withLock {
            guard !didLog else { return false }
            didLog = true
            return true
        }
    }
}

extension StoreReadFailureLogger: @unchecked Sendable {}

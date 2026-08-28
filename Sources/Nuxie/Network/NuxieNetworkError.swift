import Foundation

enum NuxieNetworkError: LocalizedError, Sendable {
    case invalidResponse
    case httpError(statusCode: Int, message: String, retryAfter: String? = nil)
    case decodingError(Error)
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response received"
        case .httpError(let statusCode, let message, _):
            return "HTTP \(statusCode): \(message)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .timeout:
            return "Request timeout"
        }
    }

    var httpStatusCode: Int? {
        guard case .httpError(let statusCode, _, _) = self else { return nil }
        return statusCode
    }

    var retryAfter: String? {
        guard case .httpError(_, _, let retryAfter) = self else { return nil }
        return retryAfter
    }
}

enum EventDeliveryDisposition {
    case retry(retryAfter: TimeInterval?)
    case split
    case unhealthyAuthentication
    case terminalPoison
}

extension EventDeliveryDisposition: Equatable {}

enum EventDeliveryPolicy {
    static func disposition(for error: Error) -> EventDeliveryDisposition {
        guard let networkError = error as? NuxieNetworkError,
              let statusCode = networkError.httpStatusCode else {
            return .retry(retryAfter: nil)
        }

        switch statusCode {
        case 400, 422:
            return .terminalPoison
        case 401, 403:
            return .unhealthyAuthentication
        case 408, 425, 429:
            return .retry(retryAfter: parseRetryAfter(networkError.retryAfter))
        case 413:
            return .split
        default:
            return .retry(retryAfter: nil)
        }
    }

    private static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }

        let formats = [
            "EEE',' dd MMM yyyy HH':'mm':'ss zzz",
            "EEEE',' dd-MMM-yy HH':'mm':'ss zzz",
            "EEE MMM d HH':'mm':'ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSinceNow)
            }
        }
        return nil
    }
}

import Foundation

/// Host-owned normalized hinge values. Enum order matches the shared env schema.
struct ExperienceFoldEnvironment: Equatable, Sendable {
    enum State: Int, Sendable {
        case unavailable, unknown, closed, partiallyOpen, fullyOpen

        var label: String {
            switch self {
            case .unavailable: return "unavailable"
            case .unknown: return "unknown"
            case .closed: return "closed"
            case .partiallyOpen: return "partially-open"
            case .fullyOpen: return "fully-open"
            }
        }
    }

    let available: Bool
    let state: State
    let openProgress: Float
    var foldProgress: Float { 1 - openProgress }

    static let unavailable = Self(angleRadians: nil, state: .unavailable)

    init(angleRadians: Double?, state: State) {
        self.state = state
        guard let angleRadians, angleRadians.isFinite,
              state == .closed || state == .partiallyOpen || state == .fullyOpen else {
            available = false
            openProgress = 1
            return
        }
        available = true
        switch state {
        case .closed: openProgress = 0
        case .fullyOpen: openProgress = 1
        default: openProgress = Float(min(1, max(0, angleRadians / .pi)))
        }
    }
}

struct ExperienceViewportEnvironment: Equatable, Sendable {
    let width: Float
    let height: Float

    init(width: Double, height: Double) {
        self.width = width.isFinite && width >= 0 && width <= Double(Float.greatestFiniteMagnitude) ? Float(width) : 0
        self.height = height.isFinite && height >= 0 && height <= Double(Float.greatestFiniteMagnitude) ? Float(height) : 0
    }
}

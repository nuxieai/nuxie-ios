import Foundation

/// Why a presentation could not finish, at the resolution the recovery surface
/// needs.
///
/// The shell deliberately says as little as it can defend. Blaming the user's
/// connection for a server fault, a signature problem, or a decode failure is
/// both wrong and unhelpful, so connectivity copy is reserved for the one case
/// the device actually reports as offline. Everything else stays neutral.
///
/// The split stops here because the recovery surface shows one line. A timeout
/// and a rejected signature read identically to someone waiting for a screen,
/// so giving them separate cases would be a distinction the product never
/// draws.
enum ExperienceShellRecoveryReason: Equatable, Sendable {
    /// The device reports it has no route to the network at all.
    case offline
    /// Everything else: timeouts, dropped connections, server responses,
    /// verification, decoding, and the presentation deadline passing with
    /// acquisition still in flight.
    case unavailable

    /// Classifies an acquisition failure.
    ///
    /// Only `URLError` codes that genuinely mean "this device has no network"
    /// map to `offline`. Transport failures that could equally be a server or
    /// route problem stay neutral rather than guessing.
    init(error: Error) {
        guard let urlError = error as? URLError else {
            self = .unavailable
            return
        }
        switch urlError.code {
        case .notConnectedToInternet,
             .dataNotAllowed,
             .internationalRoamingOff:
            self = .offline
        default:
            self = .unavailable
        }
    }
}

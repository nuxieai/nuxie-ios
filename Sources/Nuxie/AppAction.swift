import Foundation

/// A named action requested by an experience for the host app to perform.
public struct AppAction: Sendable, Equatable {
    /// The designer-authored action name.
    public let name: String
    /// The fully resolved action payload, when one was authored.
    public let payload: [String: NuxieActivityValue]?
    /// The experience and journey that requested the action.
    public let experience: ExperienceRef

    /// Creates a host-app action request.
    public init(
        name: String,
        payload: [String: NuxieActivityValue]?,
        experience: ExperienceRef
    ) {
        self.name = name
        self.payload = payload
        self.experience = experience
    }
}

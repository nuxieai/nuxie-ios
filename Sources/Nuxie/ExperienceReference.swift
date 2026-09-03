import Foundation

/// Stable identity for an experience participating in a Journey.
public struct ExperienceRef: Equatable, Sendable {
    public let experienceId: String
    public let experienceVersion: String?
    public let journeyId: String?

    public init(
        experienceId: String,
        experienceVersion: String?,
        journeyId: String?
    ) {
        self.experienceId = experienceId
        self.experienceVersion = experienceVersion
        self.journeyId = journeyId
    }
}

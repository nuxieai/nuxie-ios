import Foundation

/// SDK-authored execution context. The server corroborates this claim against
/// the owning Journey and pinned publication before granting direct credit.
struct JourneyEventOrigin: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case deviceAction = "device_action"
    }

    let journeyId: String
    let experienceId: String
    let versionId: String
    let legId: String
    let generation: Int
    let source: Source
    let stepId: String
    let occurrenceId: String
}

import Foundation

/// SDK-authored execution context. The server corroborates this claim against
/// the owning Journey and pinned publication before granting direct credit.
struct JourneyEventOrigin: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case deviceAction = "device_action"
        case screenControl = "screen_control"
    }

    let journeyId: String
    let experienceId: String
    let versionId: String
    let legId: String
    let generation: Int
    let source: Source
    let stepId: String?
    let screenId: String?
    let actionId: String?
    let invocationId: String?
    let occurrenceId: String

    init(journeyId: String, experienceId: String, versionId: String, legId: String,
         generation: Int, stepId: String, occurrenceId: String) {
        self.journeyId = journeyId
        self.experienceId = experienceId
        self.versionId = versionId
        self.legId = legId
        self.generation = generation
        self.source = .deviceAction
        self.stepId = stepId
        self.occurrenceId = occurrenceId
        self.screenId = nil
        self.actionId = nil
        self.invocationId = nil
    }

    init(journeyId: String, experienceId: String, versionId: String, legId: String,
         generation: Int, screenId: String, actionId: String, invocationId: String,
         occurrenceId: String) {
        self.journeyId = journeyId
        self.experienceId = experienceId
        self.versionId = versionId
        self.legId = legId
        self.generation = generation
        self.source = .screenControl
        self.stepId = nil
        self.occurrenceId = occurrenceId
        self.screenId = screenId
        self.actionId = actionId
        self.invocationId = invocationId
    }
}

import Foundation

/// Event names and property builders emitted by the on-device Journey
/// runtime. A device reports leg execution and presentation facts through the
/// ordinary event log; there is no claim, handoff, or checkpoint protocol.
final class JourneyEvents: Sendable {
    static let journeyStarted = "$journey_leg_started"
    static let journeyCompleted = "$journey_leg_completed"
    static let journeyMilestone = "$journey_milestone"

    static let experienceShown = "$experience_shown"
    static let experienceDismissed = "$experience_dismissed"
    static let experienceErrored = "$experience_errored"
    static let experienceArtifactLoadSucceeded = "$experience_artifact_load_succeeded"
    static let experienceArtifactLoadFailed = "$experience_artifact_load_failed"

    static let customerUpdated = "$customer_updated"
    static let appActionRequested = "$app_action_requested"
    static let experimentExposure = "$experiment_exposure"

    static func experienceArtifactLoadSucceededProperties(
        experienceId: String,
        experienceVersion: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String
    ) -> [String: Any] {
        experienceArtifactLoadBaseProperties(
            experienceId: experienceId,
            experienceVersion: experienceVersion,
            artifactBuildId: artifactBuildId,
            artifactSource: artifactSource,
            artifactContentHash: artifactContentHash
        )
    }

    static func experienceArtifactLoadFailedProperties(
        experienceId: String,
        experienceVersion: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String,
        errorMessage: String?
    ) -> [String: Any] {
        var properties = experienceArtifactLoadBaseProperties(
            experienceId: experienceId,
            experienceVersion: experienceVersion,
            artifactBuildId: artifactBuildId,
            artifactSource: artifactSource,
            artifactContentHash: artifactContentHash
        )
        if let errorMessage {
            properties["error_message"] = errorMessage
        }
        return properties
    }

    private static func experienceArtifactLoadBaseProperties(
        experienceId: String,
        experienceVersion: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String
    ) -> [String: Any] {
        [
            "experience_id": experienceId,
            "experience_version": experienceVersion,
            "artifact_build_id": artifactBuildId,
            "artifact_source": artifactSource,
            "artifact_content_hash": artifactContentHash,
        ]
    }
}

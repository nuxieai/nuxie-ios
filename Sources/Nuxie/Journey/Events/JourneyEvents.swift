import Foundation

/// Internal journey event tracking system
/// These events flow through the standard EventLog for observability
public class JourneyEvents {

    // MARK: - Event Names

    public static let journeyStarted = "$journey_started"
    public static let journeyPaused = "$journey_paused"
    public static let journeyResumed = "$journey_resumed"
    public static let journeyErrored = "$journey_errored"
    public static let journeyGoalHit = "$journey_goal_hit"
    public static let journeyGoalMet = "$journey_goal_met"
    public static let journeyExited = "$journey_exited"
    public static let journeyAction = "$journey_action"

    public static let flowShown = "$flow_shown"
    public static let flowDismissed = "$flow_dismissed"
    public static let flowPurchased = "$flow_purchased"
    public static let flowTimedOut = "$flow_timed_out"
    public static let flowErrored = "$flow_errored"
    public static let flowArtifactLoadSucceeded = "$flow_artifact_load_succeeded"
    public static let flowArtifactLoadFailed = "$flow_artifact_load_failed"

    public static let customerUpdated = "$customer_updated"
    public static let eventSent = "$event_sent"
    public static let delegateCalled = "$delegate_called"
    public static let experimentExposure = "$experiment_exposure"

    // MARK: - Properties Builders

    public static func journeyStartedProperties(
        journey: Journey,
        campaign: Campaign,
        triggerEvent: NuxieEvent? = nil,
        entryScreenId: String? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": campaign.id,
            "campaign_name": campaign.name,
            "flow_id": campaign.flowId as Any,
        ]

        if let entryScreenId {
            properties["entry_screen_id"] = entryScreenId
        }

        switch campaign.trigger {
        case .event(let config):
            properties["trigger_type"] = "event"
            properties["trigger_event_name"] = config.eventName
            if let triggerEvent {
                properties["trigger_event_properties"] = triggerEvent.properties
            }
        case .segment:
            properties["trigger_type"] = "segment"
            properties["trigger_segment"] = true
        }

        return properties
    }

    public static func journeyPausedProperties(
        journey: Journey,
        screenId: String?,
        resumeAt: Date?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }
        if let resumeAt {
            properties["resume_at"] = resumeAt.timeIntervalSince1970
        }

        return properties
    }

    public static func journeyResumedProperties(
        journey: Journey,
        screenId: String?,
        resumeReason: String
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "resume_reason": resumeReason
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }

        return properties
    }

    public static func journeyErroredProperties(
        journey: Journey,
        screenId: String?,
        errorMessage: String?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }

        if let errorMessage {
            properties["error_message"] = errorMessage
        }

        return properties
    }

    public static func journeyGoalHitProperties(
        journey: Journey,
        screenId: String?,
        goalId: String,
        goalLabel: String?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "goal_id": goalId
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }
        if let goalLabel, !goalLabel.isEmpty {
            properties["goal_label"] = goalLabel
        }

        return properties
    }

    public static func journeyExitedProperties(
        journey: Journey,
        reason: JourneyExitReason,
        screenId: String?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "exit_reason": reason.rawValue
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }

        return properties
    }

    public static func journeyActionProperties(
        journey: Journey,
        screenId: String?,
        handlerId: String?,
        actionType: String,
        error: String?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "action_type": actionType
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }
        if let handlerId {
            properties["handler_id"] = handlerId
        }
        if let error {
            properties["error_message"] = error
        }

        return properties
    }

    public static func journeyGoalHitProperties(
        journey: Journey,
        screenId: String?,
        handlerId: String?,
        goalId: String,
        goalLabel: String?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "goal_id": goalId,
        ]

        if let screenId {
            properties["screen_id"] = screenId
        }
        if let handlerId {
            properties["handler_id"] = handlerId
        }
        if let goalLabel, !goalLabel.isEmpty {
            properties["goal_label"] = goalLabel
        }

        return properties
    }

    public static func flowShownProperties(flowId: String, journey: Journey) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
    }

    public static func flowDismissedProperties(flowId: String, journey: Journey) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
    }

    public static func flowPurchasedProperties(flowId: String, journey: Journey, productId: String?) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
        if let productId {
            properties["product_id"] = productId
        }
        return properties
    }

    public static func flowTimedOutProperties(flowId: String, journey: Journey) -> [String: Any] {
        return [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
    }

    public static func flowErroredProperties(flowId: String, journey: Journey, errorMessage: String?) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId
        ]
        if let errorMessage {
            properties["error_message"] = errorMessage
        }
        return properties
    }

    public static func flowArtifactLoadSucceededProperties(
        flowId: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String
    ) -> [String: Any] {
        return flowArtifactLoadBaseProperties(
            flowId: flowId,
            artifactBuildId: artifactBuildId,
            artifactSource: artifactSource,
            artifactContentHash: artifactContentHash
        )
    }

    public static func flowArtifactLoadFailedProperties(
        flowId: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String,
        errorMessage: String?
    ) -> [String: Any] {
        var properties = flowArtifactLoadBaseProperties(
            flowId: flowId,
            artifactBuildId: artifactBuildId,
            artifactSource: artifactSource,
            artifactContentHash: artifactContentHash
        )
        if let errorMessage {
            properties["error_message"] = errorMessage
        }
        return properties
    }

    private static func flowArtifactLoadBaseProperties(
        flowId: String,
        artifactBuildId: String,
        artifactSource: String,
        artifactContentHash: String
    ) -> [String: Any] {
        return [
            "flow_id": flowId,
            "artifact_build_id": artifactBuildId,
            "artifact_source": artifactSource,
            "artifact_content_hash": artifactContentHash,
        ]
    }

    public static func customerUpdatedProperties(
        journey: Journey,
        screenId: String?,
        attributesUpdated: [String]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "attributes_updated": attributesUpdated
        ]
        if let screenId {
            properties["screen_id"] = screenId
        }
        return properties
    }

    public static func eventSentProperties(
        journey: Journey,
        screenId: String?,
        eventName: String,
        eventProperties: [String: Any]
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "event_name": eventName,
            "event_properties": eventProperties
        ]
        if let screenId {
            properties["screen_id"] = screenId
        }
        return properties
    }

    public static func delegateCalledProperties(
        journey: Journey,
        screenId: String?,
        message: String,
        payload: Any?
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "message": message
        ]
        if let screenId {
            properties["screen_id"] = screenId
        }
        if let payload {
            properties["payload"] = payload
        }
        return properties
    }

    public static func experimentExposureProperties(
        journey: Journey,
        experimentKey: String,
        variantKey: String,
        flowId: String?,
        isHoldout: Bool,
        assignmentSource: String? = nil
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "journey_id": journey.id,
            "campaign_id": journey.campaignId,
            "flow_id": flowId as Any,
            "experiment_key": experimentKey,
            "variant_key": variantKey,
            "is_holdout": isHoldout
        ]
        if let assignmentSource {
            properties["assignment_source"] = assignmentSource
        }
        return properties
    }
}

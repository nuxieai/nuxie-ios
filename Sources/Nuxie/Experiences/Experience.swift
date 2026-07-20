import Foundation

/// An **Experience** is the server-configured unit the SDK runs: the
/// **screens** (riv bundle wire model) plus the **journey definition**
/// (trigger, handlers/actions, goals, reentry). A **Journey** is a runtime
/// run of an experience for a user.
///
/// This is the composed model the Experience terminology migration
/// (cleanup plan Phase 3) introduces. The wire adapter below is the ONLY
/// place the legacy `campaigns[]` + `flows[]` split (joined by flowId) is
/// visible; when the backend ships an experience-shaped /profile response,
/// only the adapter changes. Internal types (Campaign, RemoteFlow) keep
/// their names until the Phase 10 mechanical rename.
public struct Experience {
    /// Stable experience id (today: the campaign id).
    public let id: String
    public let name: String
    /// Journey definition: trigger, reentry policy, goal/exit config.
    public let journey: Campaign
    /// Screens bundle (riv artifact wire model). Nil when the profile
    /// response did not include the referenced flow (e.g. build pending).
    public let screens: RemoteFlow?

    public init(journey: Campaign, screens: RemoteFlow?) {
        self.id = journey.id
        self.name = journey.name
        self.journey = journey
        self.screens = screens
    }
}

// MARK: - Wire-compat adapter

extension ProfileResponse {
    /// Compose the legacy `campaigns[]` + `flows[]` wire shape into
    /// `[Experience]`. This join exists in exactly one place — here.
    public var experiences: [Experience] {
        let flowsById = Dictionary(uniqueKeysWithValues: flows.map { ($0.id, $0) })
        return campaigns.map { campaign in
            Experience(journey: campaign, screens: flowsById[campaign.flowId])
        }
    }
}

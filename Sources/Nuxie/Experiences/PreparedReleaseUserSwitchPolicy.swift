import Foundation

/// The user a committed profile's prepared releases belong to.
struct PreparedReleaseOwner: Equatable, Sendable {
    let distinctId: String
    /// The anonymous id an identified user signed in from. Nil for an
    /// anonymous user, or when the sign-in origin is unknown.
    let signedInFromAnonymousId: String?

    init(distinctId: String, signedInFromAnonymousId: String? = nil) {
        self.distinctId = distinctId
        self.signedInFromAnonymousId = signedInFromAnonymousId
    }

    /// The owner for one identity snapshot. An identified user keeps the
    /// device's anonymous id until reset, so that id is where they signed in.
    init(identity: IdentitySnapshot) {
        self.init(
            distinctId: identity.distinctId,
            signedInFromAnonymousId: identity.isIdentified ? identity.anonymousId : nil
        )
    }
}

/// Which user changes throw away every prepared Experience release.
///
/// Decision 16 (Levi, 2026-09-30): a first sign-in, where an anonymous user
/// identifies, keeps everything prepared. Prepared releases are discarded on
/// reset (log out) and when one identified user switches to another. Either
/// way, the arriving user's profile commit still drops whatever is no longer
/// armed for them.
///
/// A sign-in reaches the prepared-release store in either order, so two
/// places ask this policy: the queued user transition
/// (`discardsPreparedReleases(on:)`), and the arriving user's profile commit
/// when it lands first (`keepsPreparedReleases(ownedBy:for:)`). Set
/// `firstSignInSwitchesUsers` to true to discard on every identify instead.
enum PreparedReleaseUserSwitchPolicy {
    static let firstSignInSwitchesUsers = false

    /// Whether a queued user transition discards the departing user's
    /// prepared releases. When it does not, it hands them to the arriving
    /// user.
    static func discardsPreparedReleases(
        on transition: UserTransitionCoordinator.Transition
    ) -> Bool {
        let isFirstSignIn = transition.kind == .identify && transition.migrateEvents
        return !isFirstSignIn || firstSignInSwitchesUsers
    }

    /// Whether a profile commit for a different user keeps the releases
    /// prepared for `currentOwnerDistinctId`. Only a first sign-in does: the
    /// arriving user signed in from that anonymous owner.
    static func keepsPreparedReleases(
        ownedBy currentOwnerDistinctId: String,
        for arriving: PreparedReleaseOwner
    ) -> Bool {
        !firstSignInSwitchesUsers
            && arriving.signedInFromAnonymousId == currentOwnerDistinctId
    }
}

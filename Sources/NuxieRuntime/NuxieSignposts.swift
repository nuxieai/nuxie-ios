import os

/// Launch and first-frame intervals for Instruments' os_signpost track
/// (subsystem `ai.nuxie.sdk`, category `Launch`).
///
/// Only coarse, once-per-launch or once-per-show work is signposted, so the
/// intervals are cheap enough to leave on. Both SDK modules share this one
/// signposter so a trace shows profile, release, runtime, and presentation
/// intervals on one timeline.
package enum NuxieSignposts {
    package static let signposter = OSSignposter(
        subsystem: "ai.nuxie.sdk",
        category: "Launch"
    )
}

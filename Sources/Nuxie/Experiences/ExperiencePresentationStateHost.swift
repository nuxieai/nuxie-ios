import Foundation

#if canImport(UIKit)
import UIKit

/// On-device review host for the native presentation shell.
///
/// Presentation polish (loading treatment, recovery affordances, floating
/// controls, and the geometry of each supported mode) is only reviewable while
/// a presentation is actually on screen, and the interesting states are the
/// slow and failing ones that a healthy cache never produces. This host runs
/// the ordinary authenticate -> admit -> acquire -> present path against a
/// signed fixture and varies only the *acquisition condition*, so a reviewer
/// sees the real shell rather than a mock of it.
///
/// It deliberately does not fabricate UI states. `slow` and `failure` delay or
/// fail artifact acquisition exactly where a constrained or offline device
/// would, and the shell reacts through its normal code path.
@_spi(Testing) public enum ExperiencePresentationStateHost {
    /// The acquisition condition a scenario runs under.
    public enum Condition: String, Sendable, CaseIterable {
        /// Artifact acquisition completes as fast as the fixture allows.
        case normal
        /// Acquisition stalls long enough to pass the recovery-affordance
        /// delay, which is what a constrained network looks like.
        case slow
        /// Acquisition fails the way an offline device fails.
        case failure
        /// Acquisition is already complete before presentation, which is the
        /// memory-warm path that must not show loading treatment at all.
        case warm
    }

    public struct Scenario: Sendable {
        public let fixtureBaseURL: URL
        public let cacheRootURL: URL
        public let condition: Condition

        public init(fixtureBaseURL: URL, cacheRootURL: URL, condition: Condition) {
            self.fixtureBaseURL = fixtureBaseURL
            self.cacheRootURL = cacheRootURL
            self.condition = condition
        }
    }

    /// A live presentation.
    ///
    /// Dismissal is explicit: releasing this handle does **not** tear the
    /// presentation down, because deinit cannot safely drive the MainActor
    /// shutdown this needs (`isolated deinit` is banned in this SDK, see
    /// UNIV-1397). Either call `dismiss()`, or let the shell's own close
    /// affordance run, which dismisses the controller and shuts its runtime
    /// down before invoking `onClose`.
    @MainActor
    public final class Presentation {
        private let configurator = ExperienceShellPresentationConfigurator()
        private let controller: ExperienceViewController
        private weak var presenter: UIViewController?

        init(controller: ExperienceViewController, presenter: UIViewController) {
            self.controller = controller
            self.presenter = presenter
        }

        func present(shell: ExperienceShellContract?) async {
            guard let presenter else { return }
            configurator.configure(controller, shell: shell)
            await withCheckedContinuation { continuation in
                presenter.present(controller, animated: true) {
                    continuation.resume()
                }
            }
            controller.markPresentationShellPresented(traceToken: nil)
        }

        public func dismiss() async {
            await controller.shutdownRuntime()
            guard let presenter, presenter.presentedViewController === controller else {
                return
            }
            await withCheckedContinuation { continuation in
                presenter.dismiss(animated: true) { continuation.resume() }
            }
        }
    }

    /// How long `slow` stalls acquisition. Comfortably past the controller's
    /// 5 s recovery-affordance delay so the sustained-loading and recovery
    /// states are both observable in one run.
    static let slowAcquisitionDelay: TimeInterval = 30

    /// Authenticates the fixture, resolves its first screen, and presents it
    /// from `presenter` under `condition`.
    @MainActor
    public static func present(
        _ scenario: Scenario,
        from presenter: UIViewController,
        onClose: (@MainActor () -> Void)? = nil
    ) async throws -> Presentation {
        let host = try ExperienceReleaseFixtureHost.makePresentationInputs(
            fixtureBaseURL: scenario.fixtureBaseURL,
            cacheRootURL: scenario.cacheRootURL
        )
        let definition = try await host.authenticate()
        let screenID = try await host.resolveInitialScreenID(definition: definition)

        // `warm` acquires before the shell is ever presented, which is what a
        // memory-warm presentation genuinely looks like to the controller.
        let warmArtifact: AcquiredExperienceArtifact?
        switch scenario.condition {
        case .warm:
            warmArtifact = try await host.acquire(
                definition: definition,
                initialScreenID: screenID
            )
        case .normal, .slow, .failure:
            warmArtifact = nil
        }

        let condition = scenario.condition
        let controller = host.makeViewController(
            definition: definition,
            artifactLoader: { _, _, requestedScreenID in
                switch condition {
                case .warm:
                    guard let warmArtifact else {
                        throw ExperiencePresentationStateHostError.acquisitionUnavailable
                    }
                    return warmArtifact
                case .normal:
                    return try await host.acquire(
                        definition: definition,
                        initialScreenID: requestedScreenID ?? screenID
                    )
                case .slow:
                    try await Task.sleep(
                        nanoseconds: UInt64(slowAcquisitionDelay * 1_000_000_000)
                    )
                    return try await host.acquire(
                        definition: definition,
                        initialScreenID: requestedScreenID ?? screenID
                    )
                case .failure:
                    // The same error an offline device raises, so the review
                    // sees the copy a real offline failure produces rather
                    // than the neutral fallback for an unrecognized error.
                    throw URLError(.notConnectedToInternet)
                }
            }
        )
        // The shell's own close only prepares the active screen and keeps the
        // controller alive briefly afterwards. Shutting the runtime down before
        // handing control back stops a finishing scenario's acquisition from
        // overlapping the next one.
        controller.onClose = { [weak controller] _ in
            Task { @MainActor in
                await controller?.shutdownRuntime()
                onClose?()
            }
        }

        let shell = controller.experience.shellContract(screenId: screenID)
        controller.configurePresentationShell(
            shell,
            suppressLoadingTreatment: scenario.condition == .warm
        )
        await controller.prepareForPresentation(
            traceToken: nil,
            initialScreenID: screenID
        )

        let presentation = Presentation(controller: controller, presenter: presenter)
        await presentation.present(shell: shell)
        return presentation
    }
}

@_spi(Testing) public enum ExperiencePresentationStateHostError: LocalizedError {
    case acquisitionUnavailable

    public var errorDescription: String? {
        switch self {
        case .acquisitionUnavailable:
            "The prepared experience artifact was unavailable."
        }
    }
}
#endif

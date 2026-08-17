import XCTest
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

#if canImport(UIKit)
import UIKit

/// Covers the shell chrome contract: chrome legibility is derived from the
/// authored background rather than the forced interface style, a presentation
/// is never a trap while acquisition runs, and the requested presentation mode
/// is never silently substituted.
final class ExperienceShellPresentationChromeTests: XCTestCase {
    // MARK: - Palette

    func testPaletteReadsLightContentFromADarkAuthoredBackground() {
        let palette = ExperienceShellPalette(
            backgroundCandidates: [UIColor(nuxieRGBAHex: "#0B1220FF")]
        )
        XCTAssertTrue(palette.prefersLightContent)
    }

    func testPaletteReadsDarkContentFromALightAuthoredBackground() {
        let palette = ExperienceShellPalette(
            backgroundCandidates: [UIColor(nuxieRGBAHex: "#F7F5F2FF")]
        )
        XCTAssertFalse(palette.prefersLightContent)
    }

    func testPaletteSkipsTransparentCandidatesAndUsesTheFirstOpaqueOne() {
        let palette = ExperienceShellPalette(
            backgroundCandidates: [
                UIColor(nuxieRGBAHex: "#00000000"),
                UIColor(nuxieRGBAHex: "#FFFFFFFF"),
            ]
        )
        XCTAssertFalse(palette.prefersLightContent)
    }

    func testPaletteFallsBackToLightContentWhenNoBackgroundIsOpaque() {
        let palette = ExperienceShellPalette(
            backgroundCandidates: [UIColor(nuxieRGBAHex: "#FFFFFF00"), nil]
        )
        XCTAssertTrue(palette.prefersLightContent)
    }

    /// Contrast is not linear in luminance, so splitting it at the midpoint
    /// picks light content across a wide band of ordinary mid-tone colors
    /// where dark content is dramatically more readable.
    func testPaletteChoosesTheHigherContrastPolarityOnMidTones() {
        for hex in ["#AAAAAAFF", "#999999FF", "#808080FF", "#B0B0B0FF"] {
            let background = UIColor(nuxieRGBAHex: hex)!
            let palette = ExperienceShellPalette(backgroundCandidates: [background])
            XCTAssertFalse(
                palette.prefersLightContent,
                "\(hex) reads better with dark content "
                    + "(white \(background.nuxieContrastWithWhite), "
                    + "black \(background.nuxieContrastWithBlack))"
            )
        }
    }

    /// Whatever the background, the chosen polarity is never the worse of the
    /// two options.
    func testPaletteNeverPicksTheLowerContrastPolarity() {
        for hex in [
            "#000000FF", "#0B1220FF", "#123326FF", "#7A6E8CFF",
            "#808080FF", "#AAAAAAFF", "#F7F5F2FF", "#FFFFFFFF",
        ] {
            let background = UIColor(nuxieRGBAHex: hex)!
            let palette = ExperienceShellPalette(backgroundCandidates: [background])
            let chosen = palette.prefersLightContent
                ? background.nuxieContrastWithWhite
                : background.nuxieContrastWithBlack
            let rejected = palette.prefersLightContent
                ? background.nuxieContrastWithBlack
                : background.nuxieContrastWithWhite
            XCTAssertGreaterThanOrEqual(chosen, rejected, "\(hex) picked the worse polarity")
        }
    }

    /// The regression this palette exists for: chrome used to resolve `.label`
    /// against the forced color-scheme mode, so a light-mode label landed
    /// near-black on a near-black authored background.
    @MainActor
    func testRecoveryChromeStaysLegibleOnADarkAuthoredBackgroundInLightMode() {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-dark-shell-legibility"
        )
        controller.colorSchemeMode = .light
        controller.configurePresentationShell(
            Self.shell(background: "#0B1220FF")
        )
        _ = controller.view

        XCTAssertTrue(controller.shellPalette.prefersLightContent)
        let backgroundLuminance = try? XCTUnwrap(
            controller.errorView.backgroundColor
        ).nuxieRelativeLuminance
        let titleLuminance = controller.shellPalette.primary.nuxieRelativeLuminance
        XCTAssertGreaterThan(
            titleLuminance,
            (backgroundLuminance ?? 0) + 0.3,
            "Recovery chrome must contrast with the authored background"
        )
    }

    @MainActor
    func testRecoveryChromeFlipsToDarkContentOnALightAuthoredBackground() {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-light-shell-legibility"
        )
        controller.configurePresentationShell(
            Self.shell(background: "#F7F5F2FF")
        )
        _ = controller.view

        XCTAssertFalse(controller.shellPalette.prefersLightContent)
        XCTAssertLessThan(
            controller.shellPalette.primary.nuxieRelativeLuminance,
            0.2
        )
    }

    // MARK: - Floating close control

    /// While the authored loading treatment is running, the surface stays as
    /// calm as the descriptor authored it: no SDK chrome on top of it.
    @MainActor
    func testLoadingShowsNoCloseChromeOverTheAuthoredTreatment() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-no-chrome-while-loading",
            recoveryAffordanceDelay: 5
        )
        controller.configurePresentationShell(Self.shell())
        _ = controller.view

        controller.markPresentationShellPresented(traceToken: nil)
        XCTAssertFalse(controller.loadingView.isHidden)
        XCTAssertTrue(controller.loadingShimmerView.isAnimating)
        XCTAssertEqual(controller.shellCloseControl?.isHidden, true)
        await controller.shutdownRuntime()
    }

    @MainActor
    func testCloseAppearsWithTheRecoverySurface() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-close-with-recovery",
            recoveryAffordanceDelay: 0.02
        )
        controller.configurePresentationShell(Self.shell())
        _ = controller.view
        controller.markPresentationShellPresented(traceToken: nil)
        XCTAssertEqual(controller.shellCloseControl?.isHidden, true)

        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertFalse(controller.errorView.isHidden)
        XCTAssertEqual(controller.shellCloseControl?.isHidden, false)
        await controller.shutdownRuntime()
    }

    /// A non-dismissible sheet offers no interactive dismissal, so the floating
    /// close on the recovery surface is the only way out.
    @MainActor
    func testNonDismissibleSheetStillOffersAWayOutOfRecovery() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-non-dismissible-escape",
            recoveryAffordanceDelay: 0.02
        )
        controller.configurePresentationShell(
            ExperienceShellContract(
                presentation: .init(
                    style: .sheet,
                    orientation: .portrait,
                    backgroundColor: "#123326FF",
                    sheet: .init(detent: .large, dismissible: false),
                    drawer: nil
                ),
                screen: .init(width: 390, height: 844)
            )
        )
        _ = controller.view
        controller.markPresentationShellPresented(traceToken: nil)
        try? await Task.sleep(nanoseconds: 60_000_000)

        var closeReasons: [CloseReason] = []
        controller.onClose = { closeReasons.append($0) }
        let closeControl = try? XCTUnwrap(controller.shellCloseControl)
        XCTAssertEqual(closeControl?.isHidden, false)
        closeControl?.sendActions(for: .touchUpInside)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(closeReasons, [.userDismissed])
        await controller.shutdownRuntime()
    }

    /// Retrying returns to the authored loading treatment, so the chrome that
    /// only belongs to recovery goes away with it.
    @MainActor
    func testRetryHidesTheCloseUntilRecoveryReturns() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-retry-hides-chrome",
            recoveryAffordanceDelay: 0.02
        )
        controller.configurePresentationShell(Self.shell())
        _ = controller.view
        controller.markPresentationShellPresented(traceToken: nil)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(controller.shellCloseControl?.isHidden, false)

        controller.retryFromErrorView()
        XCTAssertEqual(controller.shellCloseControl?.isHidden, true)
        await controller.shutdownRuntime()
    }

    /// A memory-warm presentation reveals immediately, so shell chrome must
    /// never flash over it.
    @MainActor
    func testWarmPresentationDoesNotShowShellChrome() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-warm-no-chrome",
            recoveryAffordanceDelay: 0.02
        )
        controller.configurePresentationShell(
            Self.shell(),
            suppressLoadingTreatment: true
        )
        _ = controller.view
        controller.markPresentationShellPresented(traceToken: nil)

        XCTAssertEqual(controller.shellCloseControl?.isHidden, true)
        XCTAssertTrue(controller.loadingView.isHidden)
        await controller.shutdownRuntime()
    }

    /// A late reveal clears every shell surface, including the recovery
    /// chrome, so authored content is never framed by SDK controls.
    @MainActor
    func testRevealHidesTheRecoveryChrome() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-reveal-hides-chrome",
            recoveryAffordanceDelay: 0.02
        )
        controller.configurePresentationShell(Self.shell())
        _ = controller.view
        controller.markPresentationShellPresented(traceToken: nil)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(controller.shellCloseControl?.isHidden, false)

        controller.platformRevealPresentationContent()
        // Still on screen while the shell fades: hiding it up front would snap
        // it away while the recovery surface animates out.
        XCTAssertEqual(controller.shellCloseControl?.isHidden, false)
        try? await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertEqual(controller.shellCloseControl?.isHidden, true)
        XCTAssertTrue(controller.errorView.isHidden)
        await controller.shutdownRuntime()
    }

    /// The close is a sibling of the recovery surface, so hiding `errorView`
    /// for a new presentation does not take it along. A controller dismissed
    /// while recovery was visible must not carry a live close over the next
    /// presentation's shimmer.
    @MainActor
    func testReusedControllerDoesNotCarryRecoveryChromeIntoTheNextPresentation() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-chrome-reset",
            recoveryAffordanceDelay: 0.02
        )
        controller.configurePresentationShell(Self.shell())
        _ = controller.view
        controller.markPresentationShellPresented(traceToken: nil)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(controller.shellCloseControl?.isHidden, false)

        // A new presentation of the same cached controller.
        controller.beginPresentationScope(traceToken: nil)

        XCTAssertEqual(
            controller.shellCloseControl?.isHidden,
            true,
            "stale close carried into the next presentation"
        )
        XCTAssertEqual(controller.shellCloseControl?.alpha, 1)
        await controller.shutdownRuntime()
    }

    // MARK: - Loading treatment

    /// Loading is not authorable: any signed presentation shimmers, and the
    /// embedded-host indicator must not also run, or the surface shows the same
    /// thing twice.
    @MainActor
    func testEverySignedPresentationShimmersOverItsBackground() {
        for presentation in [
            ExperienceBehaviorPresentation.fullScreenDefault,
            .init(
                style: .sheet,
                orientation: .portrait,
                backgroundColor: "#1E2A5AFF",
                sheet: .init(detent: .medium, dismissible: true),
                drawer: nil
            ),
            .init(
                style: .drawer,
                orientation: .portrait,
                backgroundColor: "#241528FF",
                sheet: nil,
                drawer: .init(
                    edge: .trailing,
                    extentRatio: 0.8,
                    cornerRadius: 0,
                    dismissible: true
                )
            ),
        ] {
            let controller = MockExperienceViewController(
                mockExperienceVersionId: "version-\(presentation.style.rawValue)-shimmers"
            )
            controller.configurePresentationShell(
                ExperienceShellContract(
                    presentation: presentation,
                    screen: .init(width: 390, height: 844)
                )
            )
            _ = controller.view

            XCTAssertFalse(controller.loadingShimmerView.isHidden)
            XCTAssertTrue(controller.loadingShimmerView.isAnimating)
            XCTAssertFalse(controller.activityIndicator.isAnimating)
            XCTAssertTrue(controller.activityIndicator.isHidden)
        }
    }

    /// Reduce Motion keeps the authored background flat instead of swapping in
    /// a different affordance. "Flat" means no gradient stops at all, not a
    /// band parked against an edge.
    @MainActor
    func testReduceMotionLeavesTheSurfaceFlat() {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-shimmer-reduce-motion"
        )
        _ = controller.view
        controller.loadingShimmerView.configure(
            backgroundColor: UIColor(nuxieRGBAHex: "#0B1220FF")!,
            palette: ExperienceShellPalette(prefersLightContent: true),
            reduceMotion: true
        )

        XCTAssertFalse(controller.loadingShimmerView.isHidden)
        XCTAssertFalse(controller.loadingShimmerView.isAnimating)
        XCTAssertTrue(
            controller.loadingShimmerView.gradientStopColors.isEmpty,
            "A stopped shimmer must not leave a visible band"
        )
    }

    /// The gradient layer is squared around the surface's center so its unit
    /// coordinate space is isotropic. On a non-square layer the effect angle
    /// would be skewed by the aspect ratio, and every presentation mode would
    /// show a different sweep.
    @MainActor
    func testGradientLayerIsSquaredAroundTheSurfaceForAnyAspect() {
        // Standalone, so no constraint from the shell overrides the frames
        // this test is exercising.
        let shimmer = ExperienceShellShimmerView(frame: .zero)

        for size in [
            CGSize(width: 390, height: 844),
            CGSize(width: 844, height: 390),
            CGSize(width: 400, height: 400),
        ] {
            shimmer.frame = CGRect(origin: .zero, size: size)
            shimmer.layoutIfNeeded()

            let frame = shimmer.gradientLayerFrame
            let side = max(size.width, size.height)
            XCTAssertEqual(frame.width, side, accuracy: 0.5)
            XCTAssertEqual(frame.height, side, accuracy: 0.5)
            XCTAssertEqual(frame.midX, size.width / 2, accuracy: 0.5)
            XCTAssertEqual(frame.midY, size.height / 2, accuracy: 0.5)
        }
    }

    /// Stops ramp smoothly rather than in three linear steps, which is what
    /// removes the visible edges where the band meets the background. The ramp
    /// is in alpha: the band overlays the authored ground rather than
    /// restating it, so a translucent background is not painted twice.
    @MainActor
    func testSweepStopsRampSmoothlyAsATransparentOverlay() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-shimmer-stops"
        )
        window.rootViewController = controller
        window.isHidden = false
        controller.configurePresentationShell(Self.shell())
        controller.view.layoutIfNeeded()

        let stops = controller.loadingShimmerView.gradientStopColors
        XCTAssertGreaterThan(stops.count, 10, "a three-stop ramp bands visibly")

        let alphas = stops.map { UIColor(cgColor: $0).nuxieAlpha }
        // Transparent at both ends, most opaque in the middle.
        XCTAssertEqual(alphas.first!, 0, accuracy: 0.001)
        XCTAssertEqual(alphas.last!, 0, accuracy: 0.001)
        let peak = alphas.firstIndex(of: alphas.max()!)!
        XCTAssertGreaterThan(peak, 0)
        XCTAssertLessThan(peak, alphas.count - 1)
        XCTAssertGreaterThan(alphas.max()!, 0, "the band never becomes visible")

        // No single step jumps a large fraction of the total ramp.
        let range = alphas.max()! - alphas.min()!
        for (lhs, rhs) in zip(alphas, alphas.dropFirst()) {
            XCTAssertLessThan(abs(rhs - lhs), range * 0.25)
        }
    }

    /// The authored ground is opaque by contract, so every shell surface
    /// carries it unchanged and nothing stacks alpha.
    @MainActor
    func testAuthoredGroundIsCarriedUnchangedByEverySurface() {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-single-ground"
        )
        controller.configurePresentationShell(Self.shell(background: "#102030FF"))
        _ = controller.view

        let expected = UIColor(nuxieRGBAHex: "#102030FF")!
        for surface in [
            controller.view.backgroundColor,
            controller.loadingView.backgroundColor,
            controller.errorView.backgroundColor,
        ] {
            XCTAssertTrue(surface?.isEqual(expected) == true)
        }
    }

    /// Core Animation drops animations when the app backgrounds. Without
    /// restoration a presentation that is still acquiring returns to a dead
    /// surface.
    @MainActor
    func testSweepIsRestoredAfterItsAnimationIsDropped() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-shimmer-restore"
        )
        window.rootViewController = controller
        window.isHidden = false
        controller.configurePresentationShell(Self.shell())
        controller.view.layoutIfNeeded()

        let shimmer = controller.loadingShimmerView!
        XCTAssertTrue(shimmer.hasAttachedSweep)

        shimmer.simulateSystemDroppingAnimations()
        XCTAssertFalse(shimmer.hasAttachedSweep)

        NotificationCenter.default.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        XCTAssertTrue(shimmer.hasAttachedSweep)
        XCTAssertTrue(shimmer.isAnimating)
    }

    /// Travel is derived from the surface's own geometry, so a rotation or
    /// detent change has to re-derive the sweep. What must not happen is the
    /// sweep being dropped and left off.
    @MainActor
    func testRelayoutKeepsTheSweepRunningForTheNewGeometry() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-shimmer-relayout"
        )
        window.rootViewController = controller
        window.isHidden = false
        controller.configurePresentationShell(Self.shell())
        controller.view.layoutIfNeeded()

        let shimmer = controller.loadingShimmerView!
        XCTAssertTrue(shimmer.hasAttachedSweep)

        controller.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        controller.view.layoutIfNeeded()

        XCTAssertTrue(shimmer.hasAttachedSweep, "relayout dropped the sweep")
        XCTAssertTrue(shimmer.isAnimating)
        // The square stays centered on the new bounds rather than keeping the
        // old portrait placement.
        XCTAssertEqual(
            shimmer.gradientLayerFrame.midX,
            shimmer.bounds.midX,
            accuracy: 0.5
        )
        XCTAssertEqual(
            shimmer.gradientLayerFrame.midY,
            shimmer.bounds.midY,
            accuracy: 0.5
        )
    }

    /// `preferredFontDescriptor(withTextStyle:)` is already scaled for the
    /// current category, so feeding it to `UIFontMetrics` scales twice and
    /// overflows the surface at accessibility sizes.
    @MainActor
    func testRecoveryTypographyScalesOnceWithDynamicType() {
        for category in [
            UIContentSizeCategory.large,
            .extraExtraExtraLarge,
            .accessibilityExtraExtraExtraLarge,
        ] {
            let traits = UITraitCollection(preferredContentSizeCategory: category)
            for style in [UIFont.TextStyle.title1, .title3] {
                let expected = UIFont.preferredFont(
                    forTextStyle: style,
                    compatibleWith: traits
                ).pointSize
                let actual = ExperienceShellRecoveryView.scaledFont(
                    style,
                    weight: .bold,
                    compatibleWith: traits
                ).pointSize
                // A tolerance, not equality: UIFontMetrics scales the base
                // linearly where the system applies its own curve, so a few
                // points of drift is expected. Double-scaling is not subtle -
                // it put .title3 at ~143pt against an expected 55pt.
                XCTAssertEqual(
                    actual,
                    expected,
                    accuracy: expected * 0.1,
                    "\(style) at \(category.rawValue) scaled to \(actual), expected ~\(expected)"
                )
            }
        }
    }

    /// The action's fixed height clipped its label at accessibility text
    /// sizes, because the effect view clips to bounds.
    @MainActor
    func testRecoveryActionGrowsForAccessibilityTextSizes() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let recoveryView = ExperienceShellRecoveryView(onRetry: {})
        window.addSubview(recoveryView)
        recoveryView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recoveryView.topAnchor.constraint(equalTo: window.topAnchor),
            recoveryView.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            recoveryView.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            recoveryView.bottomAnchor.constraint(equalTo: window.bottomAnchor),
        ])
        window.layoutIfNeeded()

        let action = recoveryView.primaryActionButton
        XCTAssertGreaterThanOrEqual(action.frame.height, ExperienceGlassButton.minimumHeight)
        // The label has to fit inside the control that clips it.
        let label = action.titleLabelForTesting
        XCTAssertGreaterThanOrEqual(
            action.frame.height,
            label.intrinsicContentSize.height,
            "label taller than the control that clips it"
        )
    }

    /// The contract accepts any extent above zero. A drawer narrower than the
    /// chrome would demand a negative content width and clip the close, and a
    /// non-dismissible one whose acquisition failed would trap the user.
    @MainActor
    func testNarrowSurfacesKeepRecoveryControlsUsable() {
        for width in [390.0, 200.0, 120.0, 40.0] as [CGFloat] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 600))
            let recoveryView = ExperienceShellRecoveryView(onRetry: {})
            window.addSubview(recoveryView)
            recoveryView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                recoveryView.topAnchor.constraint(equalTo: window.topAnchor),
                recoveryView.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                recoveryView.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                recoveryView.bottomAnchor.constraint(equalTo: window.bottomAnchor),
            ])
            window.layoutIfNeeded()

            XCTAssertFalse(recoveryView.hasAmbiguousLayout, "ambiguous at width \(width)")
            let action = recoveryView.primaryActionButton
            XCTAssertGreaterThan(action.frame.width, 0, "no action width at \(width)")
            XCTAssertLessThanOrEqual(
                action.frame.width,
                width,
                "action wider than the surface at \(width)"
            )
        }
    }

    /// A drawer thinner than its own chrome is clamped to a presentable
    /// extent. The authored edge is preserved, so this is not a substituted
    /// mode.
    func testUndersizedDrawersClampToAPresentableExtent() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        for edge in [
            ExperienceBehaviorPresentation.Drawer.Edge.bottom,
            .top, .leading, .trailing,
        ] {
            let layout = ExperienceShellLayout(drawer: .init(
                edge: edge,
                extentRatio: 0.02,
                cornerRadius: 0,
                dismissible: false
            ))
            let frame = layout.frame(in: bounds)
            let extent = (edge == .bottom || edge == .top)
                ? frame.height
                : frame.width
            XCTAssertGreaterThanOrEqual(
                extent,
                ExperienceShellLayout.minimumExtent,
                "\(edge) drawer stayed unusably small"
            )
            XCTAssertTrue(bounds.contains(frame), "\(edge) drawer escaped its container")
        }
    }

    // MARK: - Recovery copy

    /// Connectivity copy is reserved for the one case the device itself
    /// reports as offline. Guessing at the user's network for a server or
    /// verification fault sends them to fix something that is not broken.
    func testOnlyGenuineOfflineErrorsClassifyAsOffline() {
        XCTAssertEqual(
            ExperienceShellRecoveryReason(error: URLError(.notConnectedToInternet)),
            .offline
        )
        XCTAssertEqual(
            ExperienceShellRecoveryReason(error: URLError(.dataNotAllowed)),
            .offline
        )
    }

    func testTransportFailuresStayNeutralRatherThanClaimingOffline() {
        for code in [
            URLError.Code.timedOut,
            .networkConnectionLost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .secureConnectionFailed,
        ] {
            XCTAssertEqual(
                ExperienceShellRecoveryReason(error: URLError(code)),
                .unavailable,
                "\(code) is not proof the device is offline"
            )
        }
    }

    func testServerAndVerificationFailuresStayNeutral() {
        XCTAssertEqual(
            ExperienceShellRecoveryReason(error: BoundedHTTPAcquisitionError.httpStatus(500)),
            .unavailable
        )
        XCTAssertEqual(
            ExperienceShellRecoveryReason(error: URLError(.badServerResponse)),
            .unavailable
        )
    }

    @MainActor
    func testRecoveryCopyMentionsConnectivityOnlyWhenOffline() {
        let recoveryView = ExperienceShellRecoveryView(onRetry: {})

        recoveryView.apply(reason: .offline)
        XCTAssertTrue(
            (recoveryView.accessibilityLabel ?? "").lowercased().contains("connection")
        )

        recoveryView.apply(reason: .unavailable)
        let copy = (recoveryView.accessibilityLabel ?? "").lowercased()
        XCTAssertFalse(
            copy.contains("connection") || copy.contains("wi-fi")
                || copy.contains("network") || copy.contains("offline"),
            "a failure the shell cannot attribute must not blame the user's network"
        )
    }

    /// Every recovery state leads with a short title and one explanatory line,
    /// the shape the platform's own interruption screens use.
    @MainActor
    func testRecoveryStatesShowATitleAndAMessage() {
        let recoveryView = ExperienceShellRecoveryView(onRetry: {})

        for reason in [ExperienceShellRecoveryReason.offline, .unavailable] {
            recoveryView.apply(reason: reason)
            let labels = recoveryView.visibleTextLabels
            XCTAssertEqual(
                labels.count,
                2,
                "\(reason) rendered \(labels.count) lines of copy: \(labels)"
            )
            XCTAssertFalse(labels.contains(where: \.isEmpty))
            // The title is the shorter, scannable half.
            XCTAssertLessThan(labels[0].count, labels[1].count)
        }
    }

    /// A drawer may sign any extent in (0, 1], and Dynamic Type can push this
    /// copy past even a full screen. The surface has to stay laid out rather
    /// than forcing UIKit to break a constraint and overlap the action with
    /// the copy exactly when loading has already failed.
    @MainActor
    func testRecoveryStaysLaidOutOnSurfacesTooShortForItsContent() {
        for height in [844.0, 400.0, 211.0, 150.0] as [CGFloat] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: height))
            let recoveryView = ExperienceShellRecoveryView(onRetry: {})
            window.addSubview(recoveryView)
            recoveryView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                recoveryView.topAnchor.constraint(equalTo: window.topAnchor),
                recoveryView.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                recoveryView.trailingAnchor.constraint(equalTo: window.trailingAnchor),
                recoveryView.bottomAnchor.constraint(equalTo: window.bottomAnchor),
            ])
            window.layoutIfNeeded()

            XCTAssertFalse(
                recoveryView.hasAmbiguousLayout,
                "ambiguous layout at height \(height)"
            )
            let action = recoveryView.primaryActionButton
            let copy = recoveryView.copyFrameInSurface
            let actionFrame = action.convert(action.bounds, to: recoveryView)
            XCTAssertGreaterThanOrEqual(
                actionFrame.minY - copy.maxY,
                ExperienceShellRecoveryView.minimumCopyActionGap - 0.5,
                "action crowded the copy at height \(height): "
                    + "action \(actionFrame) copy \(copy)"
            )
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
            // Anything that does not fit must remain reachable by scrolling.
            XCTAssertGreaterThanOrEqual(
                recoveryView.scrollableContentHeight,
                recoveryView.actionFrameInScrollableContent.maxY - 0.5,
                "action was clipped out of reach at height \(height)"
            )
        }
    }

    /// The action spans the surface's gutters and sits low enough to reach
    /// one-handed, rather than floating in the middle of the screen.
    @MainActor
    func testRecoveryActionIsFullWidthAndThumbReachable() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let recoveryView = ExperienceShellRecoveryView(onRetry: {})
        window.addSubview(recoveryView)
        recoveryView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            recoveryView.topAnchor.constraint(equalTo: window.topAnchor),
            recoveryView.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            recoveryView.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            recoveryView.bottomAnchor.constraint(equalTo: window.bottomAnchor),
        ])
        window.layoutIfNeeded()

        let action = recoveryView.primaryActionButton
        let width = action.frame.width
        XCTAssertGreaterThan(width, recoveryView.bounds.width * 0.8)
        XCTAssertLessThan(width, recoveryView.bounds.width)
        XCTAssertGreaterThanOrEqual(action.frame.height, 44)
        // Bottom two-fifths of the surface.
        XCTAssertGreaterThan(action.frame.midY, recoveryView.bounds.height * 0.6)
        XCTAssertLessThan(action.frame.maxY, recoveryView.bounds.height)
    }

    @MainActor
    func testRecoveryUsesTheClassifiedReasonFromAFailedAcquisition() async {
        let controller = MockExperienceViewController(
            mockExperienceVersionId: "version-recovery-reason",
            recoveryAffordanceDelay: 0.02,
            artifactLoadError: URLError(.notConnectedToInternet)
        )
        controller.configurePresentationShell(Self.shell())
        _ = controller.view
        controller.markPresentationShellPresented(traceToken: nil)
        try? await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertFalse(controller.errorView.isHidden)
        XCTAssertEqual(controller.shellRecoveryView?.reason, .offline)
        await controller.shutdownRuntime()
    }

    // MARK: - Mode fidelity

    /// The authenticated descriptor is authoritative: every supported style
    /// maps to its own UIKit geometry and none of them fall through to
    /// another mode's behavior.
    @MainActor
    func testConfiguratorMapsEachSignedStyleToItsOwnGeometry() {
        let configurator = ExperienceShellPresentationConfigurator()

        let fullScreen = UIViewController()
        configurator.configure(fullScreen, shell: Self.shell())
        XCTAssertEqual(fullScreen.modalPresentationStyle, .fullScreen)

        let sheet = UIViewController()
        configurator.configure(
            sheet,
            shell: ExperienceShellContract(
                presentation: .init(
                    style: .sheet,
                    orientation: .portrait,
                    backgroundColor: "#12233BFF",
                    sheet: .init(detent: .medium, dismissible: true),
                    drawer: nil
                ),
                screen: .init(width: 390, height: 844)
            )
        )
        XCTAssertEqual(sheet.modalPresentationStyle, .pageSheet)
        XCTAssertFalse(sheet.isModalInPresentation)

        let drawer = UIViewController()
        configurator.configure(
            drawer,
            shell: ExperienceShellContract(
                presentation: .init(
                    style: .drawer,
                    orientation: .portrait,
                    backgroundColor: "#1B1206FF",
                    sheet: nil,
                    drawer: .init(
                        edge: .bottom,
                        extentRatio: 0.55,
                        cornerRadius: 28,
                        dismissible: true
                    )
                ),
                screen: .init(width: 390, height: 844)
            )
        )
        XCTAssertEqual(drawer.modalPresentationStyle, .custom)
        XCTAssertNotNil(drawer.transitioningDelegate)
    }

    @MainActor
    func testNonDismissibleSheetRefusesInteractiveDismissal() {
        let configurator = ExperienceShellPresentationConfigurator()
        let sheet = UIViewController()
        configurator.configure(
            sheet,
            shell: ExperienceShellContract(
                presentation: .init(
                    style: .sheet,
                    orientation: .portrait,
                    backgroundColor: "#123326FF",
                    sheet: .init(detent: .large, dismissible: false),
                    drawer: nil
                ),
                screen: .init(width: 390, height: 844)
            )
        )
        XCTAssertTrue(sheet.isModalInPresentation)
        XCTAssertEqual(sheet.sheetPresentationController?.prefersGrabberVisible, false)
    }

    /// A drawer style signed without drawer geometry cannot be honored. It
    /// fails closed to full screen instead of borrowing sheet behavior.
    @MainActor
    func testDrawerWithoutGeometryFailsClosedToFullScreen() {
        let configurator = ExperienceShellPresentationConfigurator()
        let controller = UIViewController()
        configurator.configure(
            controller,
            shell: ExperienceShellContract(
                presentation: .init(
                    style: .drawer,
                    orientation: .portrait,
                    backgroundColor: "#1B1206FF",
                    sheet: nil,
                    drawer: nil
                ),
                screen: .init(width: 390, height: 844)
            )
        )
        XCTAssertEqual(controller.modalPresentationStyle, .fullScreen)
        XCTAssertNil(controller.transitioningDelegate)
    }

    // MARK: - Helpers

    private static func shell(
        background: String = "#0B1220FF"
    ) -> ExperienceShellContract {
        ExperienceShellContract(
            presentation: .init(
                style: .fullScreen,
                orientation: .portrait,
                backgroundColor: background,
                sheet: nil,
                drawer: nil
            ),
            screen: .init(width: 390, height: 844)
        )
    }
}
#endif

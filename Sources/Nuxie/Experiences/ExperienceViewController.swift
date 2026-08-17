import Foundation
import UserNotifications
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(CoreLocation) && !os(macOS)
import CoreLocation
#endif
#if canImport(Photos)
import Photos
#endif
#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(SafariServices)
import SafariServices
#endif

// @unchecked Sendable: immutable snapshot; the [String: Any] payload is
// write-once at construction and never mutated afterwards.
struct ExperienceRendererEvent: @unchecked Sendable {
    let name: String
    let properties: [String: Any]
    let screenId: String?
    let componentId: String?
    let instanceId: String?
}

// @unchecked Sendable: immutable snapshot; the Any value is write-once at
// construction and never mutated afterwards.
struct ExperienceRendererViewModelChange: @unchecked Sendable {
    let path: VmPathRef
    let value: Any
    let source: String?
    let screenId: String?
    let instanceId: String?
    let isTrigger: Bool
}

struct ExperienceRendererOpenLinkRequest {
    let urlString: String
    let target: String?
    let screenId: String?
    let instanceId: String?
}

/// Invoked by the MainActor-isolated ExperienceViewController.
@MainActor
protocol ExperienceRuntimeDelegate: AnyObject {
    /// Commits authenticated pre-presentation journey state before the
    /// renderer activates the initial screen and emits lifecycle callbacks.
    func experienceViewControllerWillActivateInitialScreen(
        _ controller: ExperienceViewController
    ) async -> Bool

    func experienceViewControllerDidBecomeReady(_ controller: ExperienceViewController)

    func experienceViewControllerDidPresentShell(_ controller: ExperienceViewController)

    func experienceViewControllerDidReveal(_ controller: ExperienceViewController)

    func experienceViewControllerDidFinishPresentation(_ controller: ExperienceViewController)

    func experienceViewController(
        _ controller: ExperienceViewController,
        didChangeScreen screenId: String
    ) async

    func experienceViewController(
        _ controller: ExperienceViewController,
        didDismissScreen screenId: String,
        revealingScreenId: String?,
        method: String
    ) async

    func experienceViewController(
        _ controller: ExperienceViewController,
        didEmitEvent event: ExperienceRendererEvent
    )

    func experienceViewController(
        _ controller: ExperienceViewController,
        didEmitViewModelChange change: ExperienceRendererViewModelChange
    )

    func experienceViewController(
        _ controller: ExperienceViewController,
        didRequestOpenLink request: ExperienceRendererOpenLinkRequest
    )

    func experienceViewController(
        _ controller: ExperienceViewController,
        didPresentDrawable drawable: ExperienceRuntimePresentedDrawable,
        screenId: String,
        frameNumber: UInt64
    )

    func experienceViewController(
        _ controller: ExperienceViewController,
        didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput,
        screenId: String
    )

    func experienceViewControllerDidRequestDismiss(_ controller: ExperienceViewController, reason: CloseReason)
}

protocol NotificationPermissionEventReceiver: AnyObject {
    func experienceViewController(
        _ controller: ExperienceViewController,
        didResolveNotificationPermissionEvent eventName: String,
        properties: sending [String: Any],
        journeyId: String
    )
}

protocol TrackingPermissionEventReceiver: AnyObject {
    func experienceViewController(
        _ controller: ExperienceViewController,
        didResolveTrackingPermissionEvent eventName: String,
        properties: sending [String: Any],
        journeyId: String
    )
}

protocol RequestPermissionEventReceiver: AnyObject {
    func experienceViewController(
        _ controller: ExperienceViewController,
        didResolveRequestPermissionEvent eventName: String,
        properties: sending [String: Any],
        journeyId: String
    )

    func experienceViewController(
        _ controller: ExperienceViewController,
        didIgnoreUnsupportedRequestPermissionType permissionType: String,
        journeyId: String
    )
}

extension ExperienceRuntimeDelegate {
    func experienceViewControllerWillActivateInitialScreen(
        _ controller: ExperienceViewController
    ) async -> Bool { true }

    func experienceViewControllerDidBecomeReady(_ controller: ExperienceViewController) {}

    func experienceViewControllerDidPresentShell(_ controller: ExperienceViewController) {}

    func experienceViewControllerDidReveal(_ controller: ExperienceViewController) {}

    func experienceViewControllerDidFinishPresentation(_ controller: ExperienceViewController) {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didChangeScreen screenId: String
    ) async {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didDismissScreen screenId: String,
        revealingScreenId: String?,
        method: String
    ) async {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didEmitEvent event: ExperienceRendererEvent
    ) {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didEmitViewModelChange change: ExperienceRendererViewModelChange
    ) {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didRequestOpenLink request: ExperienceRendererOpenLinkRequest
    ) {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didPresentDrawable drawable: ExperienceRuntimePresentedDrawable,
        screenId: String,
        frameNumber: UInt64
    ) {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput,
        screenId: String
    ) {}
}

/// ExperienceViewController - displays native experience content with loading and error states.
public class ExperienceViewController: NuxiePlatformViewController {
    private enum NativeRuntimeCommand {
        case viewModelSnapshot(ExperienceViewModelSnapshot, screenId: String?)
        case viewModelValue(path: VmPathRef, value: Any, screenId: String?, instanceId: String?)
        case viewModelList(operation: ExperienceViewModelListOperation, path: VmPathRef, payload: [String: Any], screenId: String?, instanceId: String?)
        case viewModelTrigger(path: VmPathRef, screenId: String?, instanceId: String?)
        case navigate(screenId: String, transition: Any?)
    }

    #if canImport(UIKit)
    private struct ActiveNativeRuntimeNavigation {
        let id: UUID
        let command: NativeRuntimeCommand
        let generation: UInt64
        let coordinatorID: ObjectIdentifier
    }
    #endif

    // MARK: - Properties

    private let viewModel: ExperienceViewModel
    /// System-permission resolution (status checks, usage-description
    /// gating, authorization requests). The VC keeps orchestration and event
    /// dispatch; the coordinator owns everything that talks to the system.
    let permissions = ExperiencePermissionCoordinator()

    // Forwarding seams so tests keep configuring handlers on the controller.
    var notificationAuthorizationHandler: NotificationAuthorizationHandling {
        get { permissions.notificationAuthorizationHandler }
        set { permissions.notificationAuthorizationHandler = newValue }
    }
    var cameraPermissionAuthorizationHandler: PermissionAuthorizationHandling {
        get { permissions.cameraPermissionAuthorizationHandler }
        set { permissions.cameraPermissionAuthorizationHandler = newValue }
    }
    var locationPermissionAuthorizationHandler: PermissionAuthorizationHandling {
        get { permissions.locationPermissionAuthorizationHandler }
        set { permissions.locationPermissionAuthorizationHandler = newValue }
    }
    var microphonePermissionAuthorizationHandler: PermissionAuthorizationHandling {
        get { permissions.microphonePermissionAuthorizationHandler }
        set { permissions.microphonePermissionAuthorizationHandler = newValue }
    }
    var photoLibraryPermissionAuthorizationHandler: PermissionAuthorizationHandling {
        get { permissions.photoLibraryPermissionAuthorizationHandler }
        set { permissions.photoLibraryPermissionAuthorizationHandler = newValue }
    }
    var trackingAuthorizationHandler: TrackingAuthorizationHandling {
        get { permissions.trackingAuthorizationHandler }
        set { permissions.trackingAuthorizationHandler = newValue }
    }
    var cameraUsageDescriptionProvider: () -> String? {
        get { permissions.cameraUsageDescriptionProvider }
        set { permissions.cameraUsageDescriptionProvider = newValue }
    }
    var locationUsageDescriptionProvider: () -> String? {
        get { permissions.locationUsageDescriptionProvider }
        set { permissions.locationUsageDescriptionProvider = newValue }
    }
    var microphoneUsageDescriptionProvider: () -> String? {
        get { permissions.microphoneUsageDescriptionProvider }
        set { permissions.microphoneUsageDescriptionProvider = newValue }
    }
    var photoLibraryUsageDescriptionProvider: () -> String? {
        get { permissions.photoLibraryUsageDescriptionProvider }
        set { permissions.photoLibraryUsageDescriptionProvider = newValue }
    }
    var trackingUsageDescriptionProvider: () -> String? {
        get { permissions.trackingUsageDescriptionProvider }
        set { permissions.trackingUsageDescriptionProvider = newValue }
    }

    /// Delegate for runtime bridge messages
    weak var runtimeDelegate: ExperienceRuntimeDelegate? {
        didSet {
            if let receiver = runtimeDelegate as? NotificationPermissionEventReceiver {
                notificationPermissionEventReceiver = receiver
            }
            if let receiver = runtimeDelegate as? TrackingPermissionEventReceiver {
                trackingPermissionEventReceiver = receiver
            }
            if let receiver = runtimeDelegate as? RequestPermissionEventReceiver {
                requestPermissionEventReceiver = receiver
            }
        }
    }

    /// Dedicated receiver for native notification permission results.
    ///
    /// This is retained separately from `runtimeDelegate` because permission
    /// responses can arrive after the journey delegate has been removed from the
    /// active journey maps during identity changes or cancellation.
    var notificationPermissionEventReceiver: NotificationPermissionEventReceiver?
    var requestPermissionEventReceiver: RequestPermissionEventReceiver?
    var trackingPermissionEventReceiver: TrackingPermissionEventReceiver?

    /// Closure called when the experience is closed
    public var onClose: ((CloseReason) -> Void)?

    public var colorSchemeMode: ExperienceColorSchemeMode = .light {
        didSet {
            guard oldValue != colorSchemeMode else { return }
            guard isViewLoaded else { return }
            applyColorSchemeMode()
        }
    }

    // UI Components
    #if canImport(UIKit)
    private var screenTransitionCoordinator: ExperienceScreenTransitionCoordinator?
    private var runtimeCallbackCoordinator: ExperienceScreenTransitionCoordinator?
    private var loadedArtifact: LoadedExperienceArtifact?
    private let runtimeSession = ExperienceRuntimeLifecycleSession<
        NativeRuntimeCommand,
        ActiveNativeRuntimeNavigation
    >()
    #endif
    private var runtimePresentationTraceToken: ExperiencePresentationTraceToken?
    private var pendingDisplayPresentationTrace: (
        generation: UInt64,
        context: ExperiencePresentationTraceContext,
        span: ExperiencePresentationTraceSpan
    )?
    var presentationTraceContext: ExperiencePresentationTraceContext? {
        didSet {
            viewModel.updatePresentationTraceContext(presentationTraceContext)
        }
    }
    #if canImport(UIKit)
    var loadingView: UIView!
    var loadingShimmerView: ExperienceShellShimmerView!
    var errorView: UIView!
    var activityIndicator: UIActivityIndicatorView!
    var loadingLabel: UILabel!
    var refreshButton: UIButton!
    var closeButton: UIButton!
    #elseif canImport(AppKit)
    var loadingView: NSView!
    var errorView: NSView!
    var activityIndicator: NSProgressIndicator!
    var loadingLabel: NSTextField!
    var refreshButton: NSButton!
    var closeButton: NSButton!
    #endif

    private var presentationShellIsPresented = false
    private var contentIsRevealed = false
    private var didNotifyPresentationReveal = false
    private var revealGate = ExperienceRevealGate()
    #if !canImport(UIKit)
    private var pendingNativeRuntimeCommands: [NativeRuntimeCommand] = []
    #endif
    private var didInvokeClose = false
    private var closeGeneration: UInt64 = 0
    private var runtimePreparationGeneration: UInt64 = 0
    private var runtimeShutdownTask: Task<Void, Never>?
    private var runtimeShutdownID: UUID?
    private var presentationTraceToken: ExperiencePresentationTraceToken?
    private var presentationInitialScreenID: String?
    private(set) var presentationShellContract: ExperienceShellContract?
    private(set) var suppressesLoadingTreatmentForPresentation = false
    private var presentationWarmReservation: ExperiencePresentationWarmReservation?
    var presentationRevealGeneration: UInt64 = 0
    private(set) var experienceContentIsHidden = true
    private let recoveryAffordanceDelay: TimeInterval
    private var recoveryAffordanceTask: Task<Void, Never>?

    // MARK: - Computed Properties

    var experience: Experience {
        return viewModel.experience
    }

    var products: [ExperienceProduct] {
        return viewModel.products
    }

    // Constructor-injected StoreKit collaborators (Phase 4c).
    private let transactionService: TransactionService
    private let productService: ProductService
    private let systemEventSink: SystemEventSink

    // MARK: - Initialization

    init(
        experience: Experience,
        artifactLoader: @escaping ExperienceArtifactLoader,
        artifactTelemetryContext: ExperienceArtifactTelemetryContext? = nil,
        eventLog: EventCapturing,
        loadingTimeoutSeconds: TimeInterval = 15.0,
        recoveryAffordanceDelay: TimeInterval = 5.0,
        transactionService: TransactionService,
        productService: ProductService,
        systemEventSink: SystemEventSink
    ) {
        self.transactionService = transactionService
        self.productService = productService
        self.systemEventSink = systemEventSink
        self.recoveryAffordanceDelay = recoveryAffordanceDelay
        self.viewModel = ExperienceViewModel(
            experience: experience,
            artifactTelemetryContext: artifactTelemetryContext,
            loadingTimeoutSeconds: loadingTimeoutSeconds,
            artifactLoader: artifactLoader,
            eventLog: eventLog
        )
        super.init(nibName: nil, bundle: nil)

        setupBindings()
        LogDebug("ExperienceViewController initialized for experience: \(experience.id)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        applyColorSchemeMode()
        viewModel.loadExperience()
    }

    #if canImport(UIKit)
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // View controllers are cached and re-presented (ExperienceViewControllerCache);
        // without this reset a re-presented experience would never fire onClose again,
        // leaking the presentation window and dropping dismissal analytics.
        didInvokeClose = false
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
    }

    public override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        // Each screen controller also observes its own view's insets; this
        // host-level fan-out covers cached screens whose views are not
        // currently in the hierarchy when the environment changes.
        screenTransitionCoordinator?.syncSafeAreaInsets()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        screenTransitionCoordinator?.layoutTextInputs()
    }

    /// Orientations authenticated by the current experience presentation contract.
    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch presentationShellContract?.presentation.orientation ?? .any {
        case .portrait: .portrait
        case .landscape: .landscape
        case .any: .all
        }
    }

    /// Preferred initial orientation authenticated by the presentation contract.
    public override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        switch presentationShellContract?.presentation.orientation ?? .any {
        case .portrait: .portrait
        case .landscape: .landscapeLeft
        case .any: .unknown
        }
    }
    #endif

    // MARK: - Public Methods


    func updateProducts(_ newProducts: [ExperienceProduct]) {
        viewModel.updateProducts(newProducts)
    }

    func updateExperienceIfNeeded(_ newExperience: Experience) {
        viewModel.updateExperienceIfNeeded(newExperience)
    }

    func updateArtifactTelemetryContext(_ context: ExperienceArtifactTelemetryContext) {
        viewModel.updateArtifactTelemetryContext(context)
    }

    func configurePresentationShell(
        _ contract: ExperienceShellContract?,
        suppressLoadingTreatment: Bool = false,
        warmReservation: ExperiencePresentationWarmReservation? = nil
    ) {
        presentationWarmReservation?.release()
        presentationWarmReservation = warmReservation
        presentationShellContract = contract
        suppressesLoadingTreatmentForPresentation = suppressLoadingTreatment
        guard isViewLoaded else { return }
        platformApplyPresentationShell(contract)
    }

    /// Resets presentation-scoped state and starts fresh interactive screens for
    /// cached controllers. A newly created controller begins artifact loading
    /// when its view is first loaded; a reused controller reacquires its
    /// artifact and never shares the previous presentation's runtime state.
    func prepareForPresentation(
        traceToken: ExperiencePresentationTraceToken?,
        initialScreenID: String? = nil
    ) async {
        presentationInitialScreenID = initialScreenID
        viewModel.setInitialScreenID(initialScreenID)
        let preparationGeneration = beginPresentationScope(
            traceToken: traceToken
        )
        let wasViewLoaded = isViewLoaded
        await joinRuntimeShutdown()
        guard runtimePreparationGeneration == preparationGeneration else {
            return
        }

        #if canImport(UIKit)
        if wasViewLoaded {
            viewModel.loadExperience()
        } else {
            loadViewIfNeeded()
        }
        #endif
    }

    @discardableResult
    func beginPresentationScope(
        traceToken: ExperiencePresentationTraceToken?
    ) -> UInt64 {
        failPendingDisplayPresentationTrace(error: CancellationError())
        presentationTraceToken = traceToken
        closeGeneration &+= 1
        didInvokeClose = false
        presentationShellIsPresented = false
        contentIsRevealed = false
        didNotifyPresentationReveal = false
        revealGate = ExperienceRevealGate()
        cancelRecoveryAffordances()
        runtimePreparationGeneration &+= 1
        return runtimePreparationGeneration
    }

    private func beginDisplayPresentationTrace(generation: UInt64) {
        guard let context = presentationTraceContext else { return }
        failPendingDisplayPresentationTrace(error: CancellationError())
        pendingDisplayPresentationTrace = (
            generation: generation,
            context: context,
            span: context.begin(.displayPresentation)
        )
    }

    private func failPendingDisplayPresentationTrace(
        generation: UInt64? = nil,
        error: Error
    ) {
        guard let pendingDisplayPresentationTrace,
              generation == nil
                || pendingDisplayPresentationTrace.generation == generation else {
            return
        }
        self.pendingDisplayPresentationTrace = nil
        pendingDisplayPresentationTrace.context.fail(
            pendingDisplayPresentationTrace.span,
            error: error
        )
    }

    private func completePendingDisplayPresentationTrace(
        drawable: ExperienceRuntimePresentedDrawable,
        screenId: String,
        frameNumber: UInt64
    ) {
        guard let pendingDisplayPresentationTrace else { return }
        self.pendingDisplayPresentationTrace = nil
        pendingDisplayPresentationTrace.context.completeDisplayPresentation(
            pendingDisplayPresentationTrace.span,
            presentedMonotonicTime: drawable.presentedTime,
            observedAt: .now(),
            attributes: [
                "frame_number": String(frameNumber),
                "screen_id": screenId,
            ]
        )
    }

    func markPresentationShellPresented(
        traceToken: ExperiencePresentationTraceToken?
    ) {
        guard !presentationShellIsPresented else { return }
        presentationShellIsPresented = true
        if let scopedDelegate = runtimeDelegate as? any ExperiencePresentationScopedTraceDelegate {
            scopedDelegate.experienceViewControllerDidPresentShell(
                self,
                traceToken: traceToken
            )
        } else {
            runtimeDelegate?.experienceViewControllerDidPresentShell(self)
        }
        scheduleRecoveryAffordancesIfNeeded()
        notifyPresentationRevealIfVisible()
    }

    /// Deterministically releases every presentation-owned interactive screen.
    /// A later presentation reloads the cached artifact through ExperienceViewModel
    /// and opens an entirely new native ownership graph.
    func shutdownRuntime() async {
        releasePresentationWarmReservation()
        cancelRecoveryAffordances()
        failPendingDisplayPresentationTrace(error: CancellationError())
        await prepareForDismissal()
        // Explicit shutdown revokes any preparation currently waiting for the
        // same teardown, so it cannot restart acquisition after cleanup wins.
        runtimePreparationGeneration &+= 1
        await joinRuntimeShutdown()
    }

    func prepareForDismissal(reason: CloseReason? = nil) async {
        failPendingDisplayPresentationTrace(error: CancellationError())
        #if canImport(UIKit)
        await screenTransitionCoordinator?.exitActiveScreenForTeardown(reason: reason)
        #endif
    }

    private func joinRuntimeShutdown() async {
        if let runtimeShutdownTask {
            await runtimeShutdownTask.value
            return
        }

        let shutdownID = UUID()
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }
            await self.performRuntimeShutdown()
            // Clear ownership before waking joiners. A preparation resumed by
            // this task may start a new mount immediately; a subsequent
            // shutdown must create fresh teardown work for that new owner.
            if self.runtimeShutdownID == shutdownID {
                self.runtimeShutdownTask = nil
                self.runtimeShutdownID = nil
            }
        }
        runtimeShutdownID = shutdownID
        runtimeShutdownTask = task
        await task.value
    }

    private func performRuntimeShutdown() async {
        // This method performs the native invalidation itself. Suppress the
        // ViewModel callback to avoid constructing a second teardown task.
        viewModel.cancelLoading(notifyInvalidation: false)

        #if canImport(UIKit)
        let work = runtimeSession.beginTeardown()

        let coordinator = screenTransitionCoordinator
        screenTransitionCoordinator = nil
        runtimeCallbackCoordinator = nil
        runtimePresentationTraceToken = nil
        loadedArtifact = nil
        await coordinator?.tearDown()
        await work.mountTask?.value
        await work.failureTask?.value
        runtimeSession.finishTeardown(generation: work.generation)
        #else
        pendingNativeRuntimeCommands.removeAll()
        #endif
    }

    func performPurchase(productId: String, placementIndex: Any? = nil) {
        let offerId = products.first(where: { $0.id == productId })?.offer?.id
        handleNativePurchase(productId: productId, offerId: offerId)
    }

    func performRestore() {
        handleNativeRestore()
    }

    func performRequestNotifications(journeyId: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.permissions.resolveNotificationAuthorization()
            let properties = self.journeyScopedEventProperties(journeyId: journeyId)
            let eventName: String
            switch outcome {
            case .enabled:
                eventName = SystemEventNames.notificationsEnabled
            case .denied:
                eventName = SystemEventNames.notificationsDenied
            }
            self.dispatchNotificationPermissionEvent(
                eventName,
                properties: properties,
                journeyId: journeyId
            )
        }
    }

    func performRequestPermission(permissionType: String, journeyId: String? = nil) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let resolution = await self.permissions.resolveRequestPermission(
                permissionType: permissionType
            )
            guard case let .status(outcome) = resolution else {
                self.handleUnsupportedRequestPermission(
                    permissionType: permissionType,
                    journeyId: journeyId
                )
                return
            }
            guard outcome != .unsupported else {
                self.handleUnsupportedRequestPermission(
                    permissionType: permissionType,
                    journeyId: journeyId
                )
                return
            }
            let properties = self.permissionEventProperties(
                journeyId: journeyId,
                permissionType: permissionType
            )
            let eventName: String
            switch outcome {
            case .granted:
                eventName = SystemEventNames.permissionGranted
            case .denied, .restricted, .notDetermined:
                eventName = SystemEventNames.permissionDenied
            case .limited:
                eventName = SystemEventNames.permissionGranted
            case .unsupported:
                return
            }
            self.dispatchRequestPermissionEvent(
                eventName,
                properties: properties,
                journeyId: journeyId
            )
        }
    }

    func performRequestTracking(journeyId: String? = nil) {
        let currentStatus = trackingAuthorizationHandler.authorizationStatus()
        if currentStatus == .unsupported {
            LogWarning("ExperienceViewController: tracking authorization is unsupported on this platform; skipping event")
            if let journeyId, !journeyId.isEmpty,
               let receiver = trackingPermissionEventReceiver {
                // Boxed to hand the write-once payload to the receiver.
                let propertiesBox = UncheckedSendable(journeyScopedEventProperties(journeyId: journeyId))
                receiver.experienceViewController(
                    self,
                    didResolveTrackingPermissionEvent: SystemEventNames.trackingDenied,
                    properties: propertiesBox.value,
                    journeyId: journeyId
                )
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.permissions.resolveTrackingAuthorization(
                currentStatus: currentStatus
            )
            let properties = self.journeyScopedEventProperties(journeyId: journeyId)
            let eventName: String
            switch outcome {
            case .authorized:
                eventName = SystemEventNames.trackingAuthorized
            case .denied:
                eventName = SystemEventNames.trackingDenied
            case .unsupported:
                return
            }
            self.dispatchTrackingPermissionEvent(
                eventName,
                properties: properties,
                journeyId: journeyId
            )
        }
    }

    func emitSystemEvent(_ name: String, properties: [String: Any]) {
        systemEventSink.emit(name, properties: properties.isEmpty ? nil : properties)
    }

    func performDismiss(reason: CloseReason = .userDismissed) {
        let generation = closeGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareForDismissal(reason: reason)
            self.runtimeDelegate?.experienceViewControllerDidRequestDismiss(self, reason: reason)

            #if canImport(UIKit)
            self.dismiss(animated: true) { [weak self] in
                self?.invokeOnCloseOnce(reason, generation: generation)
            }
            #elseif canImport(AppKit)
            self.view.window?.orderOut(nil)
            self.invokeOnCloseOnce(reason, generation: generation)
            #endif

            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.invokeOnCloseOnce(reason, generation: generation)
        }
    }

    /// Completes the ordinary dismissal lifecycle after UIKit has already
    /// removed an interactively dismissible sheet or drawer.
    @MainActor
    func performInteractiveDismissal(reason: CloseReason = .userDismissed) {
        guard !didInvokeClose else { return }
        let generation = closeGeneration
        let dismissalDelegate = runtimeDelegate
        let close = onClose
        didInvokeClose = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareForDismissal(reason: reason)
            guard self.closeGeneration == generation else { return }
            dismissalDelegate?.experienceViewControllerDidRequestDismiss(
                self,
                reason: reason
            )
            close?(reason)
        }
    }

    func performOpenLink(urlString: String, target: String? = nil) {
        guard let url = URL(string: urlString) else { return }
        let normalizedTarget = target?.lowercased()

        if normalizedTarget == "in_app" {
            let scheme = url.scheme?.lowercased()
            guard scheme == "http" || scheme == "https" else { return }
            #if canImport(UIKit)
            let safariViewController = SFSafariViewController(url: url)
            present(safariViewController, animated: true)
            #elseif canImport(AppKit)
            NSWorkspace.shared.open(url)
            #endif
            return
        }

        #if canImport(UIKit)
        guard UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }

    func applyViewModelSnapshot(_ snapshot: ExperienceViewModelSnapshot, screenId: String? = nil) {
        enqueueNativeRuntimeCommand(.viewModelSnapshot(snapshot, screenId: screenId))
    }

    func applyViewModelValue(
        path: VmPathRef,
        value: Any,
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        enqueueNativeRuntimeCommand(
            .viewModelValue(
                path: path,
                value: value,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    func applyViewModelListOperation(
        _ operation: ExperienceViewModelListOperation,
        path: VmPathRef,
        payload: [String: Any],
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        enqueueNativeRuntimeCommand(
            .viewModelList(
                operation: operation,
                path: path,
                payload: payload,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    func fireViewModelTrigger(
        path: VmPathRef,
        screenId: String? = nil,
        instanceId: String? = nil
    ) {
        enqueueNativeRuntimeCommand(
            .viewModelTrigger(
                path: path,
                screenId: screenId,
                instanceId: instanceId
            )
        )
    }

    func navigate(to screenId: String, transition: Any? = nil) {
        enqueueNativeRuntimeCommand(.navigate(screenId: screenId, transition: transition))
    }

    // MARK: - Setup

    private func setupBindings() {
        // Bind to view model state changes
        viewModel.onStateChanged = { [weak self] state in
            self?.updateUIState(state)
        }

        viewModel.onLoadStarted = { [weak self] in
            self?.beginNativeRuntimeLoad()
        }

        viewModel.onLoadInvalidated = { [weak self] in
            self?.invalidateNativeRuntimeLoad()
        }

        viewModel.onLoadArtifact = { [weak self] artifact in
            self?.mountArtifact(artifact)
        }
    }

    private func setupViews() {
        platformApplyDefaultBackgroundColor()
        #if canImport(UIKit)
        view.clipsToBounds = true
        #endif

        platformSetupLoadingView()
        platformSetupErrorView()
        platformApplyPresentationShell(presentationShellContract)

        // Start in loading state
        updateUIState(.loading)
    }

    private func mountArtifact(_ acquisition: AcquiredExperienceArtifact) {
        #if canImport(UIKit)
        guard let mount = runtimeSession.beginMount() else { return }
        let generation = mount.generation
        let traceToken = presentationTraceToken

        let task = Task { @MainActor [weak self] in
            guard let self else { return }

            await mount.previousTask?.value
            guard !Task.isCancelled,
                  self.runtimeSession.isMounting(generation) else {
                return
            }

            let previousCoordinator = self.screenTransitionCoordinator
            self.screenTransitionCoordinator = nil
            await previousCoordinator?.tearDown()
            guard !Task.isCancelled,
                  self.runtimeSession.isMounting(generation) else {
                return
            }

            var candidate: ExperienceScreenTransitionCoordinator?
            do {
                try Task.checkCancellation()
                guard self.runtimeSession.isMounting(generation) else {
                    throw CancellationError()
                }
                let artifact = LoadedExperienceArtifact(acquired: acquisition)
                self.loadedArtifact = artifact

                let coordinator = ExperienceScreenTransitionCoordinator(
                    experience: self.experience,
                    artifact: artifact,
                    initialScreenID: self.presentationInitialScreenID,
                    hostViewController: self,
                    screenDelegate: self,
                    onPresentedScreenDismissed: { [weak self] dismissedScreenId, revealingScreenId in
                        await self?.handleNativePresentedScreenDismissed(
                            dismissedScreenId: dismissedScreenId,
                            revealingScreenId: revealingScreenId,
                            generation: generation
                        )
                    },
                    onScreenHidden: { [weak self] screenId, context in
                        await self?.handleNativeScreenHidden(
                            screenId: screenId,
                            context: context,
                            generation: generation
                        )
                    },
                    onScreenActive: { [weak self] screenId in
                        await self?.handleNativeScreenActive(
                            screenId: screenId,
                            generation: generation
                        )
                    },
                    onRuntimeFailure: { [weak self] screenId, error in
                        self?.latchNativeRuntimeFailure(
                            error,
                            screenId: screenId,
                            generation: generation
                        )
                    }
                )
                candidate = coordinator
                self.runtimeCallbackCoordinator = coordinator
                let preparedRIVStatus = await artifact.acquired.interactivePreparation.status()
                let runtimeSpan = self.presentationTraceContext?.begin(
                    .runtimePreparation,
                    attributes: [
                        "entry_screen_id": self.presentationInitialScreenID
                            ?? artifact.renderPlan.entry.screenId,
                        "prepared_riv_status": preparedRIVStatus.rawValue,
                        "riv_sha256": artifact.renderPlan.scene.sha256,
                    ]
                )
                do {
                    try await coordinator.install()
                    if let runtimeSpan {
                        let resourceMetrics = await artifact.acquired
                            .interactivePreparation.consumeResourceMetrics()
                        self.presentationTraceContext?.complete(
                            runtimeSpan,
                            attributes: resourceMetrics
                                .qualificationTraceAttributes
                        )
                    }
                    self.beginDisplayPresentationTrace(generation: generation)
                } catch {
                    if let runtimeSpan {
                        let resourceMetrics = await artifact.acquired
                            .interactivePreparation.consumeResourceMetrics()
                        self.presentationTraceContext?.fail(
                            runtimeSpan,
                            error: error,
                            attributes: resourceMetrics
                                .qualificationTraceAttributes
                        )
                    }
                    throw error
                }
                try Task.checkCancellation()
                guard self.runtimeSession.isMounting(generation) else {
                    throw CancellationError()
                }

                coordinator.setContentHidden(true)
                self.screenTransitionCoordinator = coordinator
                self.runtimePresentationTraceToken = traceToken
                candidate = nil
                await self.handleNativeRuntimeReady(
                    generation: generation,
                    coordinator: coordinator
                )
                LogDebug("Mounted native experience artifact for experience \(self.experience.id)")
            } catch is CancellationError {
                self.failPendingDisplayPresentationTrace(
                    generation: generation,
                    error: CancellationError()
                )
                await candidate?.tearDown()
                if let candidate,
                   self.runtimeCallbackCoordinator === candidate {
                    self.runtimeCallbackCoordinator = nil
                }
            } catch {
                self.failPendingDisplayPresentationTrace(
                    generation: generation,
                    error: error
                )
                await candidate?.tearDown()
                if let candidate,
                   self.runtimeCallbackCoordinator === candidate {
                    self.runtimeCallbackCoordinator = nil
                }
                self.latchNativeRuntimeFailure(
                    error,
                    screenId: self.experience.journey.screens.first?.id ?? "unknown",
                    generation: generation
                )
            }

            self.runtimeSession.clearMountTask(generation: generation)
        }
        runtimeSession.ownMountTask(task, generation: generation)
        #else
        viewModel.handleLoadingFailed(
            ExperienceError.configurationFailed(
                ExperienceReleaseAcquisitionError.requiredObjectUnavailable(
                    "Nuxie runtime unavailable"
                )
            )
        )
        #endif
    }

    #if canImport(UIKit)
    private func beginNativeRuntimeLoad() {
        revealGate = ExperienceRevealGate()
        failPendingDisplayPresentationTrace(error: CancellationError())
        let interruptedCommand = runtimeSession.activeNavigation?.command
        let previousWork = runtimeSession.beginLoading(requeue: interruptedCommand)
        let previousCoordinator = screenTransitionCoordinator
        screenTransitionCoordinator = nil
        runtimeCallbackCoordinator = nil
        runtimePresentationTraceToken = nil

        let generation = runtimeSession.generation
        let task = Task { @MainActor in
            await previousWork.mountTask?.value
            await previousWork.failureTask?.value
            await previousCoordinator?.tearDown()
        }
        runtimeSession.ownMountTask(task, generation: generation)
    }

    private func invalidateNativeRuntimeLoad() {
        failPendingDisplayPresentationTrace(error: CancellationError())
        let invalidation = runtimeSession.invalidateLoading()
        let previousCoordinator = screenTransitionCoordinator
        screenTransitionCoordinator = nil
        runtimeCallbackCoordinator = nil
        runtimePresentationTraceToken = nil

        let task = Task { @MainActor in
            await invalidation.work.mountTask?.value
            await invalidation.work.failureTask?.value
            await previousCoordinator?.tearDown()
        }
        runtimeSession.ownMountTask(task, generation: invalidation.generation)
    }

    private func latchNativeRuntimeFailure(
        _ error: Error,
        screenId: String,
        generation: UInt64
    ) {
        guard runtimeSession.latchTerminalFailure(generation: generation) else {
            return
        }
        failPendingDisplayPresentationTrace(generation: generation, error: error)

        let coordinator = screenTransitionCoordinator
        screenTransitionCoordinator = nil
        runtimeCallbackCoordinator = nil
        runtimePresentationTraceToken = nil
        let previousFailureTask = runtimeSession.failureTask
        let task = Task<Void, Never> { @MainActor [weak self] in
            await previousFailureTask?.value
            await coordinator?.tearDown()
            guard let self,
                  self.runtimeSession.isCurrent(generation),
                  case .terminalFailure = self.runtimeSession.state else {
                return
            }
            LogError(
                "ExperienceViewController: terminal runtime failure on screen \(screenId): \(error)"
            )
            self.viewModel.handleLoadingFailed(error)
        }
        runtimeSession.ownFailureTask(task, generation: generation)
    }
    #endif

    #if !canImport(UIKit)
    private func beginNativeRuntimeLoad() {}
    private func invalidateNativeRuntimeLoad() {}
    #endif

    #if canImport(UIKit)
    private func handleNativeRuntimeReady(
        generation: UInt64,
        coordinator: ExperienceScreenTransitionCoordinator
    ) async {
        guard screenTransitionCoordinator === coordinator,
              runtimeCallbackCoordinator === coordinator else {
            return
        }
        guard runtimeSession.becomeReady(generation: generation) else { return }
        guard await runtimeDelegate?.experienceViewControllerWillActivateInitialScreen(self)
            ?? true else {
            return
        }
        // The authored surface must be drawable while the native loading shell
        // remains visually above it. Revealing still waits for both a complete
        // presented drawable and the post-activation input-ready boundary.
        setExperienceContentHidden(false)
        platformBringPresentationShellToFront()
        await coordinator.activateInitialScreen()
        guard runtimeSession.isReady(generation),
              screenTransitionCoordinator === coordinator else {
            return
        }
        drainPendingNativeRuntimeCommands(
            generation: generation,
            coordinator: coordinator
        )
        notifyRuntimeReadyIfDrained(
            generation: generation,
            coordinator: coordinator
        )
        if revealGate.markInputReady() {
            viewModel.handleLoadingFinished()
        }
    }
    #endif

    private func setExperienceContentHidden(_ hidden: Bool) {
        experienceContentIsHidden = hidden
        #if canImport(UIKit)
        screenTransitionCoordinator?.setContentHidden(hidden)
        #endif
    }

    // MARK: - UI State Management

    private func updateUIState(_ state: ExperienceViewModel.State) {
        switch state {
        case .loading:
            platformCancelPresentationRevealTransition()
            contentIsRevealed = false
            setExperienceContentHidden(true)
            loadingView.isHidden = suppressesLoadingTreatmentForPresentation
            errorView.isHidden = true
            platformStartLoadingIndicator()
            platformBringPresentationShellToFront()
            scheduleRecoveryAffordancesIfNeeded()

        case .loaded:
            releasePresentationWarmReservation()
            cancelRecoveryAffordances()
            setExperienceContentHidden(false)
            platformStopLoadingIndicator()
            platformRevealPresentationContent()
            contentIsRevealed = true
            notifyPresentationRevealIfVisible()

        case .timedOut:
            releasePresentationWarmReservation()
            platformCancelPresentationRevealTransition()
            contentIsRevealed = false
            setExperienceContentHidden(false)
            platformStopLoadingIndicator()
            if errorView.isHidden {
                loadingView.isHidden = false
                scheduleRecoveryAffordancesIfNeeded()
            } else {
                loadingView.isHidden = true
            }
            platformBringPresentationShellToFront()

        case .error:
            releasePresentationWarmReservation()
            platformCancelPresentationRevealTransition()
            contentIsRevealed = false
            setExperienceContentHidden(true)
            platformStopLoadingIndicator()
            if errorView.isHidden {
                loadingView.isHidden = false
                scheduleRecoveryAffordancesIfNeeded()
            } else {
                loadingView.isHidden = true
            }
            platformBringPresentationShellToFront()
        }
    }

    private func notifyPresentationRevealIfVisible() {
        guard presentationShellIsPresented,
              contentIsRevealed,
              !didNotifyPresentationReveal else {
            return
        }
        didNotifyPresentationReveal = true
        if let scopedDelegate = runtimeDelegate as? any ExperiencePresentationScopedTraceDelegate {
            scopedDelegate.experienceViewControllerDidReveal(
                self,
                traceToken: runtimePresentationTraceToken
            )
        } else {
            runtimeDelegate?.experienceViewControllerDidReveal(self)
        }
    }

    func retryFromErrorView() {
        cancelRecoveryAffordances()
        updateUIState(.loading)
        viewModel.retry()
    }

    private func scheduleRecoveryAffordancesIfNeeded() {
        let isEmbeddedController = presentationShellContract == nil
        guard isEmbeddedController || presentationShellIsPresented,
              !contentIsRevealed,
              isViewLoaded,
              recoveryAffordanceTask == nil else { return }
        let delay = max(0, recoveryAffordanceDelay)
        recoveryAffordanceTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
            guard let self,
                  !Task.isCancelled,
                  !self.contentIsRevealed,
                  self.isViewLoaded else {
                return
            }
            self.platformStopLoadingIndicator()
            self.loadingView.isHidden = true
            self.errorView.isHidden = false
            self.platformBringPresentationShellToFront()
            self.recoveryAffordanceTask = nil
        }
    }

    private func cancelRecoveryAffordances() {
        recoveryAffordanceTask?.cancel()
        recoveryAffordanceTask = nil
    }

    private func releasePresentationWarmReservation() {
        presentationWarmReservation?.release()
        presentationWarmReservation = nil
    }
}

private extension ExperienceViewController {
    func invokeOnCloseOnce(_ reason: CloseReason, generation: UInt64) {
        guard closeGeneration == generation, !didInvokeClose else { return }
        didInvokeClose = true
        onClose?(reason)
    }

    func journeyScopedEventProperties(
        journeyId: String?,
        extraProperties: [String: Any] = [:]
    ) -> [String: Any] {
        var properties = extraProperties
        if let journeyId, !journeyId.isEmpty {
            properties["journey_id"] = journeyId
        }
        return properties
    }

    func permissionEventProperties(
        journeyId: String?,
        permissionType: String
    ) -> [String: Any] {
        journeyScopedEventProperties(
            journeyId: journeyId,
            extraProperties: ["type": permissionType]
        )
    }

    func handleUnsupportedRequestPermission(
        permissionType: String,
        journeyId: String?
    ) {
        guard let journeyId, !journeyId.isEmpty,
              let receiver = requestPermissionEventReceiver
        else {
            return
        }

        receiver.experienceViewController(
            self,
            didIgnoreUnsupportedRequestPermissionType: permissionType,
            journeyId: journeyId
        )
    }

    func dispatchNotificationPermissionEvent(
        _ eventName: String,
        properties: sending [String: Any],
        journeyId: String?
    ) {
        if let journeyId, !journeyId.isEmpty,
           let receiver = notificationPermissionEventReceiver {
            receiver.experienceViewController(
                self,
                didResolveNotificationPermissionEvent: eventName,
                properties: properties,
                journeyId: journeyId
            )
            return
        }

        emitSystemEvent(eventName, properties: properties)
    }

    func dispatchTrackingPermissionEvent(
        _ eventName: String,
        properties: sending [String: Any],
        journeyId: String?
    ) {
        if let journeyId, !journeyId.isEmpty,
           let receiver = trackingPermissionEventReceiver {
            receiver.experienceViewController(
                self,
                didResolveTrackingPermissionEvent: eventName,
                properties: properties,
                journeyId: journeyId
            )
            return
        }

        emitSystemEvent(eventName, properties: properties)
    }

    func dispatchRequestPermissionEvent(
        _ eventName: String,
        properties: sending [String: Any],
        journeyId: String?
    ) {
        if let journeyId, !journeyId.isEmpty,
           let receiver = requestPermissionEventReceiver {
            receiver.experienceViewController(
                self,
                didResolveRequestPermissionEvent: eventName,
                properties: properties,
                journeyId: journeyId
            )
            return
        }

        emitSystemEvent(eventName, properties: properties)
    }

    func applyColorSchemeMode() {
        platformApplyColorSchemeMode(colorSchemeMode)
        platformApplyPresentationShell(presentationShellContract)
    }

    private func enqueueNativeRuntimeCommand(_ command: NativeRuntimeCommand) {
        #if canImport(UIKit)
        runtimeSession.enqueue(command)
        let generation = runtimeSession.generation
        guard runtimeSession.isReady(generation),
              let coordinator = screenTransitionCoordinator else {
            return
        }
        drainPendingNativeRuntimeCommands(
            generation: generation,
            coordinator: coordinator
        )
        #else
        pendingNativeRuntimeCommands.append(command)
        #endif
    }

    #if canImport(UIKit)
    private func drainPendingNativeRuntimeCommands(
        generation: UInt64,
        coordinator: ExperienceScreenTransitionCoordinator
    ) {
        guard runtimeSession.beginCommandDrain(generation: generation) else { return }
        defer { runtimeSession.endCommandDrain() }

        while screenTransitionCoordinator === coordinator,
              let command = runtimeSession.nextCommand(generation: generation) {
            if case .navigate = command {
                let isWaiting = startNativeRuntimeNavigation(
                    command,
                    generation: generation,
                    coordinator: coordinator
                )
                if isWaiting { return }
                continue
            }
            performNativeRuntimeCommand(command)
        }
    }
    #endif

    private func performNativeRuntimeCommand(_ command: NativeRuntimeCommand) {
        #if canImport(UIKit)
        switch command {
        case .viewModelSnapshot(let snapshot, let screenId):
            _ = screenTransitionCoordinator?.applySnapshot(snapshot, screenId: screenId)
        case .viewModelValue(let path, let value, let screenId, let instanceId):
            _ = screenTransitionCoordinator?.applyValue(
                path: path,
                value: value,
                screenId: screenId,
                instanceId: instanceId
            )
        case .viewModelList(let operation, let path, let payload, let screenId, let instanceId):
            _ = screenTransitionCoordinator?.applyListOperation(
                operation,
                path: path,
                payload: payload,
                screenId: screenId,
                instanceId: instanceId
            )
        case .viewModelTrigger(let path, let screenId, let instanceId):
            _ = screenTransitionCoordinator?.fireTrigger(
                path: path,
                screenId: screenId,
                instanceId: instanceId
            )
        case .navigate:
            // Navigation is admitted only by the serialized command drain so
            // later screen-targeted commands wait for lazy mount + activation.
            break
        }
        #endif
    }

    #if canImport(UIKit)
    private func startNativeRuntimeNavigation(
        _ command: NativeRuntimeCommand,
        generation: UInt64,
        coordinator: ExperienceScreenTransitionCoordinator
    ) -> Bool {
        guard case let .navigate(screenId, transition) = command else {
            return false
        }
        let navigation = ActiveNativeRuntimeNavigation(
            id: UUID(),
            command: command,
            generation: generation,
            coordinatorID: ObjectIdentifier(coordinator)
        )
        guard runtimeSession.beginNavigation(navigation, generation: generation) else {
            return true
        }
        let accepted = coordinator.navigate(
            to: screenId,
            transition: transition
        ) { [weak self] didNavigate, completedScreenId in
            self?.completeNativeRuntimeNavigation(
                navigation,
                didNavigate: didNavigate,
                completedScreenId: completedScreenId
            )
        }
        guard accepted else {
            _ = runtimeSession.clearNavigation { $0.id == navigation.id }
            return false
        }
        return runtimeSession.activeNavigation?.id == navigation.id
    }

    private func completeNativeRuntimeNavigation(
        _ navigation: ActiveNativeRuntimeNavigation,
        didNavigate: Bool,
        completedScreenId: String
    ) {
        guard runtimeSession.clearNavigation(where: { $0.id == navigation.id }) else { return }

        guard runtimeSession.isReady(navigation.generation),
              let coordinator = screenTransitionCoordinator,
              ObjectIdentifier(coordinator) == navigation.coordinatorID else {
            return
        }
        drainPendingNativeRuntimeCommands(
            generation: navigation.generation,
            coordinator: coordinator
        )
        notifyRuntimeReadyIfDrained(
            generation: navigation.generation,
            coordinator: coordinator
        )
    }

    private func notifyRuntimeReadyIfDrained(
        generation: UInt64,
        coordinator: ExperienceScreenTransitionCoordinator
    ) {
        guard screenTransitionCoordinator === coordinator,
              runtimeCallbackCoordinator === coordinator,
              runtimeSession.consumeReadyNotification(generation: generation) else {
            return
        }
        if let scopedDelegate = runtimeDelegate as? any ExperiencePresentationScopedTraceDelegate {
            scopedDelegate.experienceViewControllerDidBecomeReady(
                self,
                traceToken: runtimePresentationTraceToken
            )
        } else {
            runtimeDelegate?.experienceViewControllerDidBecomeReady(self)
        }
    }

    private func handleNativePresentedScreenDismissed(
        dismissedScreenId: String,
        revealingScreenId: String?,
        generation: UInt64
    ) async {
        guard runtimeSession.isReady(generation) else {
            return
        }
        await runtimeDelegate?.experienceViewController(
            self,
            didDismissScreen: dismissedScreenId,
            revealingScreenId: revealingScreenId,
            method: "native_sheet"
        )
    }

    private func handleNativeScreenHidden(
        screenId: String,
        context: ExperienceScreenHiddenContext,
        generation: UInt64
    ) async {
        guard runtimeSession.isReady(generation) else {
            return
        }
        await runtimeDelegate?.experienceViewController(
            self,
            didDismissScreen: screenId,
            revealingScreenId: context.revealingScreenId,
            method: context.method
        )
    }

    private func handleNativeScreenActive(
        screenId: String,
        generation: UInt64
    ) async {
        guard runtimeSession.isReady(generation) else {
            return
        }
        await runtimeDelegate?.experienceViewController(
            self,
            didChangeScreen: screenId
        )
    }

    private func acceptsRuntimeCallback(
        from controller: ExperienceScreenViewController
    ) -> Bool {
        guard runtimeSession.acceptsCallbacks(),
              let runtimeCallbackCoordinator else {
            return false
        }
        return runtimeCallbackCoordinator.owns(controller)
    }
    #endif

}

#if canImport(UIKit)
extension ExperienceViewController: ExperienceScreenViewControllerDelegate {
    func experienceScreenViewControllerDidAdvance(_ controller: ExperienceScreenViewController) {
        guard acceptsRuntimeCallback(from: controller) else { return }
        screenTransitionCoordinator?.layoutTextInputs()
    }

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didEmitEvent event: ExperienceRendererEvent
    ) {
        guard acceptsRuntimeCallback(from: controller) else { return }
        runtimeDelegate?.experienceViewController(self, didEmitEvent: event)
    }

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didEmitViewModelChange change: ExperienceRendererViewModelChange
    ) {
        guard acceptsRuntimeCallback(from: controller) else { return }
        runtimeDelegate?.experienceViewController(self, didEmitViewModelChange: change)
    }

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didRequestOpenLink request: ExperienceRendererOpenLinkRequest
    ) {
        guard acceptsRuntimeCallback(from: controller) else { return }
        runtimeDelegate?.experienceViewController(self, didRequestOpenLink: request)
    }

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didRequestNavigationTo screenID: String,
        transition: Any?
    ) {
        guard acceptsRuntimeCallback(from: controller) else { return }
        navigate(to: screenID, transition: transition)
    }

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didPresentDrawable drawable: ExperienceRuntimePresentedDrawable,
        frameNumber: UInt64
    ) {
        guard acceptsRuntimeCallback(from: controller), drawable.isComplete else {
            return
        }
        completePendingDisplayPresentationTrace(
            drawable: drawable,
            screenId: controller.screenId,
            frameNumber: frameNumber
        )
        if let scopedDelegate = runtimeDelegate as? any ExperiencePresentationScopedTraceDelegate {
            scopedDelegate.experienceViewController(
                self,
                didPresentDrawable: drawable,
                screenId: controller.screenId,
                frameNumber: frameNumber,
                traceToken: runtimePresentationTraceToken
            )
        } else {
            runtimeDelegate?.experienceViewController(
                self,
                didPresentDrawable: drawable,
                screenId: controller.screenId,
                frameNumber: frameNumber
            )
        }
        if revealGate.markPresentedDrawable(drawable) {
            viewModel.handleLoadingFinished()
        }
    }

    func experienceScreenViewController(
        _ controller: ExperienceScreenViewController,
        didAcceptPointerInput input: ExperienceRuntimeAcceptedPointerInput
    ) {
        guard acceptsRuntimeCallback(from: controller) else { return }
        if let scopedDelegate = runtimeDelegate as? any ExperiencePresentationScopedTraceDelegate {
            scopedDelegate.experienceViewController(
                self,
                didAcceptPointerInput: input,
                screenId: controller.screenId,
                traceToken: runtimePresentationTraceToken
            )
        } else {
            runtimeDelegate?.experienceViewController(
                self,
                didAcceptPointerInput: input,
                screenId: controller.screenId
            )
        }
    }
}
#endif

// MARK: - Native Host Action Helpers

extension ExperienceViewController {
    fileprivate func handleNativePurchase(productId: String, offerId: String? = nil) {
        LogDebug("ExperienceViewController: Native purchase for product: \(productId)")
        let transactionService = self.transactionService
        let productService = self.productService

        Task { @MainActor in
            do {
                let products = try await productService.fetchProducts(for: [productId])
                guard let product = products.first else {
                    self.emitSystemEvent(
                        SystemEventNames.purchaseFailed,
                        properties: [
                            "product_id": productId,
                            "error": "Product not found"
                        ]
                    )
                    return
                }
                let syncResult = try await transactionService.purchase(
                    product,
                    offerId: offerId
                )
                if let syncTask = syncResult.syncTask {
                    _ = await syncTask.value
                }
            } catch StoreKitError.purchaseCancelled {
                self.emitSystemEvent(
                    SystemEventNames.purchaseCancelled,
                    properties: ["product_id": productId]
                )
            } catch StoreKitError.purchasePending {
                // Ask-to-Buy / SCA: surface a pending status so the paywall
                // doesn't spin forever; the outcome arrives later via
                // Transaction.updates.
                LogInfo("ExperienceViewController: purchase pending for product \(productId)")
                self.emitSystemEvent(
                    SystemEventNames.purchasePending,
                    properties: ["product_id": productId]
                )
            } catch StoreKitError.purchaseFailed(_) {
                // TransactionService already triggered $purchase_failed for this
                // outcome before throwing; emitting here would double-count.
                // The generic catch below covers errors TransactionService never
                // saw (e.g. product fetch failures).
                LogWarning("ExperienceViewController: purchase failed for product \(productId)")
            } catch {
                self.emitSystemEvent(
                    SystemEventNames.purchaseFailed,
                    properties: [
                        "product_id": productId,
                        "error": error.localizedDescription
                    ]
                )
            }
        }
    }

    fileprivate func handleNativeRestore() {
        LogDebug("ExperienceViewController: Native restore purchases")
        let transactionService = self.transactionService
        Task { @MainActor in
            do {
                try await transactionService.restore()
            } catch StoreKitError.restoreFailed(_) {
                LogWarning("ExperienceViewController: restore purchases failed")
            } catch {
                self.emitSystemEvent(
                    SystemEventNames.restoreFailed,
                    properties: ["error": error.localizedDescription]
                )
            }
        }
    }
}

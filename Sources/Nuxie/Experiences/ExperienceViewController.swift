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
    func experienceViewControllerDidBecomeReady(_ controller: ExperienceViewController)

    func experienceViewController(
        _ controller: ExperienceViewController,
        didChangeScreen screenId: String
    )

    func experienceViewController(
        _ controller: ExperienceViewController,
        didDismissScreen screenId: String,
        revealingScreenId: String?
    )

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
    func experienceViewControllerDidBecomeReady(_ controller: ExperienceViewController) {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didChangeScreen screenId: String
    ) {}

    func experienceViewController(
        _ controller: ExperienceViewController,
        didDismissScreen screenId: String,
        revealingScreenId: String?
    ) {}

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
    private var loadedPackage: LoadedExperiencePackage?
    private var runtimeMountTask: Task<Void, Never>?
    private var runtimeFailureTask: Task<Void, Never>?
    private var runtimeMountGeneration: UInt64 = 0
    private var reportedRuntimeFailureGeneration: UInt64?
    private var isDrainingNativeRuntimeCommands = false
    private var activeNativeRuntimeNavigation: ActiveNativeRuntimeNavigation?
    private var pendingRuntimeReadyNotificationGeneration: UInt64?
    var runtimePayloadProvider: @MainActor (AcquiredExperiencePackage) async throws
        -> AuthenticatedRuntimePayload = { artifact in
        try await SwiftExperiencePackageAuthenticator().authenticate(artifact)
    }
    #endif
    #if canImport(UIKit)
    var loadingView: UIView!
    var errorView: UIView!
    var activityIndicator: UIActivityIndicatorView!
    var refreshButton: UIButton!
    var closeButton: UIButton!
    #elseif canImport(AppKit)
    var loadingView: NSView!
    var errorView: NSView!
    var activityIndicator: NSProgressIndicator!
    var refreshButton: NSButton!
    var closeButton: NSButton!
    #endif

    private var runtimeReady = false
    private var pendingNativeRuntimeCommands: [NativeRuntimeCommand] = []
    private var didInvokeClose = false
    private var closeGeneration: UInt64 = 0
    private var runtimePreparationGeneration: UInt64 = 0
    private var runtimeShutdownTask: Task<Void, Never>?
    private var runtimeShutdownID: UUID?

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
        packageStore: ExperiencePackageStore,
        artifactTelemetryContext: ExperienceArtifactTelemetryContext? = nil,
        eventLog: EventCapturing,
        loadingTimeoutSeconds: TimeInterval = 15.0,
        transactionService: TransactionService,
        productService: ProductService,
        systemEventSink: SystemEventSink
    ) {
        self.transactionService = transactionService
        self.productService = productService
        self.systemEventSink = systemEventSink
        self.viewModel = ExperienceViewModel(
            experience: experience,
            packageStore: packageStore,
            artifactTelemetryContext: artifactTelemetryContext,
            loadingTimeoutSeconds: loadingTimeoutSeconds,
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

    /// Resets presentation-scoped state and starts fresh interactive screens for
    /// cached controllers. A newly created controller begins artifact loading
    /// when its view is first loaded; a reused controller reacquires its
    /// artifact and never shares the previous presentation's runtime state.
    func prepareForPresentation() async {
        closeGeneration &+= 1
        didInvokeClose = false
        runtimePreparationGeneration &+= 1
        let preparationGeneration = runtimePreparationGeneration
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

    /// Deterministically releases every presentation-owned interactive screen.
    /// A later presentation reloads the cached artifact through ExperienceViewModel
    /// and opens an entirely new native ownership graph.
    func shutdownRuntime() async {
        // Explicit shutdown revokes any preparation currently waiting for the
        // same teardown, so it cannot restart acquisition after cleanup wins.
        runtimePreparationGeneration &+= 1
        await joinRuntimeShutdown()
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
        runtimeReady = false
        pendingNativeRuntimeCommands.removeAll()
        // This method performs the native invalidation itself. Suppress the
        // ViewModel callback to avoid constructing a second teardown task.
        viewModel.cancelLoading(notifyInvalidation: false)

        #if canImport(UIKit)
        runtimeMountGeneration &+= 1
        reportedRuntimeFailureGeneration = nil

        let mountTask = runtimeMountTask
        let failureTask = runtimeFailureTask
        runtimeMountTask = nil
        runtimeFailureTask = nil
        mountTask?.cancel()
        activeNativeRuntimeNavigation = nil
        isDrainingNativeRuntimeCommands = false
        pendingRuntimeReadyNotificationGeneration = nil

        let coordinator = screenTransitionCoordinator
        screenTransitionCoordinator = nil
        runtimeCallbackCoordinator = nil
        loadedPackage = nil
        await coordinator?.tearDown()
        await mountTask?.value
        await failureTask?.value
        #endif
    }

    func performPurchase(productId: String, placementIndex: Any? = nil) {
        handleNativePurchase(productId: productId)
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
        runtimeDelegate?.experienceViewControllerDidRequestDismiss(self, reason: reason)
        let generation = closeGeneration

        #if canImport(UIKit)
        dismiss(animated: true) { [weak self] in
            self?.invokeOnCloseOnce(reason, generation: generation)
        }
        #elseif canImport(AppKit)
        view.window?.orderOut(nil)
        invokeOnCloseOnce(reason, generation: generation)
        #endif

        // Fallback: ensure onClose is invoked even if platform dismissal
        // completion never fires (window-root VCs have no presenting VC).
        // 2s is beyond any dismissal animation; invokeOnCloseOnce dedupes and
        // the presentation service ignores closes from non-current VCs, so a
        // late fire can no longer tear down a newer experience's window.
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self.invokeOnCloseOnce(reason, generation: generation)
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
            self?.mountPackage(artifact)
        }
    }

    private func setupViews() {
        platformApplyDefaultBackgroundColor()
        #if canImport(UIKit)
        view.clipsToBounds = true
        #endif

        platformSetupLoadingView()
        platformSetupErrorView()

        // Start in loading state
        updateUIState(.loading)
    }

    private func mountPackage(_ acquisition: AcquiredExperiencePackage) {
        #if canImport(UIKit)
        let generation = runtimeMountGeneration

        let previousMountTask = runtimeMountTask
        runtimeMountTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await previousMountTask?.value
            guard !Task.isCancelled,
                  self.runtimeMountGeneration == generation else {
                return
            }

            let previousCoordinator = self.screenTransitionCoordinator
            self.screenTransitionCoordinator = nil
            await previousCoordinator?.tearDown()
            guard !Task.isCancelled,
                  self.runtimeMountGeneration == generation else {
                return
            }

            var candidate: ExperienceScreenTransitionCoordinator?
            do {
                let payload = try await self.runtimePayloadProvider(acquisition)
                try Task.checkCancellation()
                guard self.runtimeMountGeneration == generation else {
                    throw CancellationError()
                }
                let artifact = LoadedExperiencePackage(
                    acquired: acquisition,
                    payload: payload
                )
                self.loadedPackage = artifact

                let coordinator = ExperienceScreenTransitionCoordinator(
                    experience: self.experience,
                    artifact: artifact,
                    hostViewController: self,
                    screenDelegate: self,
                    onPresentedScreenDismissed: { [weak self] dismissedScreenId, revealingScreenId in
                        self?.handleNativePresentedScreenDismissed(
                            dismissedScreenId: dismissedScreenId,
                            revealingScreenId: revealingScreenId,
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
                try await coordinator.install()
                try Task.checkCancellation()
                guard self.runtimeMountGeneration == generation else {
                    throw CancellationError()
                }
                guard self.reportedRuntimeFailureGeneration != generation else {
                    throw CancellationError()
                }

                coordinator.setContentHidden(true)
                self.screenTransitionCoordinator = coordinator
                candidate = nil
                self.handleNativeRuntimeReady(
                    generation: generation,
                    coordinator: coordinator
                )
                LogDebug("Mounted native experience artifact for experience \(self.experience.id)")
            } catch is CancellationError {
                await candidate?.tearDown()
                if let candidate,
                   self.runtimeCallbackCoordinator === candidate {
                    self.runtimeCallbackCoordinator = nil
                }
            } catch {
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

            if self.runtimeMountGeneration == generation {
                self.runtimeMountTask = nil
            }
        }
        #else
        viewModel.handleLoadingFailed(
            ExperienceError.configurationFailed(
                ExperiencePackageStoreError.invalidPointer("Nuxie runtime unavailable")
            )
        )
        #endif
    }

    #if canImport(UIKit)
    private func beginNativeRuntimeLoad() {
        runtimeReady = false
        runtimeMountGeneration &+= 1
        reportedRuntimeFailureGeneration = nil
        if let activeNativeRuntimeNavigation {
            pendingNativeRuntimeCommands.insert(
                activeNativeRuntimeNavigation.command,
                at: 0
            )
        }
        activeNativeRuntimeNavigation = nil
        isDrainingNativeRuntimeCommands = false
        pendingRuntimeReadyNotificationGeneration = nil

        let previousTask = runtimeMountTask
        previousTask?.cancel()
        let previousCoordinator = screenTransitionCoordinator
        screenTransitionCoordinator = nil
        runtimeCallbackCoordinator = nil

        runtimeMountTask = Task { @MainActor in
            await previousTask?.value
            await previousCoordinator?.tearDown()
        }
    }

    private func invalidateNativeRuntimeLoad() {
        runtimeReady = false
        runtimeMountGeneration &+= 1
        reportedRuntimeFailureGeneration = nil
        activeNativeRuntimeNavigation = nil
        isDrainingNativeRuntimeCommands = false
        pendingRuntimeReadyNotificationGeneration = nil

        let previousTask = runtimeMountTask
        previousTask?.cancel()
        let previousCoordinator = screenTransitionCoordinator
        screenTransitionCoordinator = nil
        runtimeCallbackCoordinator = nil

        runtimeMountTask = Task { @MainActor in
            await previousTask?.value
            await previousCoordinator?.tearDown()
        }
    }

    private func latchNativeRuntimeFailure(
        _ error: Error,
        screenId: String,
        generation: UInt64
    ) {
        guard runtimeMountGeneration == generation,
              reportedRuntimeFailureGeneration != generation else {
            return
        }
        reportedRuntimeFailureGeneration = generation
        runtimeReady = false
        activeNativeRuntimeNavigation = nil
        isDrainingNativeRuntimeCommands = false
        pendingRuntimeReadyNotificationGeneration = nil

        let coordinator = screenTransitionCoordinator
        screenTransitionCoordinator = nil
        runtimeCallbackCoordinator = nil
        let previousFailureTask = runtimeFailureTask
        runtimeFailureTask = Task<Void, Never> { @MainActor [weak self] in
            await previousFailureTask?.value
            await coordinator?.tearDown()
            guard let self,
                  self.runtimeMountGeneration == generation,
                  self.reportedRuntimeFailureGeneration == generation else {
                return
            }
            LogError(
                "ExperienceViewController: terminal runtime failure on screen \(screenId): \(error)"
            )
            self.viewModel.handleLoadingFailed(error)
        }
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
    ) {
        guard runtimeMountGeneration == generation,
              reportedRuntimeFailureGeneration != generation,
              screenTransitionCoordinator === coordinator,
              runtimeCallbackCoordinator === coordinator else {
            return
        }
        runtimeReady = true
        viewModel.handleLoadingFinished()
        pendingRuntimeReadyNotificationGeneration = generation
        drainPendingNativeRuntimeCommands(
            generation: generation,
            coordinator: coordinator
        )
        notifyRuntimeReadyIfDrained(
            generation: generation,
            coordinator: coordinator
        )
    }
    #endif

    private func setExperienceContentHidden(_ hidden: Bool) {
        #if canImport(UIKit)
        screenTransitionCoordinator?.setContentHidden(hidden)
        #endif
    }

    // MARK: - UI State Management

    private func updateUIState(_ state: ExperienceViewModel.State) {
        switch state {
        case .loading:
            setExperienceContentHidden(true)
            loadingView.isHidden = false
            errorView.isHidden = true
            platformStartLoadingIndicator()

        case .loaded:
            setExperienceContentHidden(false)
            loadingView.isHidden = true
            errorView.isHidden = true
            platformStopLoadingIndicator()

        case .error:
            setExperienceContentHidden(true)
            loadingView.isHidden = true
            errorView.isHidden = false
            platformStopLoadingIndicator()
        }
    }

    func retryFromErrorView() {
        viewModel.retry()
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
    }

    private func enqueueNativeRuntimeCommand(_ command: NativeRuntimeCommand) {
        pendingNativeRuntimeCommands.append(command)
        #if canImport(UIKit)
        guard runtimeReady,
              let coordinator = screenTransitionCoordinator else {
            return
        }
        drainPendingNativeRuntimeCommands(
            generation: runtimeMountGeneration,
            coordinator: coordinator
        )
        #endif
    }

    #if canImport(UIKit)
    private func drainPendingNativeRuntimeCommands(
        generation: UInt64,
        coordinator: ExperienceScreenTransitionCoordinator
    ) {
        guard !isDrainingNativeRuntimeCommands,
              activeNativeRuntimeNavigation == nil else {
            return
        }
        isDrainingNativeRuntimeCommands = true
        defer { isDrainingNativeRuntimeCommands = false }

        while runtimeReady,
              runtimeMountGeneration == generation,
              reportedRuntimeFailureGeneration != generation,
              screenTransitionCoordinator === coordinator,
              !pendingNativeRuntimeCommands.isEmpty {
            let command = pendingNativeRuntimeCommands.removeFirst()
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
        activeNativeRuntimeNavigation = navigation
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
            if activeNativeRuntimeNavigation?.id == navigation.id {
                activeNativeRuntimeNavigation = nil
            }
            return false
        }
        return activeNativeRuntimeNavigation?.id == navigation.id
    }

    private func completeNativeRuntimeNavigation(
        _ navigation: ActiveNativeRuntimeNavigation,
        didNavigate: Bool,
        completedScreenId: String
    ) {
        guard activeNativeRuntimeNavigation?.id == navigation.id else { return }
        activeNativeRuntimeNavigation = nil

        guard runtimeReady,
              runtimeMountGeneration == navigation.generation,
              reportedRuntimeFailureGeneration != navigation.generation,
              let coordinator = screenTransitionCoordinator,
              ObjectIdentifier(coordinator) == navigation.coordinatorID else {
            return
        }
        if didNavigate {
            runtimeDelegate?.experienceViewController(
                self,
                didChangeScreen: completedScreenId
            )
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
        guard pendingRuntimeReadyNotificationGeneration == generation,
              runtimeReady,
              runtimeMountGeneration == generation,
              reportedRuntimeFailureGeneration != generation,
              screenTransitionCoordinator === coordinator,
              runtimeCallbackCoordinator === coordinator,
              activeNativeRuntimeNavigation == nil,
              pendingNativeRuntimeCommands.isEmpty,
              !isDrainingNativeRuntimeCommands else {
            return
        }
        pendingRuntimeReadyNotificationGeneration = nil
        runtimeDelegate?.experienceViewControllerDidBecomeReady(self)
    }

    private func handleNativePresentedScreenDismissed(
        dismissedScreenId: String,
        revealingScreenId: String?,
        generation: UInt64
    ) {
        guard runtimeReady,
              runtimeMountGeneration == generation else {
            return
        }
        runtimeDelegate?.experienceViewController(
            self,
            didDismissScreen: dismissedScreenId,
            revealingScreenId: revealingScreenId
        )
    }

    private func acceptsRuntimeCallback(
        from controller: ExperienceScreenViewController
    ) -> Bool {
        guard reportedRuntimeFailureGeneration != runtimeMountGeneration,
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
}
#endif

// MARK: - Native Host Action Helpers

extension ExperienceViewController {
    fileprivate func handleNativePurchase(productId: String) {
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
                let syncResult = try await transactionService.purchase(product)
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

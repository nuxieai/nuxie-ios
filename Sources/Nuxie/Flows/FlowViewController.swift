import Foundation
import FactoryKit
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

protocol NotificationAuthorizationHandling {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
}

enum TrackingAuthorizationStatus {
    case authorized
    case denied
    case restricted
    case notDetermined
    case unsupported
}

protocol TrackingAuthorizationHandling {
    func authorizationStatus() -> TrackingAuthorizationStatus
    func requestAuthorization() async -> TrackingAuthorizationStatus
}

enum PermissionAuthorizationStatus {
    case granted
    case denied
    case restricted
    case limited
    case notDetermined
    case unsupported
}

protocol PermissionAuthorizationHandling {
    func authorizationStatus() -> PermissionAuthorizationStatus
    func requestAuthorization() async -> PermissionAuthorizationStatus
}

struct UserNotificationAuthorizationHandler: NotificationAuthorizationHandling {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: options)
    }
}

struct CameraPermissionAuthorizationHandler: PermissionAuthorizationHandling {
    func authorizationStatus() -> PermissionAuthorizationStatus {
        #if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unsupported
        }
        #else
        return .unsupported
        #endif
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        #if canImport(AVFoundation)
        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .granted : .denied
        #else
        return .unsupported
        #endif
    }
}

struct MicrophonePermissionAuthorizationHandler: PermissionAuthorizationHandling {
    func authorizationStatus() -> PermissionAuthorizationStatus {
        #if canImport(AVFoundation) && !os(macOS)
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            return .granted
        case .denied:
            return .denied
        case .undetermined:
            return .notDetermined
        @unknown default:
            return .unsupported
        }
        #else
        return .unsupported
        #endif
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        #if canImport(AVFoundation) && !os(macOS)
        let granted = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted ? .granted : .denied
        #else
        return .unsupported
        #endif
    }
}

struct PhotoLibraryPermissionAuthorizationHandler: PermissionAuthorizationHandling {
    func authorizationStatus() -> PermissionAuthorizationStatus {
        #if canImport(Photos)
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:
            return .granted
        case .limited:
            return .limited
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unsupported
        }
        #else
        return .unsupported
        #endif
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        #if canImport(Photos)
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        switch status {
        case .authorized:
            return .granted
        case .limited:
            return .limited
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unsupported
        }
        #else
        return .unsupported
        #endif
    }
}

final class LocationPermissionAuthorizationHandler: NSObject, PermissionAuthorizationHandling {
    #if canImport(CoreLocation) && !os(macOS)
    private var manager: CLLocationManager?
    private var continuations: [CheckedContinuation<PermissionAuthorizationStatus, Never>] = []

    private static func map(_ status: CLAuthorizationStatus) -> PermissionAuthorizationStatus {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .unsupported
        }
    }

    private func resolveContinuationIfNeeded(_ status: CLAuthorizationStatus) {
        let resolvedStatus = Self.map(status)
        guard resolvedStatus != .notDetermined,
              !continuations.isEmpty
        else { return }

        let pendingContinuations = continuations
        continuations.removeAll()
        pendingContinuations.forEach { continuation in
            continuation.resume(returning: resolvedStatus)
        }
    }
    #endif

    func authorizationStatus() -> PermissionAuthorizationStatus {
        #if canImport(CoreLocation) && !os(macOS)
        return Self.map(CLLocationManager.authorizationStatus())
        #else
        return .unsupported
        #endif
    }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        #if canImport(CoreLocation) && !os(macOS)
        let currentStatus = authorizationStatus()
        guard currentStatus == .notDetermined else {
            return currentStatus
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.continuations.append(continuation)
                let shouldRequestAuthorization = self.continuations.count == 1

                let manager: CLLocationManager
                if let existingManager = self.manager {
                    manager = existingManager
                } else {
                    let createdManager = CLLocationManager()
                    self.manager = createdManager
                    manager = createdManager
                }

                manager.delegate = self

                if shouldRequestAuthorization {
                    manager.requestWhenInUseAuthorization()
                }
            }
        }
        #else
        return .unsupported
        #endif
    }
}

#if canImport(CoreLocation) && !os(macOS)
extension LocationPermissionAuthorizationHandler: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        resolveContinuationIfNeeded(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        resolveContinuationIfNeeded(status)
    }
}
#endif

struct AppTrackingAuthorizationHandler: TrackingAuthorizationHandling {
    func authorizationStatus() -> TrackingAuthorizationStatus {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            return TrackingAuthorizationStatus(ATTrackingManager.trackingAuthorizationStatus)
        }
        #endif
        return .unsupported
    }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        #if canImport(AppTrackingTransparency)
        if #available(iOS 14, *) {
            return await withCheckedContinuation { continuation in
                ATTrackingManager.requestTrackingAuthorization { status in
                    continuation.resume(returning: TrackingAuthorizationStatus(status))
                }
            }
        }
        #endif
        return .unsupported
    }
}

#if canImport(AppTrackingTransparency)
@available(iOS 14, *)
private extension TrackingAuthorizationStatus {
    init(_ status: ATTrackingManager.AuthorizationStatus) {
        switch status {
        case .authorized:
            self = .authorized
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .restricted
        }
    }
}
#endif

struct FlowRendererEvent {
    let name: String
    let properties: [String: Any]
    let screenId: String?
    let componentId: String?
    let instanceId: String?
}

struct FlowRendererViewModelChange {
    let path: VmPathRef
    let value: Any
    let source: String?
    let screenId: String?
    let instanceId: String?
    let isTrigger: Bool
}

struct FlowRendererOpenLinkRequest {
    let urlString: String
    let target: String?
    let screenId: String?
    let instanceId: String?
}

protocol FlowRuntimeDelegate: AnyObject {
    func flowViewControllerDidBecomeReady(_ controller: FlowViewController)

    func flowViewController(
        _ controller: FlowViewController,
        didChangeScreen screenId: String
    )

    func flowViewController(
        _ controller: FlowViewController,
        didDismissScreen screenId: String,
        revealingScreenId: String?
    )

    func flowViewController(
        _ controller: FlowViewController,
        didEmitEvent event: FlowRendererEvent
    )

    func flowViewController(
        _ controller: FlowViewController,
        didEmitViewModelChange change: FlowRendererViewModelChange
    )

    func flowViewController(
        _ controller: FlowViewController,
        didRequestOpenLink request: FlowRendererOpenLinkRequest
    )

    func flowViewControllerDidRequestDismiss(_ controller: FlowViewController, reason: CloseReason)
}

protocol NotificationPermissionEventReceiver: AnyObject {
    func flowViewController(
        _ controller: FlowViewController,
        didResolveNotificationPermissionEvent eventName: String,
        properties: [String: Any],
        journeyId: String
    )
}

protocol TrackingPermissionEventReceiver: AnyObject {
    func flowViewController(
        _ controller: FlowViewController,
        didResolveTrackingPermissionEvent eventName: String,
        properties: [String: Any],
        journeyId: String
    )
}

protocol RequestPermissionEventReceiver: AnyObject {
    func flowViewController(
        _ controller: FlowViewController,
        didResolveRequestPermissionEvent eventName: String,
        properties: [String: Any],
        journeyId: String
    )

    func flowViewController(
        _ controller: FlowViewController,
        didIgnoreUnsupportedRequestPermissionType permissionType: String,
        journeyId: String
    )
}

extension FlowRuntimeDelegate {
    func flowViewControllerDidBecomeReady(_ controller: FlowViewController) {}

    func flowViewController(
        _ controller: FlowViewController,
        didChangeScreen screenId: String
    ) {}

    func flowViewController(
        _ controller: FlowViewController,
        didDismissScreen screenId: String,
        revealingScreenId: String?
    ) {}

    func flowViewController(
        _ controller: FlowViewController,
        didEmitEvent event: FlowRendererEvent
    ) {}

    func flowViewController(
        _ controller: FlowViewController,
        didEmitViewModelChange change: FlowRendererViewModelChange
    ) {}

    func flowViewController(
        _ controller: FlowViewController,
        didRequestOpenLink request: FlowRendererOpenLinkRequest
    ) {}
}

/// FlowViewController - displays native flow content with loading and error states.
public class FlowViewController: NuxiePlatformViewController {
    private enum NativeRuntimeCommand {
        case viewModelSnapshot(FlowViewModelSnapshot, screenId: String?)
        case viewModelValue(path: VmPathRef, value: Any, screenId: String?, instanceId: String?)
        case viewModelList(operation: FlowViewModelListOperation, path: VmPathRef, payload: [String: Any], screenId: String?, instanceId: String?)
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

    private let viewModel: FlowViewModel
    var notificationAuthorizationHandler: NotificationAuthorizationHandling = UserNotificationAuthorizationHandler()
    var cameraPermissionAuthorizationHandler: PermissionAuthorizationHandling = CameraPermissionAuthorizationHandler()
    var locationPermissionAuthorizationHandler: PermissionAuthorizationHandling = LocationPermissionAuthorizationHandler()
    var microphonePermissionAuthorizationHandler: PermissionAuthorizationHandling = MicrophonePermissionAuthorizationHandler()
    var photoLibraryPermissionAuthorizationHandler: PermissionAuthorizationHandling = PhotoLibraryPermissionAuthorizationHandler()
    var trackingAuthorizationHandler: TrackingAuthorizationHandling = AppTrackingAuthorizationHandler()
    var cameraUsageDescriptionProvider: () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
    }
    var locationUsageDescriptionProvider: () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") as? String
    }
    var microphoneUsageDescriptionProvider: () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
    }
    var photoLibraryUsageDescriptionProvider: () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryUsageDescription") as? String
    }
    var trackingUsageDescriptionProvider: () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "NSUserTrackingUsageDescription") as? String
    }

    /// Delegate for runtime bridge messages
    weak var runtimeDelegate: FlowRuntimeDelegate? {
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

    /// Closure called when the flow is closed
    public var onClose: ((CloseReason) -> Void)?

    public var colorSchemeMode: FlowColorSchemeMode = .light {
        didSet {
            guard oldValue != colorSchemeMode else { return }
            guard isViewLoaded else { return }
            applyColorSchemeMode()
        }
    }

    // UI Components
    #if canImport(UIKit)
    private var flowTransitionCoordinator: FlowScreenTransitionCoordinator?
    private var runtimeCallbackCoordinator: FlowScreenTransitionCoordinator?
    private var flowArtifact: LoadedFlowArtifact?
    private var runtimeMountTask: Task<Void, Never>?
    private var runtimeFailureTask: Task<Void, Never>?
    private var runtimeMountGeneration: UInt64 = 0
    private var reportedRuntimeFailureGeneration: UInt64?
    private var isDrainingNativeRuntimeCommands = false
    private var activeNativeRuntimeNavigation: ActiveNativeRuntimeNavigation?
    private var pendingRuntimeReadyNotificationGeneration: UInt64?
    var runtimeContextProvider: @MainActor (LoadedFlowArtifact) async throws -> FlowRuntimeContext = {
        artifact in
        let request = try FlowRuntimeArtifactAdapter.makeImportRequest(from: artifact)
        return try await FlowRuntimeContextFactory(adapter: NuxieRuntimeAdapter())
            .makeContext(for: request)
    }
    var runtimeDiagnosticHandler: @MainActor (FlowRuntimeDiagnostic) -> Void = {
        $0.log()
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

    var flow: Flow {
        return viewModel.flow
    }

    var products: [FlowProduct] {
        return viewModel.products
    }

    // MARK: - Initialization

    init(
        flow: Flow,
        artifactStore: FlowArtifactStore,
        artifactTelemetryContext: FlowArtifactTelemetryContext? = nil,
        loadingTimeoutSeconds: TimeInterval = 15.0
    ) {
        self.viewModel = FlowViewModel(
            flow: flow,
            artifactStore: artifactStore,
            artifactTelemetryContext: artifactTelemetryContext,
            loadingTimeoutSeconds: loadingTimeoutSeconds
        )
        super.init(nibName: nil, bundle: nil)

        setupBindings()
        LogDebug("FlowViewController initialized for flow: \(flow.id)")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        applyColorSchemeMode()
        viewModel.loadFlow()
    }

    #if canImport(UIKit)
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // View controllers are cached and re-presented (FlowViewControllerCache);
        // without this reset a re-presented flow would never fire onClose again,
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
        flowTransitionCoordinator?.syncSafeAreaInsets()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        flowTransitionCoordinator?.layoutTextInputs()
    }
    #endif

    // MARK: - Public Methods


    func updateProducts(_ newProducts: [FlowProduct]) {
        viewModel.updateProducts(newProducts)
    }

    func updateFlowIfNeeded(_ newFlow: Flow) {
        viewModel.updateFlowIfNeeded(newFlow)
    }

    func updateArtifactTelemetryContext(_ context: FlowArtifactTelemetryContext) {
        viewModel.updateArtifactTelemetryContext(context)
    }

    /// Resets presentation-scoped state and starts a fresh runtime context for
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
            viewModel.loadFlow()
        } else {
            loadViewIfNeeded()
        }
        #endif
    }

    /// Deterministically releases every presentation-owned runtime session.
    /// A later presentation reloads the cached artifact through FlowViewModel
    /// and imports an entirely new context.
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

        let coordinator = flowTransitionCoordinator
        flowTransitionCoordinator = nil
        runtimeCallbackCoordinator = nil
        flowArtifact = nil
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
            let outcome = await self.resolveNotificationAuthorizationOutcome()
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
            let resolution = await self.resolveRequestPermissionOutcome(
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
            LogWarning("FlowViewController: tracking authorization is unsupported on this platform; skipping event")
            if let journeyId, !journeyId.isEmpty,
               let receiver = trackingPermissionEventReceiver {
                receiver.flowViewController(
                    self,
                    didResolveTrackingPermissionEvent: SystemEventNames.trackingDenied,
                    properties: journeyScopedEventProperties(journeyId: journeyId),
                    journeyId: journeyId
                )
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.resolveTrackingAuthorizationOutcome(
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
        NuxieSDK.shared.trigger(name, properties: properties.isEmpty ? nil : properties)
    }

    func performDismiss(reason: CloseReason = .userDismissed) {
        runtimeDelegate?.flowViewControllerDidRequestDismiss(self, reason: reason)
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
        // late fire can no longer tear down a newer flow's window.
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

    func applyViewModelSnapshot(_ snapshot: FlowViewModelSnapshot, screenId: String? = nil) {
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
        _ operation: FlowViewModelListOperation,
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
            self?.mountFlowArtifact(artifact)
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

    private func mountFlowArtifact(_ artifact: LoadedFlowArtifact) {
        #if canImport(UIKit)
        flowArtifact = artifact
        let generation = runtimeMountGeneration

        let previousMountTask = runtimeMountTask
        runtimeMountTask = Task { @MainActor [weak self] in
            guard let self else { return }

            await previousMountTask?.value
            guard !Task.isCancelled,
                  self.runtimeMountGeneration == generation else {
                return
            }

            let previousCoordinator = self.flowTransitionCoordinator
            self.flowTransitionCoordinator = nil
            await previousCoordinator?.tearDown()
            guard !Task.isCancelled,
                  self.runtimeMountGeneration == generation else {
                return
            }

            var candidate: FlowScreenTransitionCoordinator?
            do {
                let context = try await self.runtimeContextProvider(artifact)
                try Task.checkCancellation()
                guard self.runtimeMountGeneration == generation else {
                    throw CancellationError()
                }
                context.importResult.diagnostics.forEach(
                    self.runtimeDiagnosticHandler
                )

                let coordinator = FlowScreenTransitionCoordinator(
                    flow: self.flow,
                    artifact: artifact,
                    runtimeContext: context,
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
                self.flowTransitionCoordinator = coordinator
                candidate = nil
                self.handleNativeRuntimeReady(
                    generation: generation,
                    coordinator: coordinator
                )
                LogDebug("Mounted native flow artifact for flow \(self.flow.id)")
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
                    screenId: artifact.manifest.entry.screenId,
                    generation: generation
                )
            }

            if self.runtimeMountGeneration == generation {
                self.runtimeMountTask = nil
            }
        }
        #else
        viewModel.handleLoadingFailed(
            FlowError.configurationFailed(
                FlowArtifactStoreError.downloadFailed("Nuxie runtime unavailable")
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
        let previousCoordinator = flowTransitionCoordinator
        flowTransitionCoordinator = nil
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
        let previousCoordinator = flowTransitionCoordinator
        flowTransitionCoordinator = nil
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

        let coordinator = flowTransitionCoordinator
        flowTransitionCoordinator = nil
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
                "FlowViewController: terminal runtime failure on screen \(screenId): \(error)"
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
        coordinator: FlowScreenTransitionCoordinator
    ) {
        guard runtimeMountGeneration == generation,
              reportedRuntimeFailureGeneration != generation,
              flowTransitionCoordinator === coordinator,
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

    private func setFlowContentHidden(_ hidden: Bool) {
        #if canImport(UIKit)
        flowTransitionCoordinator?.setContentHidden(hidden)
        #endif
    }

    // MARK: - UI State Management

    private func updateUIState(_ state: FlowViewModel.State) {
        switch state {
        case .loading:
            setFlowContentHidden(true)
            loadingView.isHidden = false
            errorView.isHidden = true
            platformStartLoadingIndicator()

        case .loaded:
            setFlowContentHidden(false)
            loadingView.isHidden = true
            errorView.isHidden = true
            platformStopLoadingIndicator()

        case .error:
            setFlowContentHidden(true)
            loadingView.isHidden = true
            errorView.isHidden = false
            platformStopLoadingIndicator()
        }
    }

    func retryFromErrorView() {
        viewModel.retry()
    }
}

private extension FlowViewController {
    enum NotificationAuthorizationOutcome {
        case enabled
        case denied
    }

    enum RequestPermissionKind: String {
        case camera
        case location
        case microphone
        case photos
    }

    enum RequestPermissionResolution {
        case status(PermissionAuthorizationStatus)
        case unsupportedType
    }

    enum TrackingAuthorizationOutcome {
        case authorized
        case denied
        case unsupported
    }

    func invokeOnCloseOnce(_ reason: CloseReason, generation: UInt64) {
        guard closeGeneration == generation, !didInvokeClose else { return }
        didInvokeClose = true
        onClose?(reason)
    }

    func resolveNotificationAuthorizationOutcome() async -> NotificationAuthorizationOutcome {
        let status = await notificationAuthorizationHandler.authorizationStatus()
        if isNotificationAuthorizationGranted(status) {
            return .enabled
        }
        if status == .denied {
            return .denied
        }

        do {
            let granted = try await notificationAuthorizationHandler.requestAuthorization(
                options: [.alert, .badge, .sound]
            )
            return granted ? .enabled : .denied
        } catch {
            LogWarning("FlowViewController: notification request failed: \(error)")
            return .denied
        }
    }

    func resolveTrackingAuthorizationOutcome(
        currentStatus: TrackingAuthorizationStatus? = nil
    ) async -> TrackingAuthorizationOutcome {
        switch currentStatus ?? trackingAuthorizationHandler.authorizationStatus() {
        case .authorized:
            return .authorized
        case .denied, .restricted:
            return .denied
        case .unsupported:
            return .unsupported
        case .notDetermined:
            guard let usageDescription = trackingUsageDescriptionProvider()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !usageDescription.isEmpty
            else {
                LogWarning("FlowViewController: NSUserTrackingUsageDescription is missing; emitting tracking_denied")
                return .denied
            }

            switch await trackingAuthorizationHandler.requestAuthorization() {
            case .authorized:
                return .authorized
            case .denied, .restricted, .notDetermined:
                return .denied
            case .unsupported:
                return .unsupported
            }
        }
    }

    func resolveRequestPermissionOutcome(
        permissionType: String
    ) async -> RequestPermissionResolution {
        guard let permission = RequestPermissionKind(rawValue: permissionType) else {
            LogWarning("FlowViewController: Unsupported request permission type \(permissionType); skipping event")
            return .unsupportedType
        }

        let handler: PermissionAuthorizationHandling
        let usageDescriptionProvider: () -> String?
        let usageDescriptionKey: String

        switch permission {
        case .camera:
            handler = cameraPermissionAuthorizationHandler
            usageDescriptionProvider = cameraUsageDescriptionProvider
            usageDescriptionKey = "NSCameraUsageDescription"
        case .location:
            handler = locationPermissionAuthorizationHandler
            usageDescriptionProvider = locationUsageDescriptionProvider
            usageDescriptionKey = "NSLocationWhenInUseUsageDescription"
        case .microphone:
            handler = microphonePermissionAuthorizationHandler
            usageDescriptionProvider = microphoneUsageDescriptionProvider
            usageDescriptionKey = "NSMicrophoneUsageDescription"
        case .photos:
            handler = photoLibraryPermissionAuthorizationHandler
            usageDescriptionProvider = photoLibraryUsageDescriptionProvider
            usageDescriptionKey = "NSPhotoLibraryUsageDescription"
        }

        let currentStatus = handler.authorizationStatus()
        switch currentStatus {
        case .granted, .limited, .denied, .restricted, .unsupported:
            return .status(currentStatus)
        case .notDetermined:
            guard let usageDescription = usageDescriptionProvider()?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !usageDescription.isEmpty
            else {
                LogWarning("FlowViewController: \(usageDescriptionKey) is missing; emitting permission_denied")
                return .status(.denied)
            }
            return .status(await handler.requestAuthorization())
        }
    }

    func isNotificationAuthorizationGranted(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized:
            return true
        case .ephemeral, .provisional, .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
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

        receiver.flowViewController(
            self,
            didIgnoreUnsupportedRequestPermissionType: permissionType,
            journeyId: journeyId
        )
    }

    func dispatchNotificationPermissionEvent(
        _ eventName: String,
        properties: [String: Any],
        journeyId: String?
    ) {
        if let journeyId, !journeyId.isEmpty,
           let receiver = notificationPermissionEventReceiver {
            receiver.flowViewController(
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
        properties: [String: Any],
        journeyId: String?
    ) {
        if let journeyId, !journeyId.isEmpty,
           let receiver = trackingPermissionEventReceiver {
            receiver.flowViewController(
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
        properties: [String: Any],
        journeyId: String?
    ) {
        if let journeyId, !journeyId.isEmpty,
           let receiver = requestPermissionEventReceiver {
            receiver.flowViewController(
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
              let coordinator = flowTransitionCoordinator else {
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
        coordinator: FlowScreenTransitionCoordinator
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
              flowTransitionCoordinator === coordinator,
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
            _ = flowTransitionCoordinator?.applySnapshot(snapshot, screenId: screenId)
        case .viewModelValue(let path, let value, let screenId, let instanceId):
            _ = flowTransitionCoordinator?.applyValue(
                path: path,
                value: value,
                screenId: screenId,
                instanceId: instanceId
            )
        case .viewModelList(let operation, let path, let payload, let screenId, let instanceId):
            _ = flowTransitionCoordinator?.applyListOperation(
                operation,
                path: path,
                payload: payload,
                screenId: screenId,
                instanceId: instanceId
            )
        case .viewModelTrigger(let path, let screenId, let instanceId):
            _ = flowTransitionCoordinator?.fireTrigger(
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
        coordinator: FlowScreenTransitionCoordinator
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
              let coordinator = flowTransitionCoordinator,
              ObjectIdentifier(coordinator) == navigation.coordinatorID else {
            return
        }
        if didNavigate {
            runtimeDelegate?.flowViewController(
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
        coordinator: FlowScreenTransitionCoordinator
    ) {
        guard pendingRuntimeReadyNotificationGeneration == generation,
              runtimeReady,
              runtimeMountGeneration == generation,
              reportedRuntimeFailureGeneration != generation,
              flowTransitionCoordinator === coordinator,
              runtimeCallbackCoordinator === coordinator,
              activeNativeRuntimeNavigation == nil,
              pendingNativeRuntimeCommands.isEmpty,
              !isDrainingNativeRuntimeCommands else {
            return
        }
        pendingRuntimeReadyNotificationGeneration = nil
        runtimeDelegate?.flowViewControllerDidBecomeReady(self)
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
        runtimeDelegate?.flowViewController(
            self,
            didDismissScreen: dismissedScreenId,
            revealingScreenId: revealingScreenId
        )
    }

    private func acceptsRuntimeCallback(
        from controller: FlowScreenViewController
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
extension FlowViewController: FlowScreenViewControllerDelegate {
    func flowScreenViewControllerDidAdvance(_ controller: FlowScreenViewController) {
        guard acceptsRuntimeCallback(from: controller) else { return }
        flowTransitionCoordinator?.layoutTextInputs()
    }

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didEmitEvent event: FlowRendererEvent
    ) {
        guard acceptsRuntimeCallback(from: controller) else { return }
        runtimeDelegate?.flowViewController(self, didEmitEvent: event)
    }

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didEmitViewModelChange change: FlowRendererViewModelChange
    ) {
        guard acceptsRuntimeCallback(from: controller) else { return }
        runtimeDelegate?.flowViewController(self, didEmitViewModelChange: change)
    }

    func flowScreenViewController(
        _ controller: FlowScreenViewController,
        didRequestOpenLink request: FlowRendererOpenLinkRequest
    ) {
        guard acceptsRuntimeCallback(from: controller) else { return }
        runtimeDelegate?.flowViewController(self, didRequestOpenLink: request)
    }
}
#endif

// MARK: - Native Host Action Helpers

extension FlowViewController {
    fileprivate func handleNativePurchase(productId: String) {
        LogDebug("FlowViewController: Native purchase for product: \(productId)")
        let transactionService = Container.shared.transactionService()
        let productService = Container.shared.productService()

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
                LogInfo("FlowViewController: purchase pending for product \(productId)")
                self.emitSystemEvent(
                    SystemEventNames.purchasePending,
                    properties: ["product_id": productId]
                )
            } catch StoreKitError.purchaseFailed(_) {
                // TransactionService already triggered $purchase_failed for this
                // outcome before throwing; emitting here would double-count.
                // The generic catch below covers errors TransactionService never
                // saw (e.g. product fetch failures).
                LogWarning("FlowViewController: purchase failed for product \(productId)")
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
        LogDebug("FlowViewController: Native restore purchases")
        let transactionService = Container.shared.transactionService()
        Task { @MainActor in
            do {
                try await transactionService.restore()
            } catch StoreKitError.restoreFailed(_) {
                LogWarning("FlowViewController: restore purchases failed")
            } catch {
                self.emitSystemEvent(
                    SystemEventNames.restoreFailed,
                    properties: ["error": error.localizedDescription]
                )
            }
        }
    }
}

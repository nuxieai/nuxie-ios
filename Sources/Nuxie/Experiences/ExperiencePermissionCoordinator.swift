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

// MARK: - System authorization seams
// Extracted from ExperienceViewController (cleanup Phase 7): the controller keeps
// orchestration and event dispatch; everything that inspects or requests
// system permissions lives here.

protocol NotificationAuthorizationHandling: Sendable {
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

protocol TrackingAuthorizationHandling: Sendable {
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

protocol PermissionAuthorizationHandling: Sendable {
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

// @unchecked Sendable: `manager`/`continuations` are only touched on the
// main queue (all mutations are dispatched to DispatchQueue.main).
final class LocationPermissionAuthorizationHandler: NSObject, PermissionAuthorizationHandling, @unchecked Sendable {
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
        // Instance property (the class-method variant is deprecated in iOS 14).
        return Self.map((manager ?? CLLocationManager()).authorizationStatus)
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

// MARK: - Permission outcomes

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

// MARK: - Coordinator

/// Resolves system-permission requests for an experience: current status,
/// Info.plist usage-description gating, and authorization prompts. Handlers
/// and usage-description providers are injectable test seams.
@MainActor
final class ExperiencePermissionCoordinator {
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

    func resolveNotificationAuthorization() async -> NotificationAuthorizationOutcome {
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
            LogWarning("ExperiencePermissionCoordinator: notification request failed: \(error)")
            return .denied
        }
    }

    func resolveTrackingAuthorization(
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
                LogWarning("ExperiencePermissionCoordinator: NSUserTrackingUsageDescription is missing; emitting tracking_denied")
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

    func resolveRequestPermission(
        permissionType: String
    ) async -> RequestPermissionResolution {
        guard let permission = RequestPermissionKind(rawValue: permissionType) else {
            LogWarning("ExperiencePermissionCoordinator: unsupported request permission type \(permissionType); skipping event")
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
                LogWarning("ExperiencePermissionCoordinator: \(usageDescriptionKey) is missing; emitting permission_denied")
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

}

import Foundation
import Quick
import Nimble
import UserNotifications
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

/// The permission coordinator extracted from ExperienceViewController (Phase 7):
/// status resolution, Info.plist usage-description gating, and request flow.
final class ExperiencePermissionCoordinatorTests: AsyncSpec {
    override class func spec() {
        describe("ExperiencePermissionCoordinator") {
            var coordinator: ExperiencePermissionCoordinator!

            beforeEach {
                coordinator = await ExperiencePermissionCoordinator()
            }

            describe("request permission resolution") {
                it("reports unsupported types without consulting a handler") {
                    let resolution = await coordinator.resolveRequestPermission(
                        permissionType: "telepathy")
                    guard case .unsupportedType = resolution else {
                        fail("expected .unsupportedType, got \(resolution)")
                        return
                    }
                }

                it("returns the current status without prompting when already determined") {
                    let handler = StubPermissionHandler(status: .granted, requestResult: .denied)
                    await MainActor.run {
                        coordinator.cameraPermissionAuthorizationHandler = handler
                    }

                    let resolution = await coordinator.resolveRequestPermission(
                        permissionType: "camera")

                    guard case .status(.granted) = resolution else {
                        fail("expected .status(.granted), got \(resolution)")
                        return
                    }
                    expect(handler.requestCount).to(equal(0))
                }

                it("denies without prompting when the usage description is missing") {
                    let handler = StubPermissionHandler(
                        status: .notDetermined, requestResult: .granted)
                    await MainActor.run {
                        coordinator.microphonePermissionAuthorizationHandler = handler
                        coordinator.microphoneUsageDescriptionProvider = { nil }
                    }

                    let resolution = await coordinator.resolveRequestPermission(
                        permissionType: "microphone")

                    guard case .status(.denied) = resolution else {
                        fail("expected .status(.denied), got \(resolution)")
                        return
                    }
                    // The system prompt must never fire without a usage string
                    // (it would crash the host app).
                    expect(handler.requestCount).to(equal(0))
                }

                it("prompts when undetermined and the usage description exists") {
                    let handler = StubPermissionHandler(
                        status: .notDetermined, requestResult: .granted)
                    await MainActor.run {
                        coordinator.photoLibraryPermissionAuthorizationHandler = handler
                        coordinator.photoLibraryUsageDescriptionProvider = { "We need photos" }
                    }

                    let resolution = await coordinator.resolveRequestPermission(
                        permissionType: "photos")

                    guard case .status(.granted) = resolution else {
                        fail("expected .status(.granted), got \(resolution)")
                        return
                    }
                    expect(handler.requestCount).to(equal(1))
                }
            }

            describe("tracking resolution") {
                it("denies undetermined tracking without a usage description") {
                    let handler = StubTrackingHandler(
                        status: .notDetermined, requestResult: .authorized)
                    await MainActor.run {
                        coordinator.trackingAuthorizationHandler = handler
                        coordinator.trackingUsageDescriptionProvider = { "  " }
                    }

                    let outcome = await coordinator.resolveTrackingAuthorization(
                        currentStatus: nil)

                    expect(outcome).to(equal(.denied))
                    expect(handler.requestCount).to(equal(0))
                }

                it("authorizes when the prompt is granted") {
                    let handler = StubTrackingHandler(
                        status: .notDetermined, requestResult: .authorized)
                    await MainActor.run {
                        coordinator.trackingAuthorizationHandler = handler
                        coordinator.trackingUsageDescriptionProvider = { "Track for ads" }
                    }

                    let outcome = await coordinator.resolveTrackingAuthorization(
                        currentStatus: nil)

                    expect(outcome).to(equal(.authorized))
                    expect(handler.requestCount).to(equal(1))
                }

                it("passes unsupported through without prompting") {
                    let handler = StubTrackingHandler(
                        status: .unsupported, requestResult: .authorized)
                    await MainActor.run {
                        coordinator.trackingAuthorizationHandler = handler
                    }

                    let outcome = await coordinator.resolveTrackingAuthorization(
                        currentStatus: nil)

                    expect(outcome).to(equal(.unsupported))
                    expect(handler.requestCount).to(equal(0))
                }
            }

            describe("notification resolution") {
                it("reports enabled without prompting when already authorized") {
                    let handler = StubNotificationHandler(
                        status: .authorized, requestResult: .success(true))
                    await MainActor.run {
                        coordinator.notificationAuthorizationHandler = handler
                    }

                    let outcome = await coordinator.resolveNotificationAuthorization()

                    expect(outcome).to(equal(.enabled))
                    expect(handler.requestCount).to(equal(0))
                }

                it("reports denied when the prompt is declined") {
                    let handler = StubNotificationHandler(
                        status: .notDetermined, requestResult: .success(false))
                    await MainActor.run {
                        coordinator.notificationAuthorizationHandler = handler
                    }

                    let outcome = await coordinator.resolveNotificationAuthorization()

                    expect(outcome).to(equal(.denied))
                    expect(handler.requestCount).to(equal(1))
                }

                it("treats a throwing request as denied") {
                    let handler = StubNotificationHandler(
                        status: .notDetermined,
                        requestResult: .failure(NSError(domain: "test", code: 1)))
                    await MainActor.run {
                        coordinator.notificationAuthorizationHandler = handler
                    }

                    let outcome = await coordinator.resolveNotificationAuthorization()

                    expect(outcome).to(equal(.denied))
                }
            }
        }
    }
}

// MARK: - Stubs

private final class StubPermissionHandler: PermissionAuthorizationHandling, @unchecked Sendable {
    private let status: PermissionAuthorizationStatus
    private let requestResult: PermissionAuthorizationStatus
    private(set) var requestCount = 0

    init(status: PermissionAuthorizationStatus, requestResult: PermissionAuthorizationStatus) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus() -> PermissionAuthorizationStatus { status }

    func requestAuthorization() async -> PermissionAuthorizationStatus {
        requestCount += 1
        return requestResult
    }
}

private final class StubTrackingHandler: TrackingAuthorizationHandling, @unchecked Sendable {
    private let status: TrackingAuthorizationStatus
    private let requestResult: TrackingAuthorizationStatus
    private(set) var requestCount = 0

    init(status: TrackingAuthorizationStatus, requestResult: TrackingAuthorizationStatus) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus() -> TrackingAuthorizationStatus { status }

    func requestAuthorization() async -> TrackingAuthorizationStatus {
        requestCount += 1
        return requestResult
    }
}

private final class StubNotificationHandler: NotificationAuthorizationHandling, @unchecked Sendable {
    private let status: UNAuthorizationStatus
    private let requestResult: Result<Bool, Error>
    private(set) var requestCount = 0

    init(status: UNAuthorizationStatus, requestResult: Result<Bool, Error>) {
        self.status = status
        self.requestResult = requestResult
    }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestCount += 1
        return try requestResult.get()
    }
}

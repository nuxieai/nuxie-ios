import Foundation

/// Bridges renderer callbacks (FlowRuntimeDelegate + permission receivers)
/// onto the JourneyService actor. Pure plumbing: every callback hops onto the
/// service with the journey id it was created for. Extracted from
/// JourneyService (Phase 6).
// @unchecked Sendable: immutable identifiers plus a weak reference to the
// JourneyService actor (itself Sendable); no other mutable state. The
// FlowRuntimeDelegate conformance lives in an extension so the @MainActor
// protocol does not infect the whole class with MainActor isolation — the
// nonisolated witnesses satisfy the MainActor requirements safely.
final class JourneyRendererBridge:
  NotificationPermissionEventReceiver,
  RequestPermissionEventReceiver,
  TrackingPermissionEventReceiver,
  @unchecked Sendable
{
  private weak var journeyService: JourneyService?
  private let journeyId: String
  private let distinctId: String

  init(journeyId: String, distinctId: String, journeyService: JourneyService) {
    self.journeyId = journeyId
    self.distinctId = distinctId
    self.journeyService = journeyService
  }

  func flowViewControllerDidBecomeReady(_ controller: ExperienceViewController) {
    Task { [weak journeyService] in
      await journeyService?.handleRuntimeReady(
        journeyId: journeyId,
        controller: controller
      )
    }
  }

  func flowViewController(
    _ controller: ExperienceViewController,
    didChangeScreen screenId: String
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererScreenChanged(
        journeyId: journeyId,
        screenId: screenId
      )
    }
  }

  func flowViewController(
    _ controller: ExperienceViewController,
    didDismissScreen screenId: String,
    revealingScreenId: String?
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererScreenDismissed(
        journeyId: journeyId,
        screenId: screenId,
        revealingScreenId: revealingScreenId
      )
    }
  }

  func flowViewController(
    _ controller: ExperienceViewController,
    didEmitEvent event: ExperienceRendererEvent
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererEvent(
        journeyId: journeyId,
        event: event
      )
    }
  }

  func flowViewController(
    _ controller: ExperienceViewController,
    didEmitViewModelChange change: ExperienceRendererViewModelChange
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererViewModelChange(
        journeyId: journeyId,
        change: change
      )
    }
  }

  func flowViewController(
    _ controller: ExperienceViewController,
    didRequestOpenLink request: ExperienceRendererOpenLinkRequest
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleRendererOpenLink(
        journeyId: journeyId,
        request: request
      )
    }
  }

  func flowViewControllerDidRequestDismiss(_ controller: ExperienceViewController, reason: CloseReason) {
    Task { [weak journeyService] in
      await journeyService?.handleRuntimeDismiss(
        journeyId: journeyId,
        reason: reason,
        controller: controller
      )
    }
  }

  func flowViewController(
    _ controller: ExperienceViewController,
    didResolveNotificationPermissionEvent eventName: String,
    properties: sending [String: Any],
    journeyId: String
  ) {
    // Boxed to hand the write-once payload into the task.
    let propertiesBox = UncheckedSendable(properties)
    Task { [weak journeyService] in
      await journeyService?.handleScopedPermissionEvent(
        journeyId: journeyId,
        eventName: eventName,
        properties: propertiesBox.value,
        distinctId: distinctId
      )
    }
  }

  func flowViewController(
    _ controller: ExperienceViewController,
    didResolveRequestPermissionEvent eventName: String,
    properties: sending [String: Any],
    journeyId: String
  ) {
    // Boxed to hand the write-once payload into the task.
    let propertiesBox = UncheckedSendable(properties)
    Task { [weak journeyService] in
      await journeyService?.handleScopedPermissionEvent(
        journeyId: journeyId,
        eventName: eventName,
        properties: propertiesBox.value,
        distinctId: distinctId
      )
    }
  }

  func flowViewController(
    _ controller: ExperienceViewController,
    didIgnoreUnsupportedRequestPermissionType permissionType: String,
    journeyId: String
  ) {
    Task { [weak journeyService] in
      await journeyService?.handleUnsupportedScopedRequestPermission(
        journeyId: journeyId,
        permissionType: permissionType,
        distinctId: distinctId
      )
    }
  }

  func flowViewController(
    _ controller: ExperienceViewController,
    didResolveTrackingPermissionEvent eventName: String,
    properties: sending [String: Any],
    journeyId: String
  ) {
    // Boxed to hand the write-once payload into the task.
    let propertiesBox = UncheckedSendable(properties)
    Task { [weak journeyService] in
      await journeyService?.handleScopedPermissionEvent(
        journeyId: journeyId,
        eventName: eventName,
        properties: propertiesBox.value,
        distinctId: distinctId
      )
    }
  }
}

/// Pure mapping from the renderer's CloseReason to the dismissal
/// notification payload and the `$screen_dismissed` method string.
enum JourneyDismissalMapping {
  static func notificationReason(for reason: CloseReason) -> (reason: String, errorDescription: String?) {
    switch reason {
    case .userDismissed:
      return ("user_dismissed", nil)
    case .goalMet:
      return ("goal_met", nil)
    case .purchaseCompleted:
      return ("purchase_completed", nil)
    case .timeout:
      return ("timeout", nil)
    case .error(let error):
      return ("error", error.localizedDescription)
    }
  }

  static func dismissMethod(for reason: CloseReason) -> String {
    switch reason {
    case .userDismissed:
      return "user"
    case .goalMet:
      return "goal_met"
    case .purchaseCompleted:
      return "purchase_completed"
    case .timeout:
      return "timeout"
    case .error:
      return "error"
    }
  }

  static func exitReason(for reason: CloseReason) -> JourneyExitReason {
    switch reason {
    case .userDismissed:
      return .dismissed
    case .goalMet:
      return .goalMet
    case .error:
      return .error
    case .purchaseCompleted, .timeout:
      return .completed
    }
  }
}

extension JourneyRendererBridge: FlowRuntimeDelegate {}

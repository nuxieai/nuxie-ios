import Foundation
import FactoryKit

// NuxieLifecycleCoordinator.swift
final class NuxieLifecycleCoordinator {
  /// App lifecycle transitions, in notification order.
  private enum LifecycleTransition {
    case didEnterBackground
    case willEnterForeground
    case didBecomeActive
  }

  private var observers: [NSObjectProtocol] = []
  private let lifecycleTracker: AppLifecycleTracker?

  /// Transitions are handled by a single FIFO worker so a fast
  /// background→foreground→background sequence can never interleave service
  /// fan-out (an unordered Task per notification could run the foreground
  /// handler while the background handler was still mid-flight).
  private let transitions: AsyncStream<LifecycleTransition>
  private let transitionContinuation: AsyncStream<LifecycleTransition>.Continuation
  private var worker: Task<Void, Never>?

  private let sessionService: SessionServiceProtocol
  private let journeyService: JourneyServiceProtocol
  private let eventLog: EventLogProtocol
  private let profileService: ProfileServiceProtocol
  // MainActor-isolated; resolved lazily until the FactoryKit finale.
  @Injected(\.flowPresentationService) private var flowPresentationService: ExperiencePresentationServiceProtocol
  private let featureService: FeatureServiceProtocol

  init(
    lifecycleTracker: AppLifecycleTracker? = nil,
    sessions: SessionServiceProtocol = Container.shared.sessionService(),
    journeys: JourneyServiceProtocol = Container.shared.journeyService(),
    eventLog: EventLogProtocol = Container.shared.eventLog(),
    profile: ProfileServiceProtocol = Container.shared.profileService(),
    features: FeatureServiceProtocol = Container.shared.featureService()
  ) {
    (self.transitions, self.transitionContinuation) = AsyncStream.makeStream()
    self.lifecycleTracker = lifecycleTracker
    self.sessionService = sessions
    self.journeyService = journeys
    self.eventLog = eventLog
    self.profileService = profile
    self.featureService = features
  }

  func start() {
    let nc = NotificationCenter.default

    // $app_installed / $app_updated / $app_opened — the event system queues
    // internally, so tracking before it finishes configuring is safe.
    lifecycleTracker?.trackAppLaunchEvents()

    worker = Task { [weak self, transitions] in
      for await transition in transitions {
        guard let self else { return }
        await self.handle(transition)
      }
    }

    // Observers do only the synchronous main-thread UI work; service fan-out
    // is enqueued so the worker handles transitions strictly in order.
    observers.append(
      nc.addObserver(
        forName: NuxieSystemNotifications.appDidEnterBackground,
        object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.flowPresentationService.onAppDidEnterBackground()
        self.transitionContinuation.yield(.didEnterBackground)
      })

    observers.append(
      nc.addObserver(
        forName: NuxieSystemNotifications.appWillEnterForeground,
        object: nil, queue: .main
      ) { [weak self] _ in
        self?.transitionContinuation.yield(.willEnterForeground)
      })

    observers.append(
      nc.addObserver(
        forName: NuxieSystemNotifications.appDidBecomeActive,
        object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.flowPresentationService.onAppBecameActive()
        self.transitionContinuation.yield(.didBecomeActive)
      })
  }

  private func handle(_ transition: LifecycleTransition) async {
    switch transition {
    case .didEnterBackground:
      sessionService.onAppDidEnterBackground()
      await journeyService.onAppDidEnterBackground()
      await eventLog.onAppDidEnterBackground()
      // Emit $app_backgrounded after services have processed
      lifecycleTracker?.trackAppBackgrounded()

    case .willEnterForeground:
      // Re-arm timers BEFORE UI is active so we can catch up time-based work,
      // but do not present flows until after didBecomeActive + debounce.
      await journeyService.onAppWillEnterForeground()
      // Emit $app_opened after journey service has processed
      lifecycleTracker?.trackAppForegrounded()

    case .didBecomeActive:
      sessionService.onAppBecameActive()
      await eventLog.onAppBecameActive()
      await profileService.onAppBecameActive()
      // Sync FeatureInfo after profile refresh (for SwiftUI reactivity)
      await featureService.syncFeatureInfo()
      await journeyService.onAppBecameActive()
    }
  }

  func stop() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    transitionContinuation.finish()
    worker?.cancel()
    worker = nil
  }

  deinit {
    stop()
  }
}

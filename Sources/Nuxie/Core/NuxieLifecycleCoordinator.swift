import Foundation

// NuxieLifecycleCoordinator.swift
// @unchecked Sendable: all service references are immutable Sendable values;
// `observers`/`worker` are mutated only by start()/stop(), which the SDK
// lifecycle invokes serially (setup/shutdown), never concurrently. stop()
// closes notification intake synchronously before its first suspension.
final class NuxieLifecycleCoordinator: @unchecked Sendable {
  /// App lifecycle transitions, in notification order.
  private enum LifecycleTransition {
    case didEnterBackground
    case willEnterForeground
    case didBecomeActive
  }

  private var observers: [NSObjectProtocol] = []
  private let lifecycleTracker: AppLifecycleTracker

  /// Transitions are handled by a single FIFO worker so a fast
  /// background→foreground→background sequence can never interleave service
  /// fan-out (an unordered Task per notification could run the foreground
  /// handler while the background handler was still mid-flight).
  private let transitions: AsyncStream<LifecycleTransition>
  private let transitionContinuation: AsyncStream<LifecycleTransition>.Continuation
  private var worker: Task<Void, Never>?

  private let journeyService: JourneyServiceProtocol
  private let deviceLegService: (any DeviceLegServiceProtocol)?
  private let eventLog: EventQueueLifecycle
  private let profileService: ProfileServiceProtocol
  private let experiencePresentationService: ExperiencePresentationServiceProtocol
  private let experienceService: ExperienceServiceProtocol
  private let featureService: FeatureServiceProtocol

  init(
    lifecycleTracker: AppLifecycleTracker,
    journeys: JourneyServiceProtocol,
    deviceLegs: (any DeviceLegServiceProtocol)? = nil,
    eventLog: EventQueueLifecycle,
    profile: ProfileServiceProtocol,
    experiences: ExperienceServiceProtocol,
    experiencePresentation: ExperiencePresentationServiceProtocol,
    features: FeatureServiceProtocol
  ) {
    (self.transitions, self.transitionContinuation) = AsyncStream.makeStream()
    self.lifecycleTracker = lifecycleTracker
    self.journeyService = journeys
    self.deviceLegService = deviceLegs
    self.eventLog = eventLog
    self.profileService = profile
    self.experienceService = experiences
    self.experiencePresentationService = experiencePresentation
    self.featureService = features
  }

  func start() {
    let nc = NotificationCenter.default

    // $app_installed / $app_updated / $app_opened — the event system queues
    // internally, so tracking before it finishes configuring is safe.
    lifecycleTracker.trackAppLaunchEvents()

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
        MainActor.assumeIsolated {
          self.experiencePresentationService.onAppDidEnterBackground()
        }
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
        MainActor.assumeIsolated {
          self.experiencePresentationService.onAppBecameActive()
        }
        self.transitionContinuation.yield(.didBecomeActive)
      })
  }

  private func handle(_ transition: LifecycleTransition) async {
    switch transition {
    case .didEnterBackground:
      await experienceService.onAppDidEnterBackground()
      await deviceLegService?.onAppDidEnterBackground()
      await journeyService.onAppDidEnterBackground()
      await eventLog.onAppDidEnterBackground()
      // Emit $app_backgrounded after services have processed
      lifecycleTracker.trackAppBackgrounded()

    case .willEnterForeground:
      // Re-arm timers BEFORE UI is active so we can catch up time-based work,
      // but do not present experiences until after didBecomeActive + debounce.
      await deviceLegService?.onAppWillEnterForeground()
      await journeyService.onAppWillEnterForeground()
      // Emit $app_opened after journey service has processed
      lifecycleTracker.trackAppForegrounded()

    case .didBecomeActive:
      await eventLog.onAppBecameActive()
      // Expire or refresh resident profile authority before speculative
      // Experience preparation is allowed to resume from that authority.
      await profileService.onAppBecameActive()
      await experienceService.onAppBecameActive()
      // Sync FeatureInfo after profile refresh (for SwiftUI reactivity)
      await featureService.syncFeatureInfo()
      // Presentation actions resumed by either runtime may await this gate.
      // Re-open it after profile authority is current, before invoking those
      // runtimes, so the serialized lifecycle worker cannot wait on itself.
      await experiencePresentationService.deviceLegProfileRefreshDidComplete()
      await deviceLegService?.onAppBecameActive()
      await journeyService.onAppBecameActive()
    }
  }

  func stop() async {
    stopIntake()
    let activeWorker = worker
    activeWorker?.cancel()
    await activeWorker?.value
    worker = nil
  }

  private func stopIntake() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
    transitionContinuation.finish()
  }

  deinit {
    // Normal SDK teardown uses async stop() and joins the worker. This is only
    // a best-effort backstop for a graph discarded before publication.
    stopIntake()
    worker?.cancel()
  }
}

import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

  private let journeyService: (any JourneyServiceProtocol)?
  private let eventLog: EventQueueLifecycle
  private let profileService: ProfileServiceProtocol
  private let experiencePresentationService: ExperiencePresentationServiceProtocol
  private let journeyPresentationService: any JourneyPresenting
  private let featureService: FeatureServiceProtocol
  private let experienceService: ExperienceServiceProtocol

  init(
    lifecycleTracker: AppLifecycleTracker,
    journeys: (any JourneyServiceProtocol)? = nil,
    eventLog: EventQueueLifecycle,
    profile: ProfileServiceProtocol,
    experiences: ExperienceServiceProtocol,
    experiencePresentation: ExperiencePresentationServiceProtocol,
    journeyPresentation: any JourneyPresenting,
    features: FeatureServiceProtocol
  ) {
    (self.transitions, self.transitionContinuation) = AsyncStream.makeStream()
    self.lifecycleTracker = lifecycleTracker
    self.journeyService = journeys
    self.eventLog = eventLog
    self.profileService = profile
    self.experiencePresentationService = experiencePresentation
    self.journeyPresentationService = journeyPresentation
    self.featureService = features
    self.experienceService = experiences
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

    // Background Experience preparation starts foreground, like the
    // presentation service. A launch straight into the background pauses it
    // before any profile commit can start the lane. The first activation
    // resumes it on the main queue (below), so a launch that only reads as
    // background because no scene has connected yet stays paused until that
    // activation, not until the profile refetch after it.
    let experiences = experienceService
    let pauseIfLaunchedInBackground: @MainActor @Sendable () -> Void = {
      #if canImport(UIKit)
      if UIApplication.shared.applicationState == .background {
        experiences.onAppDidEnterBackground()
      }
      #endif
    }
    if Thread.isMainThread {
      MainActor.assumeIsolated(pauseIfLaunchedInBackground)
    } else {
      DispatchQueue.main.async { pauseIfLaunchedInBackground() }
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
        // Pause background preparation now, outside the FIFO worker. The
        // pause and the resume both happen on the main queue in notification
        // order, so neither can wait behind a slow profile refetch or land
        // after a later transition.
        self.experienceService.onAppDidEnterBackground()
        self.transitionContinuation.yield(.didEnterBackground)
      })

    // A memory warning only marks the preparation gate. Prepared releases
    // stay; nothing is rebuilt as a direct reaction to the warning.
    if let memoryWarning = NuxieSystemNotifications.appDidReceiveMemoryWarning {
      observers.append(
        nc.addObserver(
          forName: memoryWarning,
          object: nil, queue: .main
        ) { [weak self] _ in
          self?.experienceService.didReceiveMemoryWarning()
        })
    }

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
        // Resume background preparation here, not in the worker: a resume
        // queued behind the profile refetch could run after the app had
        // backgrounded again and undo that pause.
        self.experienceService.onAppBecameActive()
        self.transitionContinuation.yield(.didBecomeActive)
      })
  }

  private func handle(_ transition: LifecycleTransition) async {
    switch transition {
    case .didEnterBackground:
      await journeyService?.onAppDidEnterBackground()
      await eventLog.onAppDidEnterBackground()
      // Emit $app_backgrounded after services have processed
      lifecycleTracker.trackAppBackgrounded()

    case .willEnterForeground:
      // Re-arm timers BEFORE UI is active so we can catch up time-based work,
      // but do not present experiences until after didBecomeActive + debounce.
      await journeyService?.onAppWillEnterForeground()
      // Emit $app_opened after journey service has processed
      lifecycleTracker.trackAppForegrounded()

    case .didBecomeActive:
      await eventLog.onAppBecameActive()
      // Expire or refresh resident profile authority. A changed profile
      // re-queues background Experience preparation through its commit.
      await profileService.onAppBecameActive()
      // Sync FeatureInfo after profile refresh (for SwiftUI reactivity)
      await featureService.syncFeatureInfo()
      // Presentation actions resumed by either runtime may await this gate.
      // Re-open it after profile authority is current, before invoking those
      // runtimes, so the serialized lifecycle worker cannot wait on itself.
      await journeyPresentationService.journeyProfileRefreshDidComplete()
      await journeyService?.onAppBecameActive()
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

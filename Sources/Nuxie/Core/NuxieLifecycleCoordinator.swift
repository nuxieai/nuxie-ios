import Foundation
import FactoryKit

// NuxieLifecycleCoordinator.swift
final class NuxieLifecycleCoordinator {
  private var observers: [NSObjectProtocol] = []
  private let lifecycleTracker: AppLifecycleTracker?

  @Injected(\.sessionService) private var sessionService: SessionServiceProtocol
  @Injected(\.journeyService) private var journeyService: JourneyServiceProtocol
  @Injected(\.eventService) private var eventService: EventServiceProtocol
  @Injected(\.profileService) private var profileService: ProfileServiceProtocol
  @Injected(\.flowPresentationService) private var flowPresentationService: FlowPresentationServiceProtocol
  @Injected(\.featureService) private var featureService: FeatureServiceProtocol

  init(lifecycleTracker: AppLifecycleTracker? = nil) {
    self.lifecycleTracker = lifecycleTracker
  }

  func start() {
    let nc = NotificationCenter.default

    // $app_installed / $app_updated / $app_opened — the event system queues
    // internally, so tracking before it finishes configuring is safe.
    lifecycleTracker?.trackAppLaunchEvents()

    observers.append(
      nc.addObserver(
        forName: NuxieSystemNotifications.appDidEnterBackground,
        object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.flowPresentationService.onAppDidEnterBackground()
        Task {
          self.sessionService.onAppDidEnterBackground()
          await self.journeyService.onAppDidEnterBackground()
          await self.eventService.onAppDidEnterBackground()
          // Emit $app_backgrounded after services have processed
          self.lifecycleTracker?.trackAppBackgrounded()
        }
      })

    observers.append(
      nc.addObserver(
        forName: NuxieSystemNotifications.appWillEnterForeground,
        object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        Task {
          // Re-arm timers BEFORE UI is active so we can catch up time-based work,
          // but do not present flows until after didBecomeActive + debounce.
          await self.journeyService.onAppWillEnterForeground()
          // Emit $app_opened after journey service has processed
          self.lifecycleTracker?.trackAppForegrounded()
        }
      })

    observers.append(
      nc.addObserver(
        forName: NuxieSystemNotifications.appDidBecomeActive,
        object: nil, queue: .main
      ) { [weak self] _ in
        guard let self else { return }
        self.flowPresentationService.onAppBecameActive()
        Task {
          // Services can compute immediately
          self.sessionService.onAppBecameActive()
          await self.eventService.onAppBecameActive()
          await self.profileService.onAppBecameActive()
          // Sync FeatureInfo after profile refresh (for SwiftUI reactivity)
          await self.featureService.syncFeatureInfo()
          await self.journeyService.onAppBecameActive()
        }
      })
  }

  func stop() {
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
  }

  deinit {
    stop()
  }
}

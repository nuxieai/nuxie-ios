import Foundation

/// One immutable SDK-authored event identity carried from retry ownership
/// through EventLog commit and local routing.
struct StableSystemEventCaptureRequest: @unchecked Sendable {
    let name: String
    let properties: [String: Any]?
    let eventId: String
    let distinctId: String
}

/// Fire-and-forget entry point for SDK-authored events. Internal services use
/// this capability instead of reaching through the public singleton facade.
protocol SystemEventSink: AnyObject, Sendable {
    func emit(_ name: String, properties: [String: Any]?)
    /// Returns true only after the stable capture is durable and its required
    /// local routing has settled. Production may keep retrying after a false
    /// result, but durable callers must retain their own recovery evidence until
    /// a later attempt is acknowledged.
    func capture(_ request: StableSystemEventCaptureRequest) async -> Bool
    func captureOnly(_ request: StableSystemEventCaptureRequest) async -> Bool
    /// Durably captures one stable event and routes it to local Journey
    /// subscribers. Generic sinks preserve the explicit carrier-first contract;
    /// the production sink overrides this with EventLog's atomic commit lane.
    func captureAndRoute(
        _ request: StableSystemEventCaptureRequest,
        ensureDurableCarrier: Bool
    ) async -> Bool
}

extension SystemEventSink {
    func capture(_ request: StableSystemEventCaptureRequest) async -> Bool {
        emit(request.name, properties: request.properties)
        return true
    }

    func captureOnly(_ request: StableSystemEventCaptureRequest) async -> Bool {
        await capture(request)
    }

    func captureAndRoute(
        _ request: StableSystemEventCaptureRequest,
        ensureDurableCarrier: Bool
    ) async -> Bool {
        if ensureDurableCarrier {
            guard await captureOnly(request) else { return false }
        }
        return await capture(request)
    }

    /// Captures one stable event identity with an explicit local-routing
    /// policy. External commercial declarations can require the durable
    /// carrier before Journey routing; cold recovery remains capture-only.
    func captureStableSystemEvent(
        _ request: StableSystemEventCaptureRequest,
        routeToJourneys: Bool,
        ensureDurableCarrier: Bool = false
    ) async -> Bool {
        if routeToJourneys {
            return await captureAndRoute(
                request,
                ensureDurableCarrier: ensureDurableCarrier
            )
        }
        return await captureOnly(request)
    }

    /// Emits an ordinary commerce outcome or durably captures the stable
    /// identity owned by a device Journey action. Both StoreKit entry points
    /// use this seam so correlated outcomes cannot drift onto different retry
    /// or routing behavior.
    func emitOrCaptureCommerceOutcome(
        _ name: String,
        properties: UncheckedSendable<[String: Any]?>,
        correlation: CommerceOutcomeCorrelation?,
        uncorrelatedEmitter: (@MainActor @Sendable (
            _ name: String,
            _ properties: UncheckedSendable<[String: Any]?>
        ) -> Void)? = nil
    ) async -> Bool {
        guard let correlation else {
            if let uncorrelatedEmitter {
                await uncorrelatedEmitter(name, properties)
            } else {
                emit(name, properties: properties.value)
            }
            return true
        }
        return await capture(.init(
            name: name,
            properties: properties.value,
            eventId: correlation.eventId,
            distinctId: correlation.distinctId
        ))
    }
}

final class DiscardingSystemEventSink: SystemEventSink, Sendable {
    func emit(_ name: String, properties: [String: Any]?) {}

    func capture(_ request: StableSystemEventCaptureRequest) async -> Bool {
        _ = request
        return false
    }
}

/// Keeps a live correlated commerce outcome owned after a transient EventLog
/// failure. Stable IDs make every attempt idempotent; retries remain ordered by
/// first admission so two outcomes cannot overtake each other locally.
private actor StableSystemEventCaptureRetryQueue {
    private struct RetryResult: Sendable {
        let isEmpty: Bool
        let madeProgress: Bool
    }

    private let routedEvents: (any RoutedStableSystemEventCapturing)?
    private let triggerProvider: @Sendable () -> TriggerServiceProtocol
    private let retryLoop: CancellationAwareExponentialRetryLoop
    private var pendingByEventId: [String: StableSystemEventCaptureRequest] = [:]
    private var pendingOrder: [String] = []
    private var retryTask: Task<Void, Never>?

    init(
        routedEvents: (any RoutedStableSystemEventCapturing)?,
        triggerProvider: @escaping @Sendable () -> TriggerServiceProtocol,
        baseDelayNanoseconds: UInt64
    ) {
        self.routedEvents = routedEvents
        self.triggerProvider = triggerProvider
        retryLoop = CancellationAwareExponentialRetryLoop(
            initialDelayNanoseconds: baseDelayNanoseconds,
            maximumDelayNanoseconds: 2_000_000_000
        )
    }

    /// Reserves retry ownership before the first suspension. A queued retry is
    /// deliberately reported as unacknowledged until EventLog commits it, so a
    /// durable caller keeps its own recovery evidence across process death.
    func captureOrQueue(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        if let pending = pendingByEventId[request.eventId] {
            guard pending.name == request.name,
                  pending.distinctId == request.distinctId else {
                LogError("Stable system event retry rejected an event-id collision: \(request.eventId)")
                return false
            }
            return false
        }

        pendingByEventId[request.eventId] = request
        pendingOrder.append(request.eventId)

        guard pendingOrder.first == request.eventId else {
            startRetryTaskIfNeeded()
            return false
        }

        if await attempt(request) {
            remove(request.eventId)
            return true
        }

        LogWarning("Stable system event capture queued for retry: \(request.eventId)")
        startRetryTaskIfNeeded()
        return false
    }

    private func attempt(
        _ request: StableSystemEventCaptureRequest
    ) async -> Bool {
        if let routedEvents {
            guard await routedEvents.captureAndRouteSystemEvent(request)
                    != nil else { return false }
            // EventLog commits before enqueueing its route. Keep retry
            // ownership until every subscriber admitted with that commit has
            // returned; DeviceLeg persists its correlated transition before
            // returning from the subscriber callback.
            await routedEvents.drainCommittedRouting()
            return true
        }
        return await triggerProvider().captureSystemEvent(
            request.name,
            properties: request.properties,
            eventId: request.eventId,
            distinctId: request.distinctId
        )
    }

    private func remove(_ eventId: String) {
        pendingByEventId.removeValue(forKey: eventId)
        pendingOrder.removeAll { $0 == eventId }
    }

    private func startRetryTaskIfNeeded() {
        guard retryTask == nil, !pendingOrder.isEmpty else { return }
        let retryLoop = retryLoop
        retryTask = Task { [weak self, retryLoop] in
            await retryLoop.run {
                guard let result = await self?.retryPending() else {
                    return .finished
                }
                if result.isEmpty { return .finished }
                return result.madeProgress ? .madeProgress : .pending
            }
        }
    }

    private func retryPending() async -> RetryResult {
        let eventIds = pendingOrder
        var madeProgress = false
        for eventId in eventIds {
            guard let pending = pendingByEventId[eventId] else { continue }
            if await attempt(pending) {
                remove(eventId)
                madeProgress = true
            } else {
                // A later correlated outcome must never overtake the oldest
                // unacknowledged capture.
                break
            }
        }
        let isEmpty = pendingOrder.isEmpty
        if isEmpty {
            retryTask = nil
        }
        return RetryResult(isEmpty: isEmpty, madeProgress: madeProgress)
    }
}

/// Routes internal events through the same trigger pipeline as `NuxieSDK.trigger`.
final class TriggerSystemEventSink: SystemEventSink, @unchecked Sendable {
    private let triggerProvider: @Sendable () -> TriggerServiceProtocol
    private let stableCaptureRetries: StableSystemEventCaptureRetryQueue

    init(
        routedEvents: (any RoutedStableSystemEventCapturing)? = nil,
        stableCaptureRetryBaseDelayNanoseconds: UInt64 = 50_000_000,
        triggerProvider: @escaping @Sendable () -> TriggerServiceProtocol
    ) {
        self.triggerProvider = triggerProvider
        stableCaptureRetries = StableSystemEventCaptureRetryQueue(
            routedEvents: routedEvents,
            triggerProvider: triggerProvider,
            baseDelayNanoseconds: stableCaptureRetryBaseDelayNanoseconds
        )
    }

    func emit(_ name: String, properties: [String: Any]?) {
        let properties = UncheckedSendable(properties)
        let trigger = triggerProvider()
        Task { @MainActor in
            await trigger.trigger(
                name,
                properties: properties.value
            ) { _ in }
        }
    }

    func capture(_ request: StableSystemEventCaptureRequest) async -> Bool {
        await stableCaptureRetries.captureOrQueue(request)
    }

    func captureAndRoute(
        _ request: StableSystemEventCaptureRequest,
        ensureDurableCarrier _: Bool
    ) async -> Bool {
        // EventLog atomically commits the durable carrier and enqueues local
        // routing for a newly committed stable ID. A separate carrier-first
        // call here would make the later same-ID route look like a replay and
        // correctly suppress it.
        await capture(request)
    }

    func captureOnly(_ request: StableSystemEventCaptureRequest) async -> Bool {
        return await triggerProvider().captureSystemEventOnly(
            request.name,
            properties: request.properties,
            eventId: request.eventId,
            distinctId: request.distinctId
        )
    }
}

protocol LocaleIdentifierProviding: Sendable {
    func localeIdentifier() -> String
}

struct ConfigurationLocaleIdentifierProvider: LocaleIdentifierProviding {
    private let configuredLocale: @Sendable () -> String?
    private let deviceLocale: @Sendable () -> String

    init(
        configuredLocale: @escaping @Sendable () -> String?,
        deviceLocale: @escaping @Sendable () -> String = { Locale.current.identifier }
    ) {
        self.configuredLocale = configuredLocale
        self.deviceLocale = deviceLocale
    }

    func localeIdentifier() -> String {
        configuredLocale() ?? deviceLocale()
    }
}

protocol PurchaseSettingsProviding: Sendable {
    func purchaseDelegate() -> NuxiePurchaseDelegate?
    func purchaseHandlingMode() -> NuxieConfiguration.PurchaseHandlingMode
}

/// Synchronized home for the small set of settings supported after setup.
final class NuxieRuntimeSettings:
    LocaleIdentifierProviding,
    PurchaseSettingsProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var locale: String?
    private var delegate: NuxiePurchaseDelegate?
    private var handlingMode: NuxieConfiguration.PurchaseHandlingMode
    private let deviceLocale: @Sendable () -> String

    init(
        localeIdentifier: String?,
        purchaseDelegate: NuxiePurchaseDelegate?,
        purchaseHandlingMode: NuxieConfiguration.PurchaseHandlingMode,
        deviceLocale: @escaping @Sendable () -> String = { Locale.current.identifier }
    ) {
        locale = localeIdentifier
        delegate = purchaseDelegate
        handlingMode = purchaseHandlingMode
        self.deviceLocale = deviceLocale
    }

    convenience init(
        configuration: NuxieConfiguration,
        deviceLocale: @escaping @Sendable () -> String = { Locale.current.identifier }
    ) {
        self.init(
            localeIdentifier: configuration.localeIdentifier,
            purchaseDelegate: configuration.purchaseDelegate,
            purchaseHandlingMode: configuration.purchaseHandlingMode,
            deviceLocale: deviceLocale
        )
    }

    func localeIdentifier() -> String {
        lock.lock()
        let locale = locale
        lock.unlock()
        return locale ?? deviceLocale()
    }

    func purchaseDelegate() -> NuxiePurchaseDelegate? {
        lock.lock()
        defer { lock.unlock() }
        return delegate
    }

    func purchaseHandlingMode() -> NuxieConfiguration.PurchaseHandlingMode {
        lock.lock()
        defer { lock.unlock() }
        return handlingMode
    }

    func setLocaleIdentifier(_ localeIdentifier: String?) {
        lock.lock()
        locale = localeIdentifier
        lock.unlock()
    }

    func setPurchaseDelegate(_ purchaseDelegate: NuxiePurchaseDelegate?) {
        lock.lock()
        delegate = purchaseDelegate
        lock.unlock()
    }

    func setPurchaseHandlingMode(_ purchaseHandlingMode: NuxieConfiguration.PurchaseHandlingMode) {
        lock.lock()
        handlingMode = purchaseHandlingMode
        lock.unlock()
    }
}

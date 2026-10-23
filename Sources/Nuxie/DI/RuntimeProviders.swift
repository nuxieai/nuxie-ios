import Foundation

/// One immutable SDK-authored event identity carried from retry ownership
/// through EventLog commit and local routing.
struct StableSystemEventCaptureRequest: @unchecked Sendable {
    let name: String
    let properties: [String: Any]?
    let eventId: String
    let distinctId: String
    var journeyOrigin: JourneyEventOrigin? = nil
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

/// Retains correlated capture input until the ordered queue commits and routes
/// it. Capture failures use the same timer and stable key as all local work.
private actor StableSystemEventCaptureRetryQueue {
    private final class PendingCapture {
        let request: StableSystemEventCaptureRequest
        var localRoutePending: Bool?
        init(_ request: StableSystemEventCaptureRequest) { self.request = request }
    }
    private let events: any EventLogProtocol
    private var pendingByEventId: [String: PendingCapture] = [:]

    init(events: any EventLogProtocol) { self.events = events }

    func captureOrQueue(_ request: StableSystemEventCaptureRequest) async -> Bool {
        if let pending = pendingByEventId[request.eventId] {
            guard pending.request.name == request.name, pending.request.distinctId == request.distinctId else {
                LogError("Stable system event retry rejected an event-id collision: \(request.eventId)")
                return false
            }
            return false
        }
        let pending = PendingCapture(request)
        pendingByEventId[request.eventId] = pending
        let journeyId = request.journeyOrigin?.journeyId
            ?? (request.properties?["journey_id"] as? String)
        let captured = await events.performJourneyWork(.init(
            key: .init(distinctId: request.distinctId, id: "stable-capture:\(request.eventId)"),
            runId: journeyId ?? "stable-capture:\(request.eventId)", afterFailure: false, cancelsWithJourney: false,
            operation: { [weak self] in
                guard let self else { return .complete }
                return await self.attempt(eventId: request.eventId)
            }))
        guard captured, let localPending = pending.localRoutePending else { return false }
        if localPending { return await events.drainCommittedRouting() }
        return true
    }

    private func attempt(eventId: String) async -> JourneyQueueResult {
        guard let pending = pendingByEventId[eventId] else { return .complete }
        let request = pending.request
        await events.reserveJourneyCapturePosition(eventId: eventId, distinctId: request.distinctId)
        guard let captured = await events.captureAndRouteSystemEvent(request) else { return .retry }
        pending.localRoutePending = captured.localRoutePending
        if captured.localRoutePending {
            // Ensure the event joins at the reserved position when routing is
            // open. Its own entry owns delivery and receipt retries afterwards.
            _ = await events.drainCommittedRouting()
        } else {
            await events.releaseJourneyCapturePosition(eventId: eventId, distinctId: request.distinctId)
        }
        pendingByEventId.removeValue(forKey: eventId)
        return .complete
    }
}

/// Routes every SDK-authored event through the canonical EventLog → Journey lane.
final class EventLogSystemEventSink: SystemEventSink, @unchecked Sendable {
    private let events: any EventLogProtocol
    private let stableCaptureRetries: StableSystemEventCaptureRetryQueue

    init(events: any EventLogProtocol) {
        self.events = events
        stableCaptureRetries = StableSystemEventCaptureRetryQueue(events: events)
    }

    func emit(_ name: String, properties: [String: Any]?) {
        events.track(
            name,
            properties: properties,
            userProperties: nil,
            userPropertiesSetOnce: nil
        )
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
        await capture(request)
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

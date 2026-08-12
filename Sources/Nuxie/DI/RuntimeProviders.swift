import Foundation

/// Fire-and-forget entry point for SDK-authored events. Internal services use
/// this capability instead of reaching through the public singleton facade.
protocol SystemEventSink: AnyObject, Sendable {
    func emit(_ name: String, properties: [String: Any]?)
}

final class DiscardingSystemEventSink: SystemEventSink, Sendable {
    func emit(_ name: String, properties: [String: Any]?) {}
}

/// Routes internal events through the same trigger pipeline as `NuxieSDK.trigger`.
final class TriggerSystemEventSink: SystemEventSink, @unchecked Sendable {
    private let triggerProvider: @Sendable () -> TriggerServiceProtocol

    init(triggerProvider: @escaping @Sendable () -> TriggerServiceProtocol) {
        self.triggerProvider = triggerProvider
    }

    func emit(_ name: String, properties: [String: Any]?) {
        let properties = UncheckedSendable(properties)
        let trigger = triggerProvider()
        Task { @MainActor in
            await trigger.trigger(
                name,
                properties: properties.value,
                userProperties: nil,
                userPropertiesSetOnce: nil
            ) { _ in }
        }
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

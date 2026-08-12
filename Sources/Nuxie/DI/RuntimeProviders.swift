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

struct ConfigurationPurchaseSettingsProvider: PurchaseSettingsProviding {
    private let configuration: @Sendable () -> NuxieConfiguration

    init(configuration: @escaping @Sendable () -> NuxieConfiguration) {
        self.configuration = configuration
    }

    func purchaseDelegate() -> NuxiePurchaseDelegate? {
        configuration().purchaseDelegate
    }

    func purchaseHandlingMode() -> NuxieConfiguration.PurchaseHandlingMode {
        configuration().purchaseHandlingMode
    }
}

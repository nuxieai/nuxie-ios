import Foundation

/// Tracks automatic app lifecycle events ($app_installed, $app_updated,
/// $app_opened, $app_backgrounded).
///
/// Replaces the former plugin system's sole plugin (AppLifecyclePlugin);
/// invoked directly by NuxieLifecycleCoordinator. These events are always
/// captured; customers can drop them with `NuxieConfiguration.beforeSend`.
final class AppLifecycleTracker {

    private let userDefaults: UserDefaults
    private let appVersionProvider: () -> String
    private let dateProvider: () -> Date
    private let eventSink: SystemEventSink

    // Keys are unchanged from AppLifecyclePlugin so install/update state
    // persists across the migration.
    private let hasLaunchedBeforeKey = "nuxie_has_launched_before"
    private let lastVersionKey = "nuxie_last_version"

    init(
        userDefaults: UserDefaults = .standard,
        appVersionProvider: @escaping () -> String = AppLifecycleTracker.defaultAppVersion,
        dateProvider: @escaping () -> Date = Date.init,
        eventSink: SystemEventSink
    ) {
        self.userDefaults = userDefaults
        self.appVersionProvider = appVersionProvider
        self.dateProvider = dateProvider
        self.eventSink = eventSink
    }

    /// Track launch events: $app_installed on first launch, $app_updated on
    /// version change, and $app_opened always.
    func trackAppLaunchEvents() {
        let currentVersion = appVersionProvider()
        let hasLaunchedBefore = userDefaults.bool(forKey: hasLaunchedBeforeKey)
        let lastVersion = userDefaults.string(forKey: lastVersionKey)

        var properties: [String: Any] = [
            "source": "app_lifecycle",
            "app_version": currentVersion
        ]

        if !hasLaunchedBefore {
            properties["install_date"] = dateProvider().timeIntervalSince1970
            eventSink.emit(SystemEventNames.appInstalled, properties: properties)
            userDefaults.set(true, forKey: hasLaunchedBeforeKey)
            userDefaults.set(currentVersion, forKey: lastVersionKey)
        } else if let lastVersion, lastVersion != currentVersion {
            properties["previous_version"] = lastVersion
            properties["update_date"] = dateProvider().timeIntervalSince1970
            eventSink.emit(SystemEventNames.appUpdated, properties: properties)
            userDefaults.set(currentVersion, forKey: lastVersionKey)
        }

        properties["open_date"] = dateProvider().timeIntervalSince1970
        eventSink.emit(SystemEventNames.appOpened, properties: properties)
    }

    func trackAppBackgrounded() {
        eventSink.emit(
            SystemEventNames.appBackgrounded,
            properties: [
                "source": "app_lifecycle",
                "background_date": dateProvider().timeIntervalSince1970
            ]
        )
    }

    func trackAppForegrounded() {
        eventSink.emit(
            SystemEventNames.appOpened,
            properties: [
                "source": "app_lifecycle",
                "foreground_date": dateProvider().timeIntervalSince1970,
                "app_version": appVersionProvider()
            ]
        )
    }

    static func defaultAppVersion() -> String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
                return "\(version) (\(build))"
            }
            return version
        }
        return "unknown"
    }
}

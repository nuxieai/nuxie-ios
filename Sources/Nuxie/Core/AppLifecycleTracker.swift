import Foundation

/// Tracks automatic app lifecycle events ($app_installed, $app_updated,
/// $app_opened, $app_backgrounded).
///
/// Replaces the former plugin system's sole plugin (AppLifecyclePlugin);
/// invoked directly by NuxieLifecycleCoordinator. Disable via
/// `NuxieConfiguration.trackApplicationLifecycleEvents`.
final class AppLifecycleTracker {

    private let userDefaults: UserDefaults
    private let appVersionProvider: () -> String
    private let dateProvider: () -> Date
    private let emit: (String, [String: Any]) -> Void

    // Keys are unchanged from AppLifecyclePlugin so install/update state
    // persists across the migration.
    private let hasLaunchedBeforeKey = "nuxie_has_launched_before"
    private let lastVersionKey = "nuxie_last_version"

    init(
        userDefaults: UserDefaults = .standard,
        appVersionProvider: @escaping () -> String = AppLifecycleTracker.defaultAppVersion,
        dateProvider: @escaping () -> Date = Date.init,
        emit: @escaping (String, [String: Any]) -> Void = { name, properties in
            NuxieSDK.shared.trigger(name, properties: properties)
        }
    ) {
        self.userDefaults = userDefaults
        self.appVersionProvider = appVersionProvider
        self.dateProvider = dateProvider
        self.emit = emit
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
            emit("$app_installed", properties)
            userDefaults.set(true, forKey: hasLaunchedBeforeKey)
            userDefaults.set(currentVersion, forKey: lastVersionKey)
        } else if let lastVersion, lastVersion != currentVersion {
            properties["previous_version"] = lastVersion
            properties["update_date"] = dateProvider().timeIntervalSince1970
            emit("$app_updated", properties)
            userDefaults.set(currentVersion, forKey: lastVersionKey)
        }

        properties["open_date"] = dateProvider().timeIntervalSince1970
        emit("$app_opened", properties)
    }

    func trackAppBackgrounded() {
        emit(
            "$app_backgrounded",
            [
                "source": "app_lifecycle",
                "background_date": dateProvider().timeIntervalSince1970
            ]
        )
    }

    func trackAppForegrounded() {
        emit(
            "$app_opened",
            [
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

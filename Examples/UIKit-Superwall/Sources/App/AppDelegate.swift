//
//  AppDelegate.swift
//  MoodLog
//
//  App delegate demonstrating Nuxie SDK initialization with Superwall integration.
//

import UIKit
import Nuxie
import SuperwallKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        print("[MoodLog] App launching...")

        // MARK: - Superwall Setup

        /// **Step 1: Configure Superwall**
        /// Initialize Superwall before Nuxie SDK
        Superwall.configure(apiKey: "YOUR_SUPERWALL_API_KEY_HERE")
        print("[MoodLog] ✓ Superwall configured")

        // MARK: - Nuxie SDK Setup

        let config = NuxieConfiguration(apiKey: "pk_live_odfbiUwK7nhlzWBLk8vPwQly6hBLokibNl4eUzGrd097HjaXqIpB2ZbcMw3BeRJn1wIkmeGAxRsOa12jPnEL7WwPfEI5")

        #if DEBUG
        config.apiEndpoint = URL(string: "http://localhost:3000")!
        config.environment = .development
        config.logLevel = .debug
        config.enableConsoleLogging = true
        #else
        config.environment = .production
        config.logLevel = .warning
        config.enableConsoleLogging = false
        #endif

        config.eventBatchSize = 25

        /// Use NuxieSuperwall bridge to connect Nuxie flows to Superwall
        config.purchaseDelegate = NuxieSuperwallPurchaseDelegate()

        do {
            try NuxieSDK.shared.setup(with: config)
            print("[MoodLog] ✓ Nuxie SDK initialized successfully")
        } catch {
            print("[MoodLog] ✗ Nuxie SDK setup failed: \(error.localizedDescription)")
        }

        // MARK: - User Identification

        let userId = getUserId()
        NuxieSDK.shared.identify(userId)
        print("[MoodLog] User identified: \(userId)")

        print("[MoodLog] App launch complete")
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(
        _ application: UIApplication,
        didDiscardSceneSessions sceneSessions: Set<UISceneSession>
    ) {
    }

    private func getUserId() -> String {
        let userDefaults = UserDefaults.standard

        if let existingId = userDefaults.string(forKey: Constants.userIdKey) {
            return existingId
        }

        let newId = UUID().uuidString
        userDefaults.set(newId, forKey: Constants.userIdKey)
        return newId
    }
}

//
//  AppDelegate.swift
//  MoodLog
//
//  App delegate demonstrating Nuxie SDK initialization and configuration.
//  This is the primary integration point for the SDK.
//

import UIKit
import Nuxie
import RevenueCat

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {

        print("[MoodLog] App launching...")

        // MARK: - RevenueCat Setup

        /// **Step 1: Configure RevenueCat**
        /// Initialize RevenueCat before Nuxie SDK
        /// Replace with your actual RevenueCat API key from https://app.revenuecat.com
        Purchases.logLevel = .debug
        Purchases.configure(
            with: Configuration.Builder(withAPIKey: "YOUR_REVENUECAT_API_KEY_HERE")
                .with(storeKitVersion: .storeKit2)
                .build()
        )

        // Set up PurchasesDelegate to receive entitlement updates
        Purchases.shared.delegate = EntitlementManager.shared

        print("[MoodLog] ✓ RevenueCat configured")

        // MARK: - Nuxie SDK Setup

        /// **Step 1: Create Configuration**
        /// Replace "your_api_key_here" with your actual Nuxie API key from dashboard
        let config = NuxieConfiguration(apiKey: "pk_live_odfbiUwK7nhlzWBLk8vPwQly6hBLokibNl4eUzGrd097HjaXqIpB2ZbcMw3BeRJn1wIkmeGAxRsOa12jPnEL7WwPfEI5")

        /// **Step 2: Configure Environment**
        /// Use development for local qualification and production for releases.
        #if DEBUG
        config.environment = .development
        config.logLevel = .debug
        config.enableConsoleLogging = true
        #else
        config.environment = .production
        config.logLevel = .warning
        config.enableConsoleLogging = false
        #endif

        /// **Step 3: Configure Purchase Delegate**
        /// RevenueCat owns StoreKit finishing; Nuxie consumes outcomes.
        config.purchaseHandlingMode = .observer
        /// The adapter launches the exact StoreProduct retained by Nuxie.
        config.purchaseDelegate = NuxieRevenueCatPurchaseDelegate()

        /// **Step 4: Initialize SDK**
        do {
            try NuxieSDK.shared.setup(with: config)
            print("[MoodLog] ✓ Nuxie SDK initialized successfully")
        } catch {
            print("[MoodLog] ✗ Nuxie SDK setup failed: \(error.localizedDescription)")
        }

        // MARK: - User Identification

        /// **Step 6: Identify User**
        /// Create or retrieve a persistent user ID
        /// This allows Nuxie to track the user across sessions
        let userId = getUserId()
        NuxieSDK.shared.identify(userId)
        print("[MoodLog] User identified: \(userId)")

        // MARK: - Check Existing Purchases

        /// **Step 7: Sync RevenueCat Entitlements**
        /// RevenueCat automatically checks for active subscriptions
        /// EntitlementManager will receive updates via PurchasesDelegate
        Task {
            _ = try? await Purchases.shared.customerInfo()
            print("[MoodLog] Customer info synced")
        }

        // MARK: - App Lifecycle Events

        /// **Note: App lifecycle events are automatically tracked**
        /// Automatic lifecycle tracking (on by default) tracks:
        /// - $app_installed (first launch)
        /// - $app_updated (version changes)
        /// - $app_opened (every launch + foreground)
        /// - $app_backgrounded (when app goes to background)

        print("[MoodLog] App launch complete")
        return true
    }

    // MARK: - UISceneSession Lifecycle

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
        // Called when the user discards a scene session
    }

    // MARK: - Helper Methods

    /// Gets or creates a persistent user ID
    /// This ID is used to identify the user in Nuxie analytics
    private func getUserId() -> String {
        // Check if we already have a user ID
        if let existingId = UserDefaults.standard.string(forKey: Constants.userIdKey) {
            return existingId
        }

        // Create new UUID for this user
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: Constants.userIdKey)

        return newId
    }
}

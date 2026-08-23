//
//  MoodLogApp.swift
//  MoodLog
//
//  Main SwiftUI App entry point with Nuxie SDK initialization.
//  This demonstrates how to configure the Nuxie SDK in a SwiftUI app.
//

import SwiftUI
import Nuxie

/// **Nuxie SDK Integration: SwiftUI App Entry Point**
///
/// This is the main entry point for a SwiftUI app. The Nuxie SDK initialization
/// happens in the `init()` method, before the app's view hierarchy is created.
///
/// Key steps demonstrated here:
/// 1. SDK configuration and setup
/// 2. User identification with persistent UUID
/// 3. Environment object injection for state management
/// 4. StoreKit entitlement checking on launch
@main
struct MoodLogApp: App {

    // MARK: - State Management

    /// Global observable state for mood entries
    /// Injected into view hierarchy via `.environmentObject()`
    @StateObject private var moodStore = MoodStore.shared

    /// Global observable state for Pro subscription status
    @StateObject private var entitlementManager = EntitlementManager.shared

    /// Global observable state for StoreKit products
    @StateObject private var storeKitManager = StoreKitManager.shared

    // MARK: - Initialization

    /// Initialize app and configure Nuxie SDK
    ///
    /// **Nuxie Integration: SDK Setup**
    /// This is where you configure and initialize the Nuxie SDK.
    /// It happens once, before the app's UI is rendered.
    init() {
        setupNuxieSDK()
        identifyUser()
        checkExistingPurchases()
    }

    // MARK: - App Scene

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Inject observable services into view hierarchy
                // All child views can access these via @EnvironmentObject
                .environmentObject(moodStore)
                .environmentObject(entitlementManager)
                .environmentObject(storeKitManager)
        }
    }

    // MARK: - Nuxie SDK Setup

    /// **Step 1: Configure and Initialize Nuxie SDK**
    ///
    /// This method demonstrates the complete SDK setup process:
    /// 1. Create NuxieConfiguration with your API key
    /// 2. Configure optional settings (environment, log level, etc.)
    /// 3. Set purchase delegate for StoreKit integration
    /// 4. Call setup() to initialize the SDK
    private func setupNuxieSDK() {
        /// **Step 1: Create configuration with API key**
        /// Get your API key from https://nuxie.ai dashboard
        let config = NuxieConfiguration(apiKey: "your_api_key_here")

        /// **Step 2: Set environment (optional)**
        /// Use .development for testing, .production for release builds
        config.environment = .development

        /// **Step 3: Set log level (optional)**
        /// .debug shows detailed SDK logs, helpful during development
        config.logLevel = .debug

        /// **Step 4: Configure Purchase Delegate**
        /// This connects Nuxie's flow system to your StoreKit implementation
        /// When users complete purchases through Nuxie flows, this delegate handles the transaction
        config.purchaseDelegate = StoreKitManager.shared

        /// **Step 5: Initialize SDK**
        /// This must be called before using any other Nuxie SDK methods
        do {
            try NuxieSDK.shared.setup(with: config)
            print("[MoodLog] Nuxie SDK initialized successfully")
        } catch {
            print("[MoodLog] Failed to initialize Nuxie SDK: \(error)")
        }
    }

    /// **Step 2: Identify User**
    ///
    /// User identification allows Nuxie to:
    /// - Track events for specific users
    /// - Segment users for targeted experiences
    /// - Show personalized flows based on user behavior
    ///
    /// We use a persistent UUID stored in UserDefaults so the same user
    /// is identified across app launches.
    private func identifyUser() {
        // Get or create persistent user ID
        let userId = getUserId()

        /// **Nuxie Integration: User Identification**
        /// Call this once on app launch after SDK setup
        /// You can also pass custom user properties as a second parameter
        NuxieSDK.shared.identify(
            userId,
            userProperties: [
                "app_version": Constants.appVersion,
                "platform": "iOS"
            ]
        )

        print("[MoodLog] User identified: \(userId)")
    }

    /// **Step 3: Check Existing Purchases**
    ///
    /// On app launch, check if the user has any existing StoreKit entitlements.
    /// This ensures Pro status is restored even after app reinstall (if they
    /// previously purchased).
    private func checkExistingPurchases() {
        Task {
            await storeKitManager.checkForExistingEntitlements()
        }
    }

    // MARK: - User ID Management

    /// Gets or creates a persistent user UUID
    /// - Returns: User UUID string
    private func getUserId() -> String {
        let userDefaults = UserDefaults.standard

        if let existingId = userDefaults.string(forKey: Constants.userIdKey) {
            return existingId
        }

        // Create new UUID
        let newId = UUID().uuidString
        userDefaults.set(newId, forKey: Constants.userIdKey)
        return newId
    }
}

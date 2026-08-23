# MoodLog — Nuxie iOS SDK SwiftUI Example App

A simple, beautiful daily mood tracker demonstrating best practices for integrating the Nuxie iOS SDK with **SwiftUI**.

## Overview

MoodLog is a production-quality SwiftUI example app showing how to:

- ✅ Initialize and configure the Nuxie SDK
- ✅ Track user events throughout the app lifecycle
- ✅ Implement user identification
- ✅ Integrate StoreKit 2 with Nuxie's purchase tracking
- ✅ Build event-driven flows (no hardcoded paywalls!)
- ✅ Handle entitlements and feature gating
- ✅ Implement offline-first data persistence
- ✅ Use SwiftUI state management with ObservableObject
- ✅ Leverage Environment Objects for dependency injection

## Features

### Core Functionality
- **Daily mood tracking** with 5 emoji options (😞 😐 🙂 😄 🤩)
- **Optional notes** for each mood entry (140 character limit)
- **Streak tracking** showing consecutive days logged
- **7-day history** for free users
- **Unlimited history** for Pro users

### Monetization
- **In-app purchase** for Pro upgrade
- **CSV export** (Pro feature)
- **Custom themes** (Pro feature, optional)
- **Purchase restoration** for existing Pro users

## Architecture

### SwiftUI Patterns

This example demonstrates modern SwiftUI architecture:

- **ObservableObject Services**: MoodStore, EntitlementManager, and StoreKitManager are all observable
- **Environment Injection**: Services injected via `.environmentObject()`
- **Declarative UI**: All views built with SwiftUI's declarative syntax
- **Async/Await**: Native async StoreKit 2 integration
- **Custom ViewModifiers**: Reusable styling and animations
- **ShareSheet Wrapper**: UIKit interop for CSV export (iOS 15 compatible)

### Data Layer
- **UserDefaults-backed storage** — No backend required
- **MoodStore** — ObservableObject singleton managing all mood entries
- **EntitlementManager** — ObservableObject tracking Pro subscription status
- **StoreKitManager** — ObservableObject handling purchases and implementing `NuxiePurchaseDelegate`

### UI Layer (SwiftUI)
- **ContentView** — TabView container for main navigation
- **TodayView** — Main mood entry screen
- **HistoryView** — List of past mood entries
- **Custom components** — MoodButton, StreakView, HistoryRow
- **ShareSheet** — UIActivityViewController wrapper for CSV export

### Nuxie Integration Points

#### 1. SDK Initialization (MoodLogApp.swift)
```swift
@main
struct MoodLogApp: App {
    init() {
        setupNuxieSDK()
    }

    private func setupNuxieSDK() {
        let config = NuxieConfiguration(apiKey: "your_api_key")
        config.environment = .development
        config.logLevel = .debug
        config.purchaseDelegate = StoreKitManager.shared

        try? NuxieSDK.shared.setup(with: config)
    }
}
```

#### 2. User Identification (MoodLogApp.swift)
```swift
// Identify user with persistent UUID
NuxieSDK.shared.identify(userId)
```

#### 3. Event-Driven Flows with Nuxie

**This is the key feature demonstrated in this app!**

Instead of hardcoding when/where to show paywalls, MoodLog uses Nuxie's **flow system** where the backend decides when to show upgrade prompts based on user behavior.

**How it works in SwiftUI:**

```swift
// User taps "Go Pro" button
Button("Go Pro") {
    NuxieSDK.shared.trigger("upgrade_tapped", properties: [
        "source": "today_screen",
        "current_streak": moodStore.calculateStreak()
    ]) { update in
        handleTriggerUpdate(update)
    }
}
.buttonStyle(.borderedProminent)

func handleTriggerUpdate(_ update: TriggerUpdate) {
    switch update {
    case .featureAccess(.allowed):
        // Feature access is allowed.
        break
    case .decision(.noMatch):
        break
    case .error(let error):
        print("Trigger failed: \(error.message)")
    default:
        break
    }
}
```

**Key Events:**

| Event | Triggered When | Properties Tracked | Use Case |
|-------|---------------|-------------------|----------|
| `mood_selected` | User taps mood emoji | `mood`, `mood_emoji`, `mood_label`, `has_existing_entry`, `current_streak` | Understand engagement, identify drop-off points |
| `mood_saved` | User saves mood entry | `mood`, `mood_emoji`, `has_note`, `note_length`, `is_update`, `streak`, `total_entries` | Core engagement metric, conversion opportunities |
| `upgrade_tapped` | "Go Pro" button tapped | `source`, `current_streak`, `total_entries` | Primary upgrade CTA (triggers flow) |
| `unlock_history_tapped` | User wants unlimited history | `visible_entries`, `total_entries`, `source` | Feature-gated upsell (triggers flow) |
| `csv_export_gated` | User tries Pro feature without access | `entry_count`, `source` | Just-in-time conversion (triggers flow) |
| `csv_export_completed` | User exports CSV (Pro) | `entry_count` | Pro feature usage tracking |
| `history_viewed` | History screen opens | `entry_count`, `is_pro` | Navigation and engagement tracking |

**Event Funnel Example:**

```
User opens app
  → mood_selected (engagement)
    → mood_saved (core action)
      → [After 5 days] upgrade_tapped
        → [Nuxie Flow Shown]
          → purchase completed → User is now Pro!
```

**Why this approach is powerful:**

1. **Backend-Configurable**: Change when/how flows show without releasing app updates
2. **Frequency Capping**: Nuxie handles not annoying users with too many prompts
3. **A/B Testing**: Test different flow designs and triggers from dashboard
4. **Targeting**: Show flows based on user segments, behavior patterns, etc.
5. **Analytics**: Track conversion funnels automatically
6. **Funnel Analysis**: See drop-off rates (selected mood but didn't save, saw upgrade but didn't purchase, etc.)

#### 4. StoreKit Integration
The included `StoreKitManager` purchases `product.rawProduct` with the exact
checkout options and reports only `.purchased`, `.pending`, `.cancelled`, or
`.failed`. Restore reports `.restored`, `.noPurchases`, or `.failed`. Nuxie's
StoreKit listener records, syncs, and finishes verified native transactions;
the delegate never transports receipts or finish closures.

```swift
config.purchaseDelegate = StoreKitManager.shared
```

#### 5. SwiftUI State Management
```swift
// Inject observable services via environment
@main
struct MoodLogApp: App {
    @StateObject private var moodStore = MoodStore.shared
    @StateObject private var entitlementManager = EntitlementManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(moodStore)
                .environmentObject(entitlementManager)
        }
    }
}

// Access in views
struct TodayView: View {
    @EnvironmentObject var moodStore: MoodStore
    @EnvironmentObject var entitlementManager: EntitlementManager

    var body: some View {
        // Use moodStore.entries, entitlementManager.isProUser
    }
}
```

## Building & Running

### Prerequisites
- Xcode 15.0+
- iOS 15.0+ device or simulator
- Nuxie API key (get one at [nuxie.ai](https://nuxie.ai))

### Setup

1. **Generate Xcode project**
   ```bash
   cd Examples/SwiftUI
   xcodegen generate
   ```

2. **Configure API Key**

   Edit `Sources/App/MoodLogApp.swift` and replace `"your_api_key_here"` with your actual Nuxie API key.

3. **Configure StoreKit (Optional)**

   To test in-app purchases:
   - Create products in App Store Connect
   - Update product IDs in `Constants.swift`
   - Add StoreKit configuration file for testing

4. **Run**
   ```bash
   open MoodLog.xcodeproj
   # Build and run in Xcode (Cmd+R)
   ```

## Setting Up Nuxie Experiences

The app is fully functional without any dashboard configuration, but to see Nuxie's flow system in action, you'll want to create experiences:

### 1. Create Your First Experience

1. Log into your Nuxie dashboard
2. Navigate to **Experiences** → **Create Experience**
3. Set trigger event: `upgrade_tapped`
4. Choose audience: "All Users" (for testing)

### 2. Design Your Flow

1. Select **Flow Type**: Paywall
2. Add your products (monthly/yearly subscriptions)
3. Customize design:
   - Headline: "Unlock Pro Features"
   - Benefits: Unlimited history, CSV export, themes
   - CTA button: "Start Free Trial" or "Subscribe"

### 3. Configure Behavior

- **Frequency Capping**: Show max once per day (avoid annoying users)
- **Priority**: High (for primary CTA)
- **Start Date**: Now

### 4. Test in the App

1. Run the app
2. Tap "Go Pro" button
3. Your configured flow should appear!
4. Complete purchase → app receives a verified purchase outcome

### 5. Create Additional Experiences

**Feature Gate Example** (CSV Export):
- **Trigger**: `csv_export_gated`
- **Audience**: Non-Pro users
- **Message**: "CSV export is a Pro feature"
- **Frequency**: Once per week

**Soft Paywall Example** (History):
- **Trigger**: `unlock_history_tapped`
- **Flow**: Show benefits before paywall
- **Frequency**: Twice per month

### Tips

- **Start Simple**: One experience for `upgrade_tapped` is enough to start
- **Monitor Analytics**: Check conversion rates in dashboard
- **Iterate**: Try different messaging and timing without app updates
- **Test Frequency**: Use "Preview Mode" to bypass frequency limits during development

## Project Structure

```
Sources/
├── App/
│   ├── MoodLogApp.swift         # App entry point with SDK initialization
│   └── Info.plist               # App configuration
├── Views/
│   ├── ContentView.swift        # TabView container
│   ├── TodayView.swift          # Main mood entry screen with Nuxie flows
│   ├── HistoryView.swift        # Past moods list with feature gating
│   └── Components/
│       ├── MoodButton.swift     # Custom emoji button
│       ├── StreakView.swift     # Animated streak display
│       ├── HistoryRow.swift     # List row view
│       └── ShareSheet.swift     # UIActivityViewController wrapper
├── Models/
│   ├── MoodEntry.swift          # Data model for mood entries
│   └── Theme.swift              # Theme model (Pro feature)
├── Services/
│   ├── MoodStore.swift          # UserDefaults persistence (ObservableObject)
│   ├── StoreKitManager.swift    # Purchase handling + NuxiePurchaseDelegate
│   └── EntitlementManager.swift # Pro status tracking (ObservableObject)
├── Helpers/
│   ├── Constants.swift          # App-wide constants
│   ├── DateHelper.swift         # Date formatting utilities
│   ├── Color+Theme.swift        # Custom color palette
│   └── ViewModifiers.swift      # Custom view modifiers
└── Resources/
    └── Assets.xcassets/         # Colors, images
```

## Code Highlights

### SwiftUI Best Practices
Every file demonstrates:
- **ObservableObject pattern** for state management
- **Environment injection** for dependency management
- **Declarative UI** with SwiftUI views
- **Custom ViewModifiers** for reusable styling
- **Inline documentation** for Nuxie integration points
- **Production-quality error handling**

### Modern SwiftUI Patterns
- Declarative view syntax
- @StateObject and @EnvironmentObject
- Task {} for async operations (StoreKit, async trigger streams)
- Custom ButtonStyles and ViewModifiers
- ShareSheet wrapper for UIKit interop
- Dark mode support with dynamic colors

### Offline-First
- All mood data stored locally in UserDefaults
- No network required for core functionality
- Async event sync happens in background

## Key Learnings

This example demonstrates:

1. **SDK Setup**: One-time configuration in App init
2. **Event Tracking**: Strategic placement of trigger() calls in SwiftUI views
3. **User Identification**: Persistent UUID for user continuity
4. **Purchase Integration**: Proper delegate pattern implementation
5. **Feature Gating**: Simple entitlement checks before Pro features
6. **Error Handling**: Graceful degradation when SDK unavailable
7. **SwiftUI State**: ObservableObject pattern for reactive UI updates
8. **Environment Objects**: Clean dependency injection in SwiftUI

## SwiftUI vs UIKit

This is the **SwiftUI version** of the MoodLog example. For the **UIKit version**, see `Examples/UIKit/`.

**Key Differences:**
- **State Management**: ObservableObject + @Published vs NotificationCenter
- **Navigation**: TabView + NavigationView vs UITabBarController
- **Views**: Declarative SwiftUI vs Imperative UIKit
- **Animations**: .animation() vs UIView.animate
- **Dependency Injection**: @EnvironmentObject vs manual passing

**Same Functionality:**
- Identical event tracking
- Same Nuxie SDK integration
- Same StoreKit 2 implementation
- Same feature gating logic
- Same offline-first architecture

## Next Steps

To build your own SwiftUI app with Nuxie:

1. **Copy patterns** from this example (especially MoodLogApp setup)
2. **Define your events** based on user actions in your app
3. **Implement purchase delegate** if you have IAP
4. **Configure experiences** in the Nuxie dashboard
5. **Test event tracking** in development mode

## Support

- **Nuxie Documentation**: [nuxie.ai/docs](https://nuxie.ai/docs)
- **SDK Reference**: [github.com/nuxie-io/nuxie-ios](https://github.com/nuxie-io/nuxie-ios)
- **Issues**: [github.com/nuxie-io/nuxie-ios/issues](https://github.com/nuxie-io/nuxie-ios/issues)

## License

MIT License — See LICENSE file for details

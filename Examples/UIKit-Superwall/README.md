# MoodLog — Nuxie iOS SDK Example App

A simple, beautiful daily mood tracker demonstrating best practices for integrating the Nuxie iOS SDK.

## Overview

MoodLog is a production-quality example app showing how to:

- ✅ Initialize and configure the Nuxie SDK
- ✅ Track user events throughout the app lifecycle
- ✅ Implement user identification
- ✅ Integrate StoreKit 2 with Nuxie's purchase tracking
- ✅ Build a paywall with conversion tracking
- ✅ Handle entitlements and feature gating
- ✅ Implement offline-first data persistence

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

### Data Layer
- **UserDefaults-backed storage** — No backend required
- **MoodStore** — Singleton managing all mood entries
- **EntitlementManager** — Tracks Pro subscription status
- **StoreKitManager** — Handles purchases and implements `NuxiePurchaseDelegate`

### UI Layer (UIKit)
- **TodayViewController** — Main mood entry screen
- **HistoryViewController** — List of past mood entries
- **PaywallViewController** — Pro upgrade screen with StoreKit integration
- **Custom views** — MoodButton, StreakView, HistoryCell

### Nuxie Integration Points

#### 1. SDK Initialization (AppDelegate)
```swift
let config = NuxieConfiguration(apiKey: "your_api_key")
config.apiEndpoint = URL(string: "http://localhost:3000")!
config.environment = .development
config.logLevel = .debug

try NuxieSDK.shared.setup(with: config)
```

#### 2. User Identification (AppDelegate)
```swift
// Identify user with persistent UUID
NuxieSDK.shared.identify(userId)
```

#### 3. Event-Driven Paywalls with Nuxie Flows

**This is the key feature demonstrated in this app!**

Instead of hardcoding when/where to show paywalls, MoodLog uses Nuxie's **flow system** where the backend decides when to show upgrade prompts based on user behavior.

**How it works:**

```swift
// User taps "Go Pro" button
NuxieSDK.shared.trigger("upgrade_tapped", properties: [
    "source": "today_screen",
    "current_streak": streak
]) { update in
    switch update {
    case .entitlement(.allowed):
        unlockProFeatures()
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
          → .purchased → User is now Pro!
```

**Why this approach is powerful:**

1. **Backend-Configurable**: Change when/how paywalls show without releasing app updates
2. **Frequency Capping**: Nuxie handles not annoying users with too many prompts
3. **A/B Testing**: Test different paywall designs and triggers from dashboard
4. **Targeting**: Show flows based on user segments, behavior patterns, etc.
5. **Analytics**: Track conversion funnels automatically
6. **Funnel Analysis**: See drop-off rates (selected mood but didn't save, saw upgrade but didn't purchase, etc.)

#### 4. StoreKit Integration
```swift
let options = SuperwallOptions()
options.shouldObservePurchases = true
Superwall.configure(apiKey: "YOUR_SUPERWALL_API_KEY", options: options)

// The adapter applies Nuxie's exact StoreKit options. Superwall observes the
// transaction and remains the source for its own entitlement status.
config.purchaseDelegate = NuxieSuperwallPurchaseDelegate()
```

## Building & Running

### Prerequisites
- Xcode 15.0+
- iOS 15.0+ device or simulator
- Nuxie API key (get one at [nuxie.ai](https://nuxie.ai))

### Setup

1. **Generate Xcode project**
   ```bash
   cd Examples/UIKit
   xcodegen generate
   ```

2. **Configure API Key**

   Edit `Sources/App/AppDelegate.swift` and replace `"your_api_key_here"` with your actual Nuxie API key.

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

### 2. Design Your Paywall Flow

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
4. Complete purchase → app receives `.purchased` outcome

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
│   ├── AppDelegate.swift          # SDK initialization, user identification
│   ├── SceneDelegate.swift        # Window setup
│   └── Info.plist                 # App configuration
├── ViewControllers/
│   ├── TodayViewController.swift  # Main mood entry screen with Nuxie flow integration
│   └── HistoryViewController.swift # Past moods list with feature gating
├── Views/
│   ├── MoodButton.swift           # Custom emoji button with animations
│   ├── HistoryCell.swift          # Table cell for mood entries
│   └── StreakView.swift           # Animated streak display
├── Models/
│   ├── MoodEntry.swift            # Data model for mood entries
│   ├── MoodStore.swift            # UserDefaults persistence layer
│   └── Theme.swift                # Theme model (Pro feature)
├── Services/
│   ├── StoreKitManager.swift      # Purchase handling + NuxiePurchaseDelegate
│   └── EntitlementManager.swift   # Pro status tracking
├── Helpers/
│   ├── Constants.swift            # App-wide constants
│   ├── DateHelper.swift           # Date formatting utilities
│   ├── UIColor+Theme.swift        # Custom color palette
│   └── UIView+Extensions.swift    # UI convenience methods
└── Resources/
    ├── Assets.xcassets/          # Colors, images
    └── LaunchScreen.storyboard    # Launch screen
```

## Code Highlights

### Clean, Documented Code
Every file includes:
- Header comments explaining purpose
- Inline documentation for Nuxie integration points
- Clear separation of concerns
- Production-quality error handling

### Modern UIKit Patterns
- Programmatic UI (no storyboards except LaunchScreen)
- Proper auto layout with anchors
- Smooth animations and haptic feedback
- Dark mode support

### Offline-First
- All mood data stored locally in UserDefaults
- No network required for core functionality
- Async event sync happens in background

## Key Learnings

This example demonstrates:

1. **SDK Setup**: One-time configuration in AppDelegate
2. **Event Tracking**: Strategic placement of trigger() calls
3. **User Identification**: Persistent UUID for user continuity
4. **Purchase Integration**: Proper delegate pattern implementation
5. **Feature Gating**: Simple entitlement checks before Pro features
6. **Error Handling**: Graceful degradation when SDK unavailable

## Next Steps

To build your own app with Nuxie:

1. **Copy patterns** from this example (especially AppDelegate setup)
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

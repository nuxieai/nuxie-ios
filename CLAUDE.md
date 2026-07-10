# CLAUDE.md - Nuxie iOS SDK

This file provides guidance to Claude Code when working on the Nuxie iOS SDK.

## Project Structure

```
packages/nuxie-ios/
├── Sources/Nuxie/          # Main SDK source code
│   ├── NuxieSDK.swift      # Main singleton class
│   ├── NuxieConfiguration.swift  # Configuration classes
│   ├── NuxieError.swift    # Error types
│   ├── TriggerModels.swift # Trigger update models
│   ├── SDKVersion.swift    # Version constant
│   ├── DI/                # Dependency injection
│   │   └── DIContainer.swift  # Service container
│   ├── Storage/           # Event storage system
│   │   ├── StoredEvent.swift   # Event data model
│   │   ├── EventStore.swift    # SQLite storage layer
│   │   └── EventStoreManager.swift # Business logic layer
│   ├── Plugins/           # Plugin system
│   │   ├── NuxiePlugin.swift  # Plugin protocol
│   │   ├── PluginManager.swift # Plugin lifecycle manager
│   │   └── AppLifecyclePlugin.swift # Built-in app lifecycle plugin
│   ├── Managers/          # Business logic managers
│   │   └── FlowManager.swift   # Workflow management
│   ├── Network/           # API client and networking
│   │   ├── NuxieApi.swift  # Main API client
│   │   ├── APIEndpoint.swift  # Endpoint definitions
│   │   ├── NuxieNetworkError.swift  # Network errors
│   │   └── Models/        # Request/response models
│   └── Extensions/        # Swift extensions
├── Tests/NuxieUnitTests/        # Unit tests (Quick/Nimble)
├── Tests/NuxieIntegrationTests/ # Integration tests
├── Tests/NuxieE2ETests/         # End-to-end tests (WebKit/UI)
├── Tests/NuxieTestSupport/      # Shared mocks + utilities
├── Examples/DemoApp/      # Example iOS app
└── Package.swift          # Swift Package Manager config
```

## Core Design Principles

1. **Event-Centric API**: The primary SDK interface is the `trigger()` method which handles both local storage and remote tracking
2. **Offline-First Architecture**: Events persist locally immediately, remote sync is asynchronous 
3. **Dependency Injection**: Services managed through `DIContainer` for testability and clean architecture
4. **Plugin Architecture**: Extensible plugin system for modular functionality
5. **Configuration-First**: SDK must be configured with `setup(with:)` before use
6. **Type Safety**: Strong typing throughout with proper Swift enums and structs
7. **Thread Safety**: SQLite operations with proper queue management and locking

## Key Implementation Rules

- **Never run swift build**, the nuxie-ios sdk is ios only and swift build will build it for macos

### API Design
- **Single Entry Point**: `NuxieSDK.shared` singleton pattern
- **Setup Required**: Always check `isSetup` before operations, use `isEnabled()` helper for graceful degradation
- **Trigger-First**: Primary method is `trigger()` for event recording and feature gating
- **Immutable Config**: `NuxieConfiguration` properties are `let` where possible

### Dependency Injection
- **DIContainer**: All services registered and resolved through `DIContainer.shared`
- **DIManaged Protocol**: Services conform to `DIManaged` for parameterless initialization
- **Singleton Services**: EventStoreManager, PluginManager, and FlowManager registered as singletons
- **Service Resolution**: Use `resolveOptional()` for graceful degradation

### Plugin Architecture
- **Simple Interface**: Plugins implement `NuxiePlugin` with install/uninstall/start/stop methods
- **SDK Reference**: Plugins receive SDK singleton reference on installation
- **Thread Safety**: PluginManager uses concurrent queue for thread-safe access
- **Configuration-Based**: Plugins are defined in `NuxieConfiguration` and auto-installed during SDK setup
- **Default Plugins**: AppLifecyclePlugin is included by default but can be removed if needed

### Event Storage Architecture
- **SQLite Backend**: Local database with proper indexing and thread safety
- **Three-Layer Design**: StoredEvent (model) → EventStore (database) → EventStoreManager (business logic)
- **Automatic Enrichment**: Device info, SDK version, platform metadata added automatically
- **Session Management**: Automatic session tracking with unique identifiers
- **Cleanup Policies**: Configurable retention based on count and age limits

### Network Layer
- **Gzip Compression**: All requests use gzip compression
- **Type-Safe Models**: Use `AnyCodable` for flexible JSON handling
- **Error Propagation**: Network errors wrapped in `NuxieError.networkError`
- **Async Operations**: All network calls use async/await

### Code Style
- **Swift Conventions**: Follow standard Swift naming and patterns
- **Documentation**: Public APIs have proper doc comments
- **Error Messages**: Clear, actionable error descriptions
- **Logging**: Use `print("[Nuxie] ...")` for debugging output

### Testing Framework
- **Quick 7+/Nimble 13+**: Modern BDD-style testing with async/await support
- **AsyncSpec**: Use `AsyncSpec` as base class for tests requiring async operations
- **Test Isolation**: Each test uses unique database paths for clean separation
- **Comprehensive Coverage**: All storage operations, DI resolution, and business logic tested
- **Foundation Import**: Always import `Foundation` in test files for system types

## API Endpoints

Currently implemented:
- `POST /profile` - Get campaigns, segments, and flows with flow execution data
- `POST /event` - Track events

Authentication: API key in request body for all POST endpoints.

### Profile Response Structure
The `/profile` endpoint now returns campaign-centric data optimized for client-side execution:
- `campaigns`: Array of `Campaign` objects with flattened current version data and flow execution graphs
- `segments`: Array of `Segment` objects with compiled CEL expressions for client-side evaluation  
- `flows`: Array of `FlowManifest` objects with build URLs and product information

## Development Workflow

### Adding New Managers/Services
1. Create manager class conforming to `DIManaged` protocol
2. Register service in `NuxieSDK.setup()` with `diContainer.registerSingleton()`
3. Access via `diContainer.resolveOptional()` throughout codebase
4. Add initialization logic after registration
5. Include cleanup in `shutdown()` method

### Adding Event Storage Features
1. Extend `StoredEvent` model if new fields needed
2. Update `EventStore` for new database operations (with migrations if needed)
3. Add business logic to `EventStoreManager`
4. Expose through `NuxieSDK` internal methods for flow evaluation
5. Add comprehensive tests covering all layers

### Error Handling
- Use `EventStorageError` for storage-related errors
- Use `NuxieError` enum for SDK-level errors
- Network errors should be wrapped: `throw NuxieError.networkError(originalError)`
- Always provide descriptive error messages
- Use `isEnabled()` helper method for graceful error handling without crashes

### Testing Workflow

#### Writing Async Tests with Quick 7+ and Nimble 13+

1. **Use AsyncSpec for async tests**:
```swift
import Quick
import Nimble
@testable import Nuxie

final class MyTests: AsyncSpec {
    override class func spec() {
        describe("feature") {
            it("should work") {
                // Async code runs directly in test context
                let result = await api.fetchData()
                expect(result).to(equal(expectedValue))
            }
        }
    }
}
```

2. **Async expectations with actors/async functions**:
```swift
// For async/actor-isolated properties or methods
await expect { await actor.property }.to(equal(value))
await expect { await asyncFunction() }.to(equal(expectedResult))

// For throwing async functions
await expect { try await api.fetchUser(id: -1) }
    .to(throwError(UserError.notFound))
```

3. **Polling with toEventually**:
```swift
// Poll for eventually-true conditions
await expect { await viewModel.isReady }
    .toEventually(beTrue(), timeout: .seconds(2))

// Poll async expressions (Nimble 12+)
await expect { await actor.counter() }
    .toEventually(equal(2), timeout: .seconds(1))
```

4. **Mock actors for thread-safe testing**:
```swift
actor MockAPI: APIProtocol {
    private(set) var callCount = 0
    
    func fetch() async throws -> Data {
        callCount += 1
        return testData
    }
}
```

5. **Test structure best practices**:
- Use custom database paths for EventStoreManager tests
- Test both success and failure scenarios
- Verify DI container service resolution
- Run unit tests with `make test` (or `make test-unit`)

## Configuration Management

### Environment Setup
```swift
let config = NuxieConfiguration(apiKey: "your_key")
config.environment = .development  // Updates endpoint automatically
config.logLevel = .debug
try NuxieSDK.shared.setup(with: config)
```

### Key Configuration Properties
- `apiKey`: Required authentication
- `environment`: Automatically sets correct endpoint
- `logLevel`: Controls verbosity
- `enableCompression`: Gzip on/off (default: true)
- `syncInterval`: Background sync frequency
- `eventBatchSize`: Events per batch upload
- `enablePlugins`: Enable/disable plugin system (default: true)
- `plugins`: Array of plugins to install during SDK setup (includes AppLifecyclePlugin by default)

## Common Patterns

### Event Tracking with Local Storage
```swift
// Events are stored locally immediately and synced remotely async
NuxieSDK.shared.trigger("app_launched", properties: [
    "version": "1.0.0",
    "platform": "ios"
]) { result in
    switch result {
    case .granted: /* user has access */
    case .denied: /* show upgrade prompt */  
    case .paywallShown(let id): /* paywall displayed */
    case .continue: /* normal event tracking */
    }
}
```

### Plugin Configuration
```swift
// Configure plugins during SDK setup
let config = NuxieConfiguration(apiKey: "your-key")

// AppLifecyclePlugin is included by default
// Add additional plugins:
config.addPlugin(MyCustomPlugin())

// Remove default plugins if needed:
config.removePlugin("app-lifecycle")

// Setup SDK - plugins will be auto-installed
try NuxieSDK.shared.setup(with: config)
```

### Runtime Plugin Management
```swift
// Manual plugin management after SDK setup
let plugin = MyCustomPlugin()
try NuxieSDK.shared.installPlugin(plugin)
NuxieSDK.shared.startPlugin(plugin.pluginId)

// Check plugin status
let isInstalled = NuxieSDK.shared.isPluginInstalled("my-custom-plugin")

// Stop and uninstall a plugin
NuxieSDK.shared.stopPlugin("my-custom-plugin")
try NuxieSDK.shared.uninstallPlugin("my-custom-plugin")
```

### Creating Custom Plugins
```swift
public class MyCustomPlugin: NSObject, NuxiePlugin {
    public let pluginId = "my-custom-plugin"
    
    private weak var sdk: NuxieSDK?
    private var isStarted = false
    
    public func install(sdk: NuxieSDK) {
        self.sdk = sdk
        print("MyCustomPlugin installed")
    }
    
    public func uninstall() {
        stop()
        sdk = nil
        print("MyCustomPlugin uninstalled")
    }
    
    public func start() {
        guard !isStarted else { return }
        isStarted = true
        // Start plugin functionality
        print("MyCustomPlugin started")
    }
    
    public func stop() {
        guard isStarted else { return }
        isStarted = false
        // Stop plugin functionality
        print("MyCustomPlugin stopped")
    }
}
```

### Session Management
```swift
// Start new session (typically on app launch)
NuxieSDK.shared.startNewSession()

// User identification with automatic session creation
NuxieSDK.shared.identify(userId: "user123", attributes: [
    "subscription": "premium",
    "region": "US"
])
```

### Service Resolution via DI Container
```swift
// Internal SDK usage - accessing registered services
guard let eventStoreManager = diContainer.resolveOptional(EventStoreManager.self) else {
    print("[Nuxie] Event storage not available")
    return
}

try eventStoreManager.storeEvent(name: "test", properties: [:])
```

### Event History Access (Internal)
```swift
// Get recent events for flow evaluation
let recentEvents = NuxieSDK.shared.getRecentEvents(limit: 50)
let userEvents = NuxieSDK.shared.getCurrentUserEvents(limit: 100)
let sessionEvents = NuxieSDK.shared.getCurrentSessionEvents()
```

## App Lifecycle Events

The AppLifecyclePlugin automatically tracks these key events:

### **$app_installed**
- Triggered on the very first launch of the app
- Properties: `install_date`, `app_version`, `source`
- Used to identify new users and measure app adoption

### **$app_updated** 
- Triggered when the app launches with a different version than the last launch
- Properties: `previous_version`, `app_version`, `update_date`, `source`  
- Used to track version adoption and update success rates

### **$app_opened**
- Triggered every time the app opens (including first launch and after updates)
- Also triggered when returning from background to foreground
- Properties: `open_date`, `app_version`, `source`
- Used to measure app engagement and session frequency

### **$app_backgrounded**
- Triggered when the app moves to the background
- Properties: `background_date`, `source`
- Used to measure session duration and app usage patterns

All events include version information (CFBundleShortVersionString + CFBundleVersion) and are automatically tracked with no additional code required.

## Current Implementation Status

### ✅ Completed Features
- **Event Storage System**: Complete SQLite-based local storage with threading and cleanup
- **Dependency Injection**: DIContainer managing all services as singletons
- **Plugin System**: Simple install/uninstall/start/stop plugin architecture
- **App Lifecycle Plugin**: Auto-installed plugin tracking App Installed, App Updated, App Opened, App Backgrounded
- **Event Tracking**: Full `trigger()` implementation with local storage + remote sync
- **Campaign-Centric API**: Updated `/profile` endpoint response models to support new flow-based campaigns
- **Session Management**: Automatic session tracking with unique identifiers
- **User Management**: User identification, attribution, and event filtering
- **Test Suite**: Comprehensive Quick/Nimble tests covering all functionality
- **Error Handling**: Graceful degradation and proper error propagation
- **Device Enrichment**: Automatic metadata injection (device, OS, SDK version)

### 🚧 Next Phase Implementation
- **Workflow Evaluation Engine**: Rule engine for processing campaigns against event history
- **Campaign Management**: Enhanced FlowManager for flow processing and caching
- **Feature Gating Logic**: Real paywall/feature access decisions based on rules
- **Background Sync**: Event queue with batching and offline resilience

### 📋 Future Roadmap
- **WebView Paywall Presentation**: Modal paywall display system
- **StoreKit Integration**: Purchase processing and receipt validation
- **Migration System**: Database schema versioning and migration handling
- **Advanced Analytics**: Event aggregation and real-time metrics
- **Push Notifications**: Campaign-triggered messaging system

## Architecture Deep Dive

### Event Storage Flow
```
trigger() → EventStoreManager → EventStore → SQLite Database
   ↓            ↓                 ↓
Remote API   Enrichment       Indexing
(async)      (metadata)      (performance)
```

### Dependency Injection Flow
```
SDK.setup() → DIContainer.registerSingleton() → Service Creation
     ↓              ↓                              ↓
Service Use → resolveOptional() → Singleton Instance
```

### Data Models
- **StoredEvent**: JSON-serialized properties, indexed by timestamp/user/session
- **EventStoreManager**: 10k event limit, 30-day retention by default
- **DIContainer**: Thread-safe singleton resolution with cleanup support

## Build & Development Commands

Use the Makefile for all development tasks:

### Project Setup
- `make install-deps` - Install XcodeGen and other dependencies
- `make generate` - Generate Xcode project using XcodeGen

### Swift Package Pinning
The committed root `Package.resolved` is the source of truth for dependency
revisions — including the `nuxieai/rive-ios` fork, which is declared as
`branch: main` and would otherwise float (or, worse, resolve stale from a
cached package mirror). `make generate` seeds it into the generated
workspace (`scripts/sync-package-pins.sh seed`) so xcodebuild checks out
exactly the pinned revisions; CI verifies this with
`scripts/sync-package-pins.sh verify`. To bump the rive-ios fork, run
`swift package update rive-ios` (updates root `Package.resolved`) and commit.

### Testing
- `make test` - Run unit tests on iOS Simulator (default)
- `make test-unit` - Run unit tests
- `make test-integration` - Run integration tests
- `make test-e2e` - Run end-to-end tests
- `make test-all` - Run unit + integration + e2e tests
- `make test-ios` - Alias for `make test`

### Cleanup
- `make clean` - Remove generated Xcode project files and build artifacts

### Help
- `make help` - Show all available commands

**Important**: Always use `make` commands instead of direct `xcodebuild` or `swift` commands to ensure consistency.

## Testing Best Practices

### Test File Structure
```swift
import Foundation
import Quick
import Nimble
@testable import Nuxie

// Use AsyncSpec for any tests involving async operations
final class NetworkQueueTests: AsyncSpec {
    override class func spec() {
        describe("NetworkQueue") {
            var queue: NetworkQueue!
            var mockApi: MockAPI!
            
            beforeEach {
                mockApi = MockAPI()
                queue = NetworkQueue(api: mockApi)
            }
            
            afterEach {
                await queue?.shutdown()
                await mockApi?.reset()
            }
            
            describe("enqueue") {
                it("should process events") {
                    await queue.enqueue(event)
                    await expect { await queue.size }.to(equal(1))
                }
            }
        }
    }
}
```

### Common Testing Patterns

#### Testing Actors
```swift
// Mock as an actor for thread safety
actor MockService: ServiceProtocol {
    private(set) var events: [Event] = []
    
    func trigger(_ event: Event) {
        events.append(event)
    }
    
    func reset() {
        events.removeAll()
    }
}

// Test with async expectations
it("should track events") {
    await service.trigger(event)
    await expect { await service.events.count }.to(equal(1))
}
```

#### Testing Async Network Calls
```swift
it("should handle network errors") {
    await mockApi.setError(NetworkError.timeout)
    
    await expect { try await api.fetch() }
        .to(throwError(NetworkError.timeout))
}
```

#### Testing Eventually-True Conditions
```swift
it("should eventually process queue") {
    await queue.enqueue(events)
    
    // Poll until condition is met
    await expect { await queue.isEmpty }
        .toEventually(beTrue(), timeout: .seconds(2))
    
    await expect { await mockApi.callCount }
        .toEventually(equal(3), timeout: .seconds(1))
}
```

#### Testing Concurrent Operations
```swift
it("should handle concurrent access") {
    // Launch multiple concurrent operations
    async let result1 = queue.process()
    async let result2 = queue.process()
    
    let results = await (result1, result2)
    
    // Only one should succeed
    expect(results.0 || results.1).to(beTrue())
    expect(results.0 && results.1).to(beFalse())
}
```

### Testing Guidelines

1. **Always use AsyncSpec** for tests with async operations
2. **Use actors for mock objects** to ensure thread safety
3. **Wrap async calls in expect closures**: `await expect { await ... }`
4. **Use toEventually for polling**: Great for testing async state changes
5. **Clean up resources in afterEach**: Shutdown queues, reset mocks
6. **Test error conditions**: Always test failure paths
7. **Isolate test data**: Use unique paths/IDs for each test

### Running Tests

- `make test` - Run unit tests on iOS Simulator (default)
- `make test-integration` - Run integration tests on iOS Simulator
- `make test-e2e` - Run end-to-end tests on iOS Simulator
- `make test-all` - Run unit + integration + e2e tests on iOS Simulator
- `make coverage` - Run with code coverage
- `make coverage-html` - Generate HTML coverage report

## Important Notes

- **Version**: Currently 0.1.0, update `SDKVersion.swift` as needed
- **Thread Safety**: SQLite operations use dedicated queue, DI container is thread-safe
- **Memory Management**: Avoid retain cycles with weak references, proper cleanup in deinit
- **Privacy**: Event storage is local-first, remote sync respects user preferences
- **Testing**: Always use Quick 7+/Nimble 13+ with AsyncSpec for async tests
- **Performance**: Events stored immediately, remote sync is non-blocking

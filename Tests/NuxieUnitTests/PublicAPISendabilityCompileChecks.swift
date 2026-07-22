import Foundation
import XCTest

@testable import Nuxie

/// Compile-time checks that the PUBLIC API surface is Sendable-correct for a
/// Swift 6 consumer.
///
/// A host app compiled in Swift 6 language mode gets *errors* wherever a
/// non-Sendable SDK type crosses an isolation boundary at the interface.
/// These checks pin the two properties we can enforce from inside the
/// package's Swift 5 tests:
///
/// 1. `requireSendable` fails to COMPILE if a public value type loses its
///    `Sendable` conformance (generic bounds are enforced in every language
///    mode — this is a hard gate, not a warning).
/// 2. `_compileOnlyUsage` mirrors representative consumer call sites —
///    `@MainActor` UI code, detached tasks, `@Sendable` callbacks — so any
///    signature change that would break a strict-concurrency consumer
///    surfaces here as a strict-concurrency warning (caught by
///    `make check-concurrency-warnings`) or an outright compile error.
///
/// Limits (documented, not fixable from in-package tests):
/// - The package compiles in Swift 5 mode, so isolation violations that
///   would be *errors* for a Swift 6 consumer are only *warnings* here; the
///   warning ratchet is what keeps them at zero.
/// - `@preconcurrency import` behavior in a consumer cannot be simulated.
final class PublicAPISendabilityCompileChecks: XCTestCase {

  // MARK: - 1. Sendable conformance assertions (hard compile-time gate)

  private func requireSendable<T: Sendable>(_: T.Type) {}

  func testPublicValueTypesAreSendable() {
    // Configuration
    requireSendable(Environment.self)
    requireSendable(LogLevel.self)
    requireSendable(NuxieConfiguration.self)
    requireSendable(NuxieConfiguration.PurchaseHandlingMode.self)

    // Facade auxiliary types
    requireSendable(NuxieSDK.self)
    requireSendable(NuxieSDK.FeatureCheckPolicy.self)

    // Trigger surface (wrapper contract)
    requireSendable(TriggerUpdate.self)
    requireSendable(TriggerDecision.self)
    requireSendable(TriggerResult.self)
    requireSendable(TriggerError.self)
    requireSendable(EntitlementUpdate.self)
    requireSendable(JourneyRef.self)
    requireSendable(JourneyUpdate.self)
    requireSendable(SuppressReason.self)
    requireSendable(GateSource.self)

    // Events
    requireSendable(NuxieEvent.self)
    requireSendable(StoredEvent.self)
    requireSendable(EventResponse.self)
    requireSendable(EventFlushStrategy.self)
    requireSendable(AnyCodable.self)

    // Features / entitlements
    requireSendable(FeatureAccess.self)
    requireSendable(FeatureCheckResult.self)
    requireSendable(FeatureUsageResult.self)
    requireSendable(FeatureUsageResult.UsageInfo.self)
    requireSendable(PurchaseResponse.self)
    requireSendable(PurchaseFeature.self)

    // Profile / network models
    requireSendable(ProfileResponse.self)
    requireSendable(Campaign.self)
    requireSendable(Segment.self)
    requireSendable(Feature.self)
    requireSendable(ActiveJourney.self)
    requireSendable(ExperimentAssignment.self)

    // Experiences
    requireSendable(Experience.self)
    requireSendable(ExperienceProduct.self)
    requireSendable(ExperienceColorSchemeMode.self)
    requireSendable(CloseReason.self)
    requireSendable(RemoteFlow.self)
    requireSendable(FlowArtifact.self)

    // Journeys
    requireSendable(Journey.self)
    requireSendable(JourneyStatus.self)
    requireSendable(JourneyExitReason.self)
    requireSendable(JourneyAction.self)
    requireSendable(ResumeReason.self)

    // StoreKit
    requireSendable(PurchaseResult.self)
    requireSendable(PurchaseOutcome.self)
    requireSendable(RestoreResult.self)
    requireSendable(PurchaseSyncResult.self)
    requireSendable(StoreProductType.self)
    requireSendable(SubscriptionPeriod.self)

    // Errors
    requireSendable(NuxieError.self)
    requireSendable(NuxieNetworkError.self)
    requireSendable(StoreKitError.self)
    requireSendable(TriggerError.self)

    // IR value model (crosses the EventLog actor boundary)
    requireSendable(IRValue.self)
    requireSendable(IRPredicate.self)
    requireSendable(IREnvelope.self)
    requireSendable(CompareOp.self)
    requireSendable(Aggregate.self)
    requireSendable(Period.self)
    requireSendable(StepQuery.self)
  }

  // MARK: - 2. Representative Swift 6 consumer call sites (compile-only)

  /// Never invoked — exists so the compiler type-checks the exact shapes a
  /// strict-concurrency consumer writes. Any isolation break here shows up
  /// in the `make check-concurrency-warnings` ratchet.
  @MainActor
  private func _compileOnlyMainActorUsage() async throws {
    let sdk = NuxieSDK.shared

    // Configuration handoff from the main actor.
    let config = NuxieConfiguration(apiKey: "compile-check")
    config.purchaseHandlingMode = .observer
    config.beforeSend = { event in event }  // must accept @Sendable closure
    try sdk.setup(with: config)

    // Fire-and-forget trigger with a @Sendable progress handler.
    sdk.trigger("compile_check", properties: ["k": "v"]) { update in
      _ = update
    }

    // Awaited trigger; result consumed on the main actor.
    let result = await sdk.triggerAndWait("compile_check")
    switch result {
    case .allowed(let source): _ = source
    case .denied, .noMatch: break
    case .journeyCompleted(let update): _ = update.journeyId
    case .error(let error): _ = error.code
    }

    // Identity + sessions.
    sdk.identify("user-1", userProperties: ["plan": "pro"])
    _ = sdk.getDistinctId()
    _ = sdk.getAnonymousId()
    _ = sdk.isIdentified
    _ = sdk.getCurrentSessionId()
    sdk.reset(keepAnonymousId: true)

    // Features: observable snapshot is MainActor-bound; checks are async.
    let features: FeatureInfo = sdk.features
    _ = features
    let access = try await sdk.hasFeature("gate", policy: .cacheFirst)
    _ = access.allowed
    sdk.useFeature("metered", amount: 1)
    _ = try await sdk.useFeatureAndWait("metered")

    // Experiences from UI code.
    _ = try await sdk.experienceViewController(for: "exp", colorSchemeMode: .dark)
    try await sdk.showExperience("exp")

    // Event queue controls.
    _ = await sdk.flushEvents()
    _ = await sdk.getQueuedEventCount()
    await sdk.pauseEventQueue()
    await sdk.resumeEventQueue()

    _ = try await sdk.refreshProfile()
    _ = sdk.version
    await sdk.shutdown()
  }

  /// Consumer moving SDK values across isolation domains: everything a
  /// detached task captures below must be Sendable.
  private func _compileOnlyCrossIsolationUsage() async {
    let result = await NuxieSDK.shared.triggerAndWait("compile_check")
    let response: ProfileResponse? = try? await NuxieSDK.shared.refreshProfile()

    Task.detached {
      _ = result
      _ = response
      _ = await NuxieSDK.shared.flushEvents()
    }
  }

  /// Delegate wired from a @MainActor consumer type.
  @MainActor
  private final class CompileCheckDelegate: NuxieDelegate {
    func featureAccessDidChange(
      _ featureId: String, from oldValue: FeatureAccess?, to newValue: FeatureAccess
    ) {}
  }

  @MainActor
  private func _compileOnlyDelegateUsage() {
    let delegate = CompileCheckDelegate()
    NuxieSDK.shared.delegate = delegate
  }

  /// Purchase delegate implemented by a consumer; protocol requires Sendable.
  private final class CompileCheckPurchaseDelegate: NuxiePurchaseDelegate {
    func purchase(_ product: any StoreProductProtocol) async -> PurchaseResult {
      .cancelled
    }
    func restore() async -> RestoreResult {
      .noPurchases
    }
  }

  func testCompileCheckAnchorsExist() {
    // Runtime no-op: the value of this file is that it compiles.
    XCTAssertNotNil(NuxieSDK.shared)
  }
}

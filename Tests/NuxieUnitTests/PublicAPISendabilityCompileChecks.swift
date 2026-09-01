import Foundation
import StoreKit
import XCTest

@_spi(Testing) @testable import Nuxie

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
    requireSendable(TriggerError.Code.self)
    requireSendable(ExperienceRef.self)
    requireSendable(JourneyUpdate.self)
    requireSendable(SuppressReason.self)

    // Events
    requireSendable(NuxieEvent.self)
    requireSendable(StoredEvent.self)
    requireSendable(EventResponse.self)
    requireSendable(EventFlushStrategy.self)
    requireSendable(AnyCodable.self)
    requireSendable(AppActionValue.self)
    requireSendable(AppAction.self)
    requireSendable(NuxieActivityInfo.self)
    requireSendable(NuxieActivityValue.self)
    requireSendable(NuxieActivity.self)
    requireSendable(DismissReason.self)
    requireSendable(PurchaseInfo.self)
    requireSendable(PermissionKind.self)

    // Features / entitlements
    requireSendable(FeatureAccess.self)
    requireSendable(FeatureCheckResult.self)
    requireSendable(FeatureUsageResult.self)
    requireSendable(FeatureUsageResult.UsageInfo.self)
    requireSendable(PurchaseResponse.self)
    requireSendable(PurchaseFeature.self)

    // Profile / network models
    requireSendable(Segment.self)
    requireSendable(Feature.self)
    requireSendable(ExperimentAssignment.self)

    // Experiences
    requireSendable(StoreProduct.self)
    // Journeys
    requireSendable(Journey.self)
    requireSendable(JourneyStatus.self)
    requireSendable(JourneyExitReason.self)
    requireSendable(ResumeReason.self)

    // StoreKit
    requireSendable(PurchaseResult.self)
    requireSendable(RestoreResult.self)
    requireSendable(PurchaseSyncResult.self)
    requireSendable(StoreProductType.self)
    requireSendable(SubscriptionPeriod.self)

    // Errors
    requireSendable(NuxieError.self)
    requireSendable(NuxieNetworkError.self)
    requireSendable(Nuxie.StoreKitError.self)
    requireSendable(TriggerError.self)

    // IR value model (crosses the EventLog actor boundary)
    requireSendable(IRValue.self)
    requireSendable(IRPredicate.self)
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
    case .noMatch: break
    case .journeyCompleted(let update): _ = update.journeyId
    case .error(let error): _ = error.code
    }

    // Identity.
    sdk.identify("user-1", userProperties: ["plan": "pro"])
    _ = sdk.getDistinctId()
    _ = sdk.getAnonymousId()
    _ = sdk.isIdentified
    sdk.reset(keepAnonymousId: true)

    // Features: observable snapshot is MainActor-bound; checks are async.
    let features: FeatureInfo = sdk.features
    _ = features
    let access = try await sdk.hasFeature("gate", policy: .cacheFirst)
    _ = access.allowed
    sdk.useFeature("metered", amount: 1)
    _ = try await sdk.useFeatureAndWait("metered")

    // Engine-owned experience presentation can be dismissed from UI code.
    await sdk.dismiss()

    try await sdk.setLocaleIdentifier(nil)
    _ = sdk.version
    await sdk.shutdown()
  }

  /// Consumer moving SDK values across isolation domains: everything a
  /// detached task captures below must be Sendable.
  private func _compileOnlyCrossIsolationUsage() async {
    let result = await NuxieSDK.shared.triggerAndWait("compile_check")

    Task.detached {
      _ = result
      await NuxieSDK.shared.dismiss()
    }
  }

  /// Exact purchase shapes copied by the maintained public documentation.
  /// This is intentionally compile-only: docs checks pin the snippets to
  /// these call sites, and this target proves that the public Swift surface
  /// accepts them.
  private func _compileOnlyPurchaseDocumentationSurface() async throws {
    let terms = StoreProduct.IntroductoryTerms(
      price: "$0.00",
      period: .week,
      periodCount: 1,
      cycles: 1,
      paymentMode: .freeTrial,
      trialPeriodText: "1 week"
    )
    let product = StoreProduct(
      productId: "product-pro",
      storeProductId: "com.example.pro.monthly",
      placementId: "primary",
      name: "Pro Monthly",
      price: "$9.99",
      period: .month,
      productType: .autoRenewable,
      billingPlan: .default,
      introductoryTerms: terms
    )
    _ = product.rawProduct
    _ = product.storeKitPurchaseOptions
    _ = product.introductoryOfferEligibilityJWS

    let ordinary = FeatureUsageResult(
      success: true,
      featureId: "api_calls",
      amountUsed: 1,
      message: nil,
      usage: .init(current: 1, limit: 10, remaining: 9)
    )
    let atomic = FeatureUsageResult(
      success: true,
      featureId: "api_calls",
      amountUsed: 1,
      message: nil,
      usage: nil,
      authoritativeAccess: nil
    )
    _ = ordinary.usage?.remaining
    _ = atomic.authoritativeAccess?.allowed

    let purchaseOutcomes: [PurchaseResult] = [
      .purchased, .pending, .cancelled,
      .failed(NuxieError.invalidConfiguration("failed")),
    ]
    let restoreOutcomes: [RestoreResult] = [
      .restored, .noPurchases,
      .failed(NuxieError.invalidConfiguration("failed")),
    ]
    _ = purchaseOutcomes
    _ = restoreOutcomes
  }

  /// Delegate wired from a @MainActor consumer type.
  @MainActor
  private final class CompileCheckDelegate: NuxieDelegate {
    func featureAccessDidChange(
      _ featureId: String, from oldValue: FeatureAccess?, to newValue: FeatureAccess
    ) {}

    func nuxie(_ sdk: NuxieSDK, didRequestAppAction action: AppAction) {
      _ = action.experience
    }

    func nuxieDidEmit(_ info: NuxieActivityInfo) {
      _ = info.id
      _ = info.timestamp
      _ = info.receivedAt
      _ = info.activity
      _ = info.name
      _ = info.properties
    }
  }

  @MainActor
  private func _compileOnlyDelegateUsage() {
    let delegate = CompileCheckDelegate()
    NuxieSDK.shared.delegate = delegate
  }

  /// A direct provider integration; no provider-specific compatibility shim.
  private final class CompileCheckRevenueCatDelegate: NuxiePurchaseDelegate {
    func purchase(product: StoreProduct) async -> PurchaseResult {
      _ = product.rawProduct
      return .cancelled
    }
    func restorePurchases() async -> RestoreResult {
      .noPurchases
    }
  }

  /// Superwall can own checkout through the same two-method contract.
  private final class CompileCheckSuperwallDelegate: NuxiePurchaseDelegate {
    func purchase(product: StoreProduct) async -> PurchaseResult {
      _ = product.rawProduct
      return .cancelled
    }
    func restorePurchases() async -> RestoreResult {
      .noPurchases
    }
  }

  /// A hand-written StoreKit stack conforms without an adapter protocol.
  private final class CompileCheckCustomPurchaseDelegate: NuxiePurchaseDelegate {
    private enum PurchaseError: Error {
      case productUnavailable
      case unknown
    }

    func purchase(product: StoreProduct) async -> PurchaseResult {
      guard let rawProduct = product.rawProduct else {
        return .failed(PurchaseError.productUnavailable)
      }
      do {
        switch try await rawProduct.purchase(
          options: product.storeKitPurchaseOptions
        ) {
        case .success(let verification):
          switch verification {
          case .verified: return .purchased
          case .unverified(_, let error): return .failed(error)
          }
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: return .failed(PurchaseError.unknown)
        }
      } catch {
        return .failed(error)
      }
    }

    func restorePurchases() async -> RestoreResult {
      do {
        try await AppStore.sync()
        for await result in Transaction.currentEntitlements {
          guard case .verified(let transaction) = result,
                transaction.revocationDate == nil,
                !transaction.isUpgraded else { continue }
          return .restored
        }
        return .noPurchases
      } catch {
        return .failed(error)
      }
    }
  }

  func testCompileCheckAnchorsExist() {
    // Runtime no-op: the value of this file is that it compiles.
    XCTAssertNotNil(NuxieSDK.shared)
    let _: any NuxiePurchaseDelegate = CompileCheckRevenueCatDelegate()
    let _: any NuxiePurchaseDelegate = CompileCheckSuperwallDelegate()
    let _: any NuxiePurchaseDelegate = CompileCheckCustomPurchaseDelegate()
  }
}

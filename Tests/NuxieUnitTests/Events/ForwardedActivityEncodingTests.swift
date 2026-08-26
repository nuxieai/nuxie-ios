import Foundation
import XCTest

@testable import Nuxie

final class ForwardedActivityEncodingTests: XCTestCase {
  private struct Suite: Decodable {
    let version: Int
    let vectors: [Vector]
  }

  private struct Vector: Decodable {
    let `case`: String
    let wireName: String
    let propertyKeys: [String]
  }

  func testEveryActivityMatchesTheForwardedActivityFixture() throws {
    let suite = try JSONDecoder().decode(
      Suite.self,
      from: Data(contentsOf: repositoryRoot.appendingPathComponent(
        "fixtures/encodings/forwarded-activity.json"
      ))
    )
    XCTAssertEqual(suite.version, NuxieActivityInfo.schemaVersion)

    let activities = Self.activities
    XCTAssertEqual(Set(suite.vectors.map(\.case)), Set(activities.keys))
    for vector in suite.vectors {
      let activity = try XCTUnwrap(activities[vector.case], vector.case)
      XCTAssertEqual(activity.wireName, vector.wireName, vector.case)
      XCTAssertEqual(activity.wireProperties.keys.sorted(), vector.propertyKeys, vector.case)
    }
  }

  func testArrayValuesUseThePinnedFlatCommaJoinedEncoding() throws {
    let activity = NuxieActivity.productsUnavailable(Self.ref, productIds: ["pro", "plus"])
    XCTAssertEqual(activity.wireProperties["product_ids"], .string("pro,plus"))
  }

  func testPurchaseFailureWithoutResolvedProductIdentifiersStillCurates() throws {
    let activity = try XCTUnwrap(ActivityCuration.activity(
      internalName: SystemEventNames.purchaseFailed,
      properties: [
        "placement_id": "placement-1",
        "error": "Product resolution failed",
        "test_store": true,
      ]
    ))

    guard case .purchaseFailed(let info, let message) = activity else {
      return XCTFail("Expected purchaseFailed, got \(activity)")
    }
    XCTAssertNil(info.productId)
    XCTAssertNil(info.storeProductId)
    XCTAssertEqual(info.placementId, "placement-1")
    XCTAssertTrue(info.isTestStore)
    XCTAssertEqual(message, "Product resolution failed")
    XCTAssertNil(activity.wireProperties["product_id"])
    XCTAssertNil(activity.wireProperties["store_product_id"])
  }

  func testPendingAndCancelledPurchasesPreserveTestStoreStatus() throws {
    let properties: [String: Any] = [
      "placement_id": "placement-1",
      "product_id": "product-1",
      "store_product_id": "com.example.product",
      "test_store": true,
    ]
    let pending = try XCTUnwrap(ActivityCuration.activity(
      internalName: SystemEventNames.purchasePending,
      properties: properties
    ))
    let cancelled = try XCTUnwrap(ActivityCuration.activity(
      internalName: SystemEventNames.purchaseCancelled,
      properties: properties
    ))

    guard case .purchasePending(let pendingInfo) = pending,
          case .purchaseCancelled(let cancelledInfo) = cancelled else {
      return XCTFail("Expected pending and cancelled purchase activities")
    }
    XCTAssertTrue(pendingInfo.isTestStore)
    XCTAssertTrue(cancelledInfo.isTestStore)
  }

  func testJourneyUserDismissalAndGenuineCancellationRemainDistinct() throws {
    let base: [String: Any] = [
      "experience_id": "experience-1",
      "experience_version": "version-1",
      "journey_id": "journey-1",
      "reason": "cancelled",
    ]
    let userDismissed = try XCTUnwrap(ActivityCuration.activity(
      internalName: JourneyEvents.journeyExited,
      properties: base.merging(["dismissed_by": "user"]) { _, new in new }
    ))
    let cancelled = try XCTUnwrap(ActivityCuration.activity(
      internalName: JourneyEvents.journeyExited,
      properties: base
    ))

    guard case .journeyEnded(_, let dismissedReason) = userDismissed,
          case .journeyEnded(_, let cancelledReason) = cancelled else {
      return XCTFail("Expected journeyEnded activities")
    }
    XCTAssertEqual(dismissedReason, .dismissed)
    XCTAssertEqual(cancelledReason, .cancelled)
  }

  private static let ref = ExperienceRef(
    experienceId: "experience-1",
    experienceVersion: "version-1",
    journeyId: "journey-1"
  )

  private static let purchase = PurchaseInfo(
    productId: "product-1",
    storeProductId: "com.example.product",
    placementId: "placement-1",
    experience: ref,
    price: Decimal(string: "9.99"),
    displayPrice: "$9.99",
    transactionId: "transaction-1",
    isTestStore: true
  )

  private static let unresolvedPurchase = PurchaseInfo(
    productId: nil,
    storeProductId: nil,
    placementId: "placement-1",
    experience: nil,
    price: nil,
    displayPrice: nil,
    transactionId: nil,
    isTestStore: false
  )

  private static let activities: [String: NuxieActivity] = [
    "experienceShown": .experienceShown(ref),
    "experienceDismissed": .experienceDismissed(ref, reason: .user),
    "experienceErrored": .experienceErrored(ref, message: "failed"),
    "journeyStarted": .journeyStarted(ref),
    "milestoneReached": .milestoneReached(ref, milestoneId: "milestone-1"),
    "journeyConverted": .journeyConverted(ref, journeyId: "journey-1"),
    "journeyEnded": .journeyEnded(ref, exitReason: .completed),
    "purchaseCompleted": .purchaseCompleted(purchase),
    "purchaseFailed": .purchaseFailed(unresolvedPurchase, message: "failed"),
    "purchaseCancelled": .purchaseCancelled(purchase),
    "purchasePending": .purchasePending(purchase),
    "restoreCompleted": .restoreCompleted,
    "restoreFailed": .restoreFailed(message: "failed"),
    "restoreNoPurchases": .restoreNoPurchases,
    "purchaseSynced": .purchaseSynced(
      transactionId: "transaction-1",
      originalTransactionId: "original-1",
      productId: "product-1",
      experience: ref
    ),
    "featureUsed": .featureUsed(featureId: "feature-1", amount: 2, entityId: "entity-1"),
    "experimentExposure": .experimentExposure(
      ref,
      experimentKey: "experiment-1",
      variantKey: "variant-1",
      isHoldout: false
    ),
    "experimentError": .experimentError(
      ref,
      experimentKey: "experiment-1",
      message: "failed"
    ),
    "productsUnavailable": .productsUnavailable(ref, productIds: ["product-1"]),
    "screenShown": .screenShown(ref, screenId: "screen-1"),
    "screenDismissed": .screenDismissed(ref, screenId: "screen-1"),
    "experienceLoadFailed": .experienceLoadFailed(ref, message: "failed"),
    "permissionResolved": .permissionResolved(ref, kind: .notifications, granted: true),
    "appInstalled": .appInstalled,
    "appUpdated": .appUpdated(fromVersion: "1.0", toVersion: "2.0"),
    "appOpened": .appOpened,
    "appBackgrounded": .appBackgrounded,
  ]

  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }
}

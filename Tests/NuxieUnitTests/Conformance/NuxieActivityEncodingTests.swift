import Foundation
import XCTest
@testable import Nuxie

final class NuxieActivityEncodingTests: XCTestCase {
    private struct Fixture {
        let version: Int
        let vectors: [[String: Any]]
    }

    func testEveryActivityCaseRoundTripsThroughPinnedWireEncoding() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.version, NuxieActivityInfo.schemaVersion)

        let ref = ExperienceRef(
            experienceId: "exp-1",
            experienceVersion: "v1",
            journeyId: "journey-1"
        )
        let purchase = PurchaseInfo(
            productId: "product-1",
            storeProductId: "store.product.1",
            placementId: "placement-1",
            experience: ref,
            price: Decimal(string: "9.99"),
            displayPrice: "$9.99",
            transactionId: "transaction-1",
            isTestStore: true
        )
        let minimalPurchase = PurchaseInfo(
            productId: "product-2",
            storeProductId: "store.product.2",
            placementId: nil,
            experience: nil,
            price: nil,
            displayPrice: nil,
            transactionId: nil,
            isTestStore: false
        )
        let cases: [(String, NuxieActivity)] = [
            ("experienceShown", .experienceShown(ref)),
            ("experienceDismissed", .experienceDismissed(ref, reason: .user)),
            ("experienceTimedOut", .experienceTimedOut(ref)),
            ("experienceErrored", .experienceErrored(ref, message: "render failed")),
            ("journeyStarted", .journeyStarted(ref)),
            ("milestoneReached", .milestoneReached(ref, milestoneId: "milestone-1")),
            ("journeyConverted", .journeyConverted(ref)),
            ("journeyEnded", .journeyEnded(ref, exitReason: .goalMet)),
            ("purchaseCompleted", .purchaseCompleted(purchase)),
            ("purchaseFailed", .purchaseFailed(purchase, message: "declined")),
            ("purchaseCancelled", .purchaseCancelled(minimalPurchase)),
            ("purchasePending", .purchasePending(minimalPurchase)),
            ("restoreCompleted", .restoreCompleted),
            ("restoreFailed", .restoreFailed(message: "offline")),
            ("restoreNoPurchases", .restoreNoPurchases),
            ("purchaseSynced", .purchaseSynced(
                transactionId: "transaction-2",
                originalTransactionId: "original-2",
                productId: "product-2"
            )),
            ("featureUsed", .featureUsed(
                featureId: "feature-1",
                amount: 2.5,
                entityId: "entity-1"
            )),
            ("experimentExposure", .experimentExposure(
                ref,
                experimentKey: "experiment-1",
                variantKey: "variant-a",
                isHoldout: false,
                isFallback: true
            )),
            ("experimentError", .experimentError(
                ref,
                experimentKey: "experiment-1",
                message: "variant missing"
            )),
            ("productsUnavailable", .productsUnavailable(
                ref,
                productIds: ["product-1", "product-2"]
            )),
            ("screenShown", .screenShown(ref, screenId: "screen-1")),
            ("screenDismissed", .screenDismissed(ref, screenId: "screen-1")),
            ("experienceLoadFailed", .experienceLoadFailed(
                ref,
                message: "signature invalid"
            )),
            ("permissionResolved", .permissionResolved(
                ref,
                kind: .tracking,
                granted: true
            )),
            ("appInstalled", .appInstalled),
            ("appUpdated", .appUpdated(fromVersion: nil, toVersion: "2.0")),
            ("appOpened", .appOpened),
            ("appBackgrounded", .appBackgrounded),
        ]

        XCTAssertEqual(cases.count, 28)
        XCTAssertEqual(fixture.vectors.count, cases.count)

        for ((caseName, activity), vector) in zip(cases, fixture.vectors) {
            XCTAssertEqual(vector["case"] as? String, caseName)
            XCTAssertEqual(vector["name"] as? String, activity.wireName)

            let actual: [String: Any] = [
                "name": activity.wireName,
                "properties": activity.wireProperties.analyticsDictionary,
            ]
            let expected: [String: Any] = [
                "name": try XCTUnwrap(vector["name"] as? String),
                "properties": try XCTUnwrap(vector["properties"] as? [String: Any]),
            ]
            let actualJSON = try canonicalJSON(actual)
            XCTAssertEqual(actualJSON, try canonicalJSON(expected), caseName)

            let decoded = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(actualJSON.utf8)) as? [String: Any]
            )
            XCTAssertEqual(try canonicalJSON(decoded), actualJSON, "round trip: \(caseName)")
        }
    }

    func testEveryDeclaredInternalEventIsExplicitlyMappedOrHidden() throws {
        let declared = try declaredEventNames()
        let mapped = ActivityCuration.mappedNames
        let hidden = ActivityCuration.hiddenNames

        XCTAssertTrue(mapped.isDisjoint(with: hidden))
        XCTAssertEqual(mapped.count, 35)
        XCTAssertEqual(hidden.count, 15)
        XCTAssertEqual(mapped.union(hidden), declared)

        for name in mapped {
            let isJourneySummary = [
                JourneyEvents.journeyMilestone,
                JourneyEvents.journeyConverted,
                JourneyEvents.journeyExited,
            ].contains(name)
            XCTAssertNotNil(
                ActivityCuration.activity(
                    canonicalName: name,
                    properties: isJourneySummary ? ["journey_id": "journey-1"] : [:],
                    journeyExperience: isJourneySummary ? ExperienceRef(
                        experienceId: "experience-1",
                        experienceVersion: nil,
                        journeyId: "journey-1"
                    ) : nil
                ),
                "mapped event has no curation branch: \(name)"
            )
        }
        for name in hidden {
            XCTAssertNil(ActivityCuration.activity(canonicalName: name, properties: [:]))
        }
        XCTAssertEqual(ActivityCuration.classification(for: "customer_event"), .hidden)
        XCTAssertNil(ActivityCuration.activity(canonicalName: "customer_event", properties: [:]))
    }

    private func loadFixture() throws -> Fixture {
        let data = try Data(
            contentsOf: repoRoot.appendingPathComponent("fixtures/encodings/forwarded-activity.json")
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return Fixture(
            version: try XCTUnwrap(object["version"] as? Int),
            vectors: try XCTUnwrap(object["vectors"] as? [[String: Any]])
        )
    }

    private func declaredEventNames() throws -> Set<String> {
        let files = [
            repoRoot.appendingPathComponent("Sources/Nuxie/Events/SystemEventNames.swift"),
            repoRoot.appendingPathComponent("Sources/Nuxie/Journey/Events/JourneyEvents.swift"),
        ]
        let expression = try NSRegularExpression(
            pattern: #"(?:public\s+)?static\s+let\s+\w+\s*=\s*\"([^\"]+)\""#
        )
        var result: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in expression.matches(in: source, range: range) {
                guard let valueRange = Range(match.range(at: 1), in: source) else { continue }
                result.insert(String(source[valueRange]))
            }
        }
        return result
    }

    private func canonicalJSON(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testResolvedKeepsNumericNSNumbersNumeric() {
        XCTAssertEqual(NuxieActivityValue.resolved(NSNumber(value: 0)), .int(0))
        XCTAssertEqual(NuxieActivityValue.resolved(NSNumber(value: 1)), .int(1))
        XCTAssertEqual(
            NuxieActivityValue.resolved(NSNumber(value: true)),
            .bool(true)
        )
        XCTAssertEqual(
            NuxieActivityValue.resolved(kCFBooleanFalse as Any),
            .bool(false)
        )
    }
}

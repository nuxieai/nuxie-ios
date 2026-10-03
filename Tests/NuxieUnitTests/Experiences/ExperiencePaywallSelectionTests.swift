import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie

final class ExperiencePaywallSelectionTests: XCTestCase {
    private func coordinator(duplicateID: Bool = false) -> ExperienceViewModelStateCoordinator {
        func value(_ model: String, _ instance: String, _ path: String, _ raw: Any) -> JourneyViewModelValue {
            .init(viewModelName: model, instanceId: instance, path: path, value: AnyCodable(raw))
        }
        return ExperienceViewModelStateCoordinator(screens: JourneyDocument(screens: [
            .init(id: "paywall", defaultViewModelName: "Runtime", defaultInstanceId: "root"),
            .init(id: "other", defaultViewModelName: "Runtime", defaultInstanceId: "other-root"),
        ], viewModelValues: [
            value("Runtime", "root", "paywall/products", [["vmInstanceId": "monthly"], ["vmInstanceId": "annual"]]),
            value("Runtime", "root", "paywall/selectedProduct", ["vmInstanceId": "monthly"]),
            value("Runtime", "root", "paywall/selectedProductId", "product-monthly"),
            value("Runtime", "root", "paywall/selectedIndex", 0),
            value("PaywallProduct", "monthly", "productId", "product-monthly"),
            value("PaywallProduct", "monthly", "placementId", "placement-monthly"),
            value("PaywallProduct", "annual", "productId", duplicateID ? "product-monthly" : "product-annual"),
            value("PaywallProduct", "annual", "placementId", "placement-annual"),
            value("PaywallProduct", "undeclared", "productId", "product-undeclared"),
            value("PaywallProduct", "undeclared", "placementId", "placement-undeclared"),
        ]))
    }

    private func placement(_ subject: ExperienceViewModelStateCoordinator) -> String? {
        subject.getPurchaseValue(path: .init(viewModelName: "Runtime",
            path: "paywall.selectedProduct.placementId", isRelative: false),
            screenId: "paywall", instanceId: nil) as? String
    }

    @discardableResult
    private func select(_ id: Any, on subject: ExperienceViewModelStateCoordinator,
                        screen: String = "paywall") -> [JourneyViewModelValue] {
        subject.applyRendererValue(path: .init(viewModelName: "Runtime", path: "paywall/selectedProductId"),
            value: id, screenId: screen, instanceId: "root")
    }

    func testPublishedDefaultAndFileAuthoredSelectionResolveDifferentPlacements() {
        let subject = coordinator()
        XCTAssertEqual(placement(subject), "placement-monthly")
        let updates = select("product-annual", on: subject)
        XCTAssertEqual(placement(subject), "placement-annual")
        XCTAssertEqual(subject.getValue(path: .init(path: "paywall/selectedIndex"), screenId: "paywall") as? Int, 1)
        XCTAssertEqual(updates.first { $0.instanceId == "annual" && $0.path == "isSelected" }?.value.value as? Bool, true)
        XCTAssertEqual(updates.first { $0.instanceId == "monthly" && $0.path == "isSelected" }?.value.value as? Bool, false)
        select("product-monthly", on: subject)
        XCTAssertEqual(placement(subject), "placement-monthly")
    }

    func testInvalidAndUndeclaredSelectionsNeverKeepAPreviousPurchaseTarget() {
        for invalid: Any in ["unknown", "product-undeclared", "", 1, NSNull()] {
            let subject = coordinator()
            select("product-annual", on: subject)
            select(invalid, on: subject)
            XCTAssertNil(placement(subject))
            XCTAssertEqual(subject.getValue(path: .init(path: "paywall/selectedIndex"), screenId: "paywall") as? Int, -1)
            let snapshot = subject.getSnapshot()
            subject.hydrate(snapshot)
            XCTAssertNil(placement(subject), "Snapshots must not restore a stale purchase target")
            select("product-monthly", on: subject)
            XCTAssertEqual(placement(subject), "placement-monthly")
        }
    }

    func testAmbiguousProductIDClearsThePurchaseTarget() {
        let subject = coordinator(duplicateID: true)
        select("product-monthly", on: subject)
        XCTAssertNil(placement(subject))
    }

    func testFileAuthoredRootCanSelectItsAttachedPaywall() {
        let values = coordinator().getSnapshot().values.map { value in
            JourneyViewModelValue(viewModelName: value.viewModelName == "Runtime" ? "PaywallFrame" : value.viewModelName,
                instanceId: value.instanceId, path: value.path, value: value.value)
        }
        let subject = ExperienceViewModelStateCoordinator(screens: JourneyDocument(screens: [
            .init(id: "paywall", defaultViewModelName: "PaywallFrame", defaultInstanceId: "root"),
        ], viewModelValues: values))
        _ = subject.applyRendererValue(path: .init(viewModelName: "PaywallFrame", path: "paywall/selectedProductId"),
            value: "product-annual", screenId: "paywall", instanceId: "root")
        XCTAssertEqual(subject.getPurchaseValue(path: .init(viewModelName: "PaywallFrame",
            path: "paywall.selectedProduct.placementId", isRelative: false),
            screenId: "paywall", instanceId: nil) as? String, "placement-annual")
    }

    func testAnotherScreenCannotSelectProductsForThisOccurrence() {
        let subject = coordinator()
        XCTAssertTrue(select("product-annual", on: subject, screen: "other").isEmpty)
        XCTAssertEqual(placement(subject), "placement-monthly")
    }

    func testRendererCannotExpandTheSignedProductList() {
        let subject = coordinator()
        _ = subject.applyRendererValue(path: .init(viewModelName: "Runtime", path: "paywall/products"),
            value: [["vmInstanceId": "undeclared"]], screenId: "paywall", instanceId: "root")
        select("product-undeclared", on: subject)
        XCTAssertNil(placement(subject))
    }

    func testRootPathWinsOverAnUnrelatedInstanceWithTheSameName() {
        let subject = coordinator()
        subject.hydrate(.init(values: subject.getSnapshot().values + [
            .init(viewModelName: "Other", instanceId: "shadow", instanceName: "paywall",
                path: "selectedProduct", value: AnyCodable(["vmInstanceId": "undeclared"])),
        ]))
        XCTAssertEqual(placement(subject), "placement-monthly")
    }

    func testSelectionUsesTheCurrentOrderOfDeclaredProducts() {
        let subject = coordinator()
        _ = subject.applyRendererValue(path: .init(viewModelName: "Runtime", path: "paywall/products"),
            value: [["vmInstanceId": "annual"], ["vmInstanceId": "monthly"]],
            screenId: "paywall", instanceId: "root")
        select("product-annual", on: subject)
        XCTAssertEqual(placement(subject), "placement-annual")
        XCTAssertEqual(subject.getValue(path: .init(path: "paywall/selectedIndex"), screenId: "paywall") as? Int, 0)
    }

    func testMissingRootReferenceCannotFallThroughToAnUnrelatedNamedInstance() {
        let subject = coordinator()
        subject.hydrate(.init(values: subject.getSnapshot().values.filter {
            $0.path != "paywall/selectedProduct"
        } + [
            .init(viewModelName: "Other", instanceId: "shadow", instanceName: "paywall",
                path: "selectedProduct", value: AnyCodable(["vmInstanceId": "undeclared"])),
        ]))
        XCTAssertNil(placement(subject))
    }
}

import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class PaywallStatusProjectorTests: QuickSpec {
    override class func spec() {
        func makeProjector() -> PaywallStatusProjector {
            var next = 0
            return PaywallStatusProjector(makeInvocationId: {
                next += 1
                return "inv-\(next)"
            })
        }

        func values(_ writes: [PaywallStatusProjector.Write]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: writes.map { ($0.path, $0.value) })
        }

        describe("beginPurchase") {
            it("marks the purchase running with a fresh invocation id") {
                var projector = makeProjector()
                let writes = projector.beginPurchase()
                expect(writes.map(\.path)) == [
                    "paywall/purchase/status",
                    "paywall/purchase/errorCode",
                    "paywall/purchase/invocationId",
                ]
                expect(values(writes)) == [
                    "paywall/purchase/status": "running",
                    "paywall/purchase/errorCode": "",
                    "paywall/purchase/invocationId": "inv-1",
                ]
                expect(projector.activePurchaseInvocationId) == "inv-1"
            }
        }

        describe("project") {
            it("resolves a completed purchase against the active invocation") {
                var projector = makeProjector()
                _ = projector.beginPurchase()
                let writes = projector.project(
                    eventName: SystemEventNames.purchaseCompleted,
                    properties: [:]
                )
                expect(values(writes)) == [
                    "paywall/purchase/status": "success",
                    "paywall/purchase/errorCode": "",
                    "paywall/purchase/invocationId": "inv-1",
                ]
                expect(projector.activePurchaseInvocationId).to(beNil())
            }

            it("carries the error code on purchase failure") {
                var projector = makeProjector()
                _ = projector.beginPurchase()
                let writes = projector.project(
                    eventName: SystemEventNames.purchaseFailed,
                    properties: ["error_code": "payment_declined"]
                )
                expect(values(writes)["paywall/purchase/status"]) == "error"
                expect(values(writes)["paywall/purchase/errorCode"]) == "payment_declined"
                expect(projector.activePurchaseInvocationId).to(beNil())
            }

            it("keeps the invocation active for a pending (Ask-to-Buy) purchase") {
                var projector = makeProjector()
                _ = projector.beginPurchase()
                let pending = projector.project(
                    eventName: SystemEventNames.purchasePending,
                    properties: [:]
                )
                expect(values(pending)["paywall/purchase/status"]) == "pending"
                expect(projector.activePurchaseInvocationId) == "inv-1"

                let completed = projector.project(
                    eventName: SystemEventNames.purchaseCompleted,
                    properties: [:]
                )
                expect(values(completed)["paywall/purchase/invocationId"]) == "inv-1"
            }

            it("mints an invocation id for an outcome with no active invocation") {
                var projector = makeProjector()
                let writes = projector.project(
                    eventName: SystemEventNames.purchaseCancelled,
                    properties: [:]
                )
                expect(values(writes)["paywall/purchase/status"]) == "cancelled"
                expect(values(writes)["paywall/purchase/invocationId"]) == "inv-1"
            }

            it("projects restore outcomes on the restore paths") {
                var projector = makeProjector()
                _ = projector.beginRestore()
                let writes = projector.project(
                    eventName: SystemEventNames.restoreNoPurchases,
                    properties: [:]
                )
                expect(values(writes)) == [
                    "paywall/restore/status": "not_found",
                    "paywall/restore/errorCode": "",
                    "paywall/restore/invocationId": "inv-1",
                ]
                expect(projector.activeRestoreInvocationId).to(beNil())
            }

            it("tracks purchase and restore invocations independently") {
                var projector = makeProjector()
                _ = projector.beginPurchase()
                _ = projector.beginRestore()
                let restore = projector.project(
                    eventName: SystemEventNames.restoreCompleted,
                    properties: [:]
                )
                expect(values(restore)["paywall/restore/invocationId"]) == "inv-2"
                expect(projector.activePurchaseInvocationId) == "inv-1"
            }

            it("ignores unrelated events") {
                var projector = makeProjector()
                expect(projector.project(eventName: "$screen_shown", properties: [:])).to(beEmpty())
            }
        }

        describe("errorCode") {
            it("scans the known error keys in order") {
                expect(PaywallStatusProjector.errorCode(from: ["errorCode": "x"])) == "x"
                expect(PaywallStatusProjector.errorCode(from: ["error_code": "a", "code": "b"])) == "a"
                expect(PaywallStatusProjector.errorCode(from: ["error": "e"])) == "e"
                expect(PaywallStatusProjector.errorCode(from: ["error": ""])) == ""
                expect(PaywallStatusProjector.errorCode(from: [:])) == ""
            }
        }
    }
}

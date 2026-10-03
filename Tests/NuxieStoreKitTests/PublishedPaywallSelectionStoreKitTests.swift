import Foundation
import UIKit
import XCTest
@testable import Nuxie
@testable import NuxieTestSupport

/// Normal publication, authenticated acquisition, the UIKit input loop, the
/// production presentation delegate and native commerce handler share one release.
final class PublishedPaywallSelectionStoreKitTests: NativeStoreKitTestCase {
    @MainActor
    func testPublishedDefaultAndSelectedProductsReachNativeStoreKit() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/rendered-paywall-selection")
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let profile = try JourneyPlaneProfile.decode(Data(contentsOf: directory.appendingPathComponent("profile.json")))
        let host = try XCTUnwrap(URL(string: profile.delivery.renderBaseUrl)?.host)
        StubURLProtocol.register(matcher: { $0.url?.host == host }) { request in
            let bytes = try Data(contentsOf: directory.appendingPathComponent(String(request.url!.path.dropFirst())))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                "Content-Type": "application/vnd.nuxie.scene", "Content-Length": String(bytes.count),
            ])!, bytes)
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("selection-storekit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        let acquisition = JourneyReleaseAcquisitionStore(cacheDirectory: cache,
            urlSession: TestURLSessionProvider.createTestSession())
        let catalog = JourneyProfileCatalog(authorizationKeys: try JourneyTrustRoots.keys(for: .development),
            supportedRuntime: JourneyReleaseRuntime.current, highWaterStore: InMemoryJourneyReleaseHighWaterStore())
        let entry = try XCTUnwrap(profile.releases.first)
        let snapshot = try await catalog.prepare(profile, authority: .init(
            appId: entry.locator.appId, environment: entry.locator.environment)).snapshot
        let release = try XCTUnwrap(snapshot.releasesByDigest.values.first)
        let purchase = try XCTUnwrap(release.descriptor.leg.steps.first { $0.action?["type"] == .string("purchase") }?.action)
        let fixture = NativeStoreKitServiceFixture(mode: .full)
        let events = MockEventLog()
        let experiences = ExperienceService(productService: ProductService(), eventLog: events,
            transactionServiceProvider: { fixture.service }, systemEventSink: StoreKitRecordingEventSink(), releaseStore: acquisition)
        let prepared = try await experiences.prepareJourneyProfile(snapshot)
        let committed = await experiences.commitJourneyProfile(prepared, generation: 1, admission: nil)
        XCTAssertTrue(committed)
        let presenter = ExperiencePresentationService(experiences: experiences, eventLog: events)
        let owner = JourneyPresentationOwner(journeyId: "selection-storekit", distinctId: NativeStoreKitServiceFixture.customerId)
        let reservation = try XCTUnwrap(presenter.reserveJourneyPresentation(ownerDistinctId: owner.distinctId))
        let request = JourneyPresentationRequest(release: release, delivery: profile.delivery,
            screenId: "screen", owner: owner, reservation: reservation, onEmissionBatch: { batch in
                guard batch.emissions.contains(where: { $0.name == "purchase_requested" }) else { return true }
                // Dispatch the signed action unchanged: the production delegate resolves
                // its VM reference and the real controller purchases the resulting product.
                let result = await presenter.dispatchJourneyPresentationAction(owner: owner, action: purchase, effectId: batch.invocationId)
                XCTAssertEqual(result, .awaitingOutcome)
                return result == .awaitingOutcome
            }, onOutcome: { _, _ in true })
        let shown = await presenter.presentJourney(request)
        XCTAssertEqual(shown, .shown)
        addTeardownBlock { await presenter.shutdownCurrentExperience() }
        let controller = try XCTUnwrap(presenter.currentExperienceViewController)
        func surface(in view: UIView) -> ExperienceRuntimeSurfaceView? {
            if let result = view as? ExperienceRuntimeSurfaceView { return result }
            return view.subviews.lazy.compactMap { surface(in: $0) }.first
        }
        let clock = ContinuousClock()
        let readyDeadline = clock.now.advanced(by: .seconds(10))
        var mounted: ExperienceRuntimeSurfaceView?
        repeat {
            mounted = surface(in: controller.view)
            if mounted?.runtimeObserver != nil, mounted?.window != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        } while clock.now < readyDeadline
        let input = try XCTUnwrap(mounted)
        XCTAssertNotNil(input.runtimeObserver)
        let transform = try XCTUnwrap(ExperienceContainCenterTransform(
            artboardBounds: CGRect(x: 0, y: 0, width: 320, height: 150), viewportBounds: input.bounds))
        func tap(_ point: CGPoint) async throws {
            let pointer = NSObject()
            let location = transform.viewportPoint(fromArtboard: point)
            input.runtimeObserver?.runtimeSurfaceViewDidReceivePointerEvents([
                .init(source: .init(pointer), kind: .down, location: location, timestampSeconds: 1),
            ])
            try await Task.sleep(for: .milliseconds(100))
            input.runtimeObserver?.runtimeSurfaceViewDidReceivePointerEvents([
                .init(source: .init(pointer), kind: .up, location: location, timestampSeconds: 1.1),
            ])
            try await Task.sleep(for: .milliseconds(100))
        }
        func awaitTransaction(_ product: NativeStoreKitTestProduct) async throws {
            let deadline = clock.now.advanced(by: .seconds(10))
            while store.transactionCount(for: product) == 0, clock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertEqual(store.transactionCount(for: product), 1)
            await controller.waitForInFlightPurchaseBeforeHostDismissal()
            controller.cancelHostDismissal()
        }
        try await tap(CGPoint(x: 80, y: 120))
        try await awaitTransaction(.consumable)
        XCTAssertEqual(store.transactionCount(for: .lifetime), 0)
        try await tap(CGPoint(x: 80, y: 40))
        try await tap(CGPoint(x: 80, y: 120))
        try await awaitTransaction(.lifetime)
        XCTAssertEqual(store.transactionCount(for: .consumable), 1)
        let receipts = await fixture.directObserver.recordedPurchaseIds
        XCTAssertEqual(receipts.count, 2)
        await presenter.shutdownCurrentExperience()
    }
}

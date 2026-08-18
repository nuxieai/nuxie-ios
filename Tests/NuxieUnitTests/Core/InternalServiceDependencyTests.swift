import XCTest
@testable import Nuxie
@testable import NuxieTestSupport

final class InternalServiceDependencyTests: XCTestCase {
    private final class EventSink: SystemEventSink, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(String, [String: Any]?)] = []

        func emit(_ name: String, properties: [String: Any]?) {
            lock.lock()
            storage.append((name, properties))
            lock.unlock()
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage.map(\.0)
        }
    }

    @MainActor
    func testRuntimeControllerUsesInjectedEventSinkWithoutSDKSetup() {
        let sink = EventSink()
        let controller = MockExperienceViewController(systemEventSink: sink)

        controller.emitSystemEvent("runtime_event", properties: ["source": "test"])

        XCTAssertEqual(sink.names, ["runtime_event"])
    }

    func testPurchaseServicesConstructFromNarrowCapabilitiesWithoutSDKSetup() async {
        let mocks = MockFactory.shared
        let configuration = NuxieConfiguration(apiKey: "isolated")
        let settings = NuxieRuntimeSettings(configuration: configuration)
        let sink = EventSink()
        let serviceBox = LateBound<TransactionService>()
        let features = FeatureService(
            api: mocks.nuxieApi,
            identity: mocks.identityService,
            profile: mocks.profileService,
            dateProvider: mocks.dateProvider,
            featureInfo: FeatureInfo(),
            cacheTTL: configuration.featureCacheTTL
        )
        let observer = TransactionObserver(
            api: mocks.nuxieApi,
            features: features,
            identity: mocks.identityService,
            settings: settings,
            eventSink: sink,
            transactionServiceProvider: { serviceBox.get() }
        )
        let nativePurchaseAdapter = MockNativeStoreKitPurchaseAdapter()
        nativePurchaseAdapter.configureCancelled()
        let service = TransactionService(
            productService: mocks.productService,
            transactionObserver: observer,
            pendingPurchaseStore: InMemoryPendingPurchaseStore(),
            dateProvider: mocks.dateProvider,
            settings: settings,
            eventSink: sink,
            nativePurchaseAdapter: nativePurchaseAdapter
        )
        serviceBox.set(service)

        do {
            let appStoreProduct = MockStoreProduct(
                id: "product",
                displayName: "Product",
                price: 1,
                displayPrice: "$1"
            )
            _ = try await service.purchase(StoreProduct(
                productId: "product",
                placementId: "placement",
                name: appStoreProduct.displayName,
                price: appStoreProduct.displayPrice,
                period: nil,
                appStoreProduct: appStoreProduct
            ))
            XCTFail("purchase should surface the native adapter outcome")
        } catch StoreKitError.purchaseCancelled {
            XCTAssertTrue(sink.names.isEmpty)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

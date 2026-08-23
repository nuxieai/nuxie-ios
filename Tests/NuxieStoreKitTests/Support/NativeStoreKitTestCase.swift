import XCTest

class NativeStoreKitTestCase: XCTestCase {
    private(set) var store: NativeStoreKitTestHarness!

    override func setUp() async throws {
        try await super.setUp()
        let store = try NativeStoreKitTestHarness()
        do {
            try await store.reset()
        } catch NativeStoreKitTestError.unavailableStoreKitTestDaemon(
            let storefront
        ) {
            if ProcessInfo.processInfo.environment[
                "NUXIE_STOREKIT_REQUIRE_AVAILABLE"
            ] == "1" {
                throw NativeStoreKitTestError.unavailableStoreKitTestDaemon(
                    storefront: storefront
                )
            }
            throw XCTSkip(
                "StoreKitTest is unavailable for this Xcode/simulator-runtime pair; "
                    + "see docs/storekit-test-qualification.md"
            )
        }
        self.store = store
    }

    override func tearDown() async throws {
        await store?.finishAllTransactions()
        store = nil
        try await super.tearDown()
    }
}

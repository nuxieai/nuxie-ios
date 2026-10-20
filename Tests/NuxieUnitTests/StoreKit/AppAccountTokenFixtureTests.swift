import Foundation
import XCTest
@testable import Nuxie

/// The server rebuilds this token from the signed transaction to decide who owns
/// a purchase. Both sides read `fixtures/purchases/app-account-token.json`.
final class AppAccountTokenFixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Case: Decodable {
            let name: String
            let bundleId: String
            let publishableKey: String
            let serviceEnvironment: String
            let storeKitEnvironment: String
            let distinctId: String
            let appAccountToken: String
        }
        let suite: String
        let cases: [Case]
    }

    func testSharedAccountTokenVectors() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/purchases/app-account-token.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        XCTAssertEqual(fixture.suite, "purchases/app-account-token")
        XCTAssertFalse(fixture.cases.isEmpty)

        for vector in fixture.cases {
            let configuration = NuxieConfiguration(apiKey: vector.publishableKey)
            configuration.environment = try XCTUnwrap(
                Environment(rawValue: vector.serviceEnvironment),
                vector.name
            )
            let scope = PurchaseStorageScope(
                appIdentifier: vector.bundleId,
                apiKey: configuration.apiKey,
                testStoreEnabled: configuration.testStoreEnabled
            )

            XCTAssertEqual(
                scope.appAccountToken(distinctId: vector.distinctId)
                    .uuidString.lowercased(),
                vector.appAccountToken,
                vector.name
            )
        }
    }
}

import CryptoKit
import Foundation
import XCTest
@_spi(Companion) @testable import Nuxie

final class JourneyTrustRootsTests: XCTestCase {
    func testStagingTrustsRotatedPublisherAndOtherEnvironmentsDoNot() throws {
        let message = Data("nuxie staging trust root recovery test".utf8)
        let signature = try XCTUnwrap(Data(base64Encoded:
            "t/49Nw7FY1BQs6oaIOgU9cTPtfv83HtkKx/iYjqLNV7kZHe1Yw2ALnERTwBaDslCC1or4Eyus9kUKCCjkcYQCg=="
        ))
        let staging = try JourneyTrustRoots.keys(for: .staging)
        let key = try XCTUnwrap(staging.first { $0.keyID == "nuxie-staging-2026-10-31" })
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: key.ed25519PublicKeyBytes)
        XCTAssertTrue(verifier.isValidSignature(signature, for: message))
        XCTAssertFalse(staging.contains { $0.keyID == "nuxie-experience-2026-07" })
        for environment in [Environment.development, .production] {
            XCTAssertFalse(try JourneyTrustRoots.keys(for: environment).contains { $0.keyID == key.keyID })
        }
    }
}

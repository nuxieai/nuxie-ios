#if os(iOS) && !targetEnvironment(macCatalyst)
import XCTest
import NuxieRuntime
@testable import Nuxie

@MainActor
final class NuxieRuntimeAdapterTests: XCTestCase {
    func testImportsSignedPackageAndBindsAuthenticatedKey() async throws {
        let request = try RuntimePackageFixtureSupport.request(
            named: "animation-event",
            bundle: Bundle(for: Self.self)
        )
        let attachment = try await NuxieRuntimeAdapter().makeContext(for: request)
        defer { attachment.driver.dispose() }

        XCTAssertEqual(
            attachment.importResult.authenticatedKeyId,
            "TEST_ONLY_DEV_KEYPAIR"
        )
        let session = try await attachment.driver.makeSession(
            descriptor: ScreenSessionDescriptor(artboardName: "Timeline Screen")
        )
        session.driver.dispose()
    }

    func testRefusesTamperedSignature() async throws {
        let request = try RuntimePackageFixtureSupport.request(
            named: "animation-event",
            bundle: Bundle(for: Self.self)
        ) { bytes, _ in
            let marker = Data("\"signatureBase64\":\"".utf8)
            guard let range = bytes.range(of: marker), range.upperBound < bytes.endIndex else {
                return XCTFail("Expected signature payload")
            }
            bytes[range.upperBound] = bytes[range.upperBound] == Character("A").asciiValue
                ? Character("B").asciiValue!
                : Character("A").asciiValue!
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await NuxieRuntimeAdapter().makeContext(for: request)
        }
    }

    func testRefusesPackageWithoutSignatureMember() async throws {
        let request = try RuntimePackageFixtureSupport.request(
            named: "animation-event",
            bundle: Bundle(for: Self.self)
        ) { bytes, _ in
            let name = Data("signature".utf8)
            guard let range = bytes.range(of: name) else {
                return XCTFail("Expected signature ToC member")
            }
            bytes[range.lowerBound] = Character("x").asciiValue!
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await NuxieRuntimeAdapter().makeContext(for: request)
        }
    }

    func testRefusesExperienceIdentityReplay() async throws {
        let request = try RuntimePackageFixtureSupport.request(
            named: "animation-event",
            bundle: Bundle(for: Self.self),
            expectedExperienceId: "different-experience"
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NuxieRuntimeAdapter().makeContext(for: request)
        }
    }

    func testImportsVerifiedExternalImageBytes() async throws {
        let request = try RuntimePackageFixtureSupport.request(
            named: "external-image",
            bundle: Bundle(for: Self.self)
        )
        XCTAssertEqual(request.externalAssets.count, 1)

        let attachment = try await NuxieRuntimeAdapter().makeContext(for: request)
        attachment.driver.dispose()
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @MainActor () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
#endif

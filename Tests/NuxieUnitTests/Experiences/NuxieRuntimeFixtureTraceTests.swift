#if os(iOS) && !targetEnvironment(macCatalyst)
import XCTest
@testable import Nuxie

@MainActor
final class NuxieRuntimeFixtureTraceTests: XCTestCase {
    func testSDKBehaviorFixturesCreateScreenSessions() async throws {
        for fixture in ["multi-screen", "scripted-resources"] {
            let request = try RuntimePackageFixtureSupport.request(
                named: fixture,
                bundle: Bundle(for: Self.self)
            )
            let context = try await NuxieRuntimeAdapter().makeContext(for: request)
            defer { context.driver.dispose() }
            let session = try await context.driver.makeSession(
                descriptor: ScreenSessionDescriptor()
            )
            XCTAssertNotNil(session.creationResult.bootstrap, fixture)
            session.driver.dispose()
        }
    }
}
#endif

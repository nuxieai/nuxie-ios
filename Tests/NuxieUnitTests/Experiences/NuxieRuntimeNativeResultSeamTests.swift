#if os(iOS) && !targetEnvironment(macCatalyst)
import XCTest
import NuxieRuntimeSupport
import NuxieRuntimeLegacy
@testable import Nuxie

@MainActor
final class NuxieRuntimeNativeResultSeamTests: XCTestCase {
    func testFinalScreenSessionResultIsCopiedIntoSwiftOwnership() async throws {
        let request = try RuntimePackageFixtureSupport.request(
            named: "animation-event",
            bundle: Bundle(for: Self.self)
        )
        let context = try await NuxieRuntimeAdapter().makeContext(for: request)
        defer { context.driver.dispose() }
        let session = try await context.driver.makeSession(
            descriptor: ScreenSessionDescriptor(artboardName: "Timeline Screen")
        )
        defer { session.driver.dispose() }

        let result = try await session.driver.perform(
            .advance(ExperienceRuntimeFrameTime(timestamp: 0, delta: 0)),
            drawable: nil
        )
        XCTAssertFalse(result.diagnostics.contains { $0.severity == .fatal })
    }
}
#endif

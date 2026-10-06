#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import QuartzCore
import XCTest
@testable import Nuxie
@testable import NuxieRuntime

final class ExperienceSharedValuesTests: XCTestCase {
    #if os(iOS)
    func testScreensShareAuthoredExperienceValues() async throws {
        let expected = try SharedValuesFixture.expectations()
        let payload = try SharedValuesFixture.payload()
        let runValues = ExperienceRunValues()
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let first = try await preparation.openScreen(screenID: "first", runValues: runValues, pixelWidth: 100, pixelHeight: 100)
        let firstSnapshot = try await first.snapshot()
        XCTAssertEqual(firstSnapshot.values.first { $0.name == "trip_days" }?.value, .number(expected.startingValues.trip_days))
        XCTAssertEqual(firstSnapshot.values.first { $0.name == "trip" }?.value, .bytes(Data(expected.startingValues.trip.utf8)))
        XCTAssertEqual(firstSnapshot.values.first { $0.name == "wants_reminder" }?.value, .bool(expected.startingValues.wants_reminder))
        let root = try await first.rootViewModel()
        _ = try await first.mutateState([.setNumber(root, path: "experience/trip_days", value: 30)])
        let second = try await preparation.openScreen(screenID: "long", runValues: runValues, pixelWidth: 100, pixelHeight: 100)
        let secondSnapshot = try await second.snapshot()
        XCTAssertEqual(secondSnapshot.values.first { $0.name == "trip_days" }?.value, .number(30))
        XCTAssertEqual(firstSnapshot.values.first { $0.name == "experience" }?.value,
            secondSnapshot.values.first { $0.name == "experience" }?.value)
        try await first.close()
        try await second.close()
    }
    func testRunSurvivesScreenCloseAndPreparationReplacementButOtherRunsStartFresh() async throws {
        let payload = try SharedValuesFixture.payload()
        let run = ExperienceRunValues()
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let first = try await preparation.openScreen(screenID: "first", runValues: run, pixelWidth: 100, pixelHeight: 100)
        let root = try await first.rootViewModel()
        _ = try await first.mutateState([.setNumber(root, path: "experience/trip_days", value: 30)])
        try await first.close()
        let replacement = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let later = try await replacement.openScreen(screenID: "short", runValues: run, pixelWidth: 80, pixelHeight: 80)
        let separate = try await preparation.openScreen(screenID: "short", runValues: ExperienceRunValues(), pixelWidth: 100, pixelHeight: 100)
        let retained = try await later.snapshot()
        let fresh = try await separate.snapshot()
        XCTAssertEqual(retained.values.first { $0.name == "trip_days" }?.value, .number(30))
        XCTAssertEqual(fresh.values.first { $0.name == "trip_days" }?.value, .number(23))
        try await later.close()
        try await separate.close()
    }

    func testSDKSnapshotCannotSeedOrMirrorSharedRunValues() async throws {
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: SharedValuesFixture.payload())
        let screen = try await preparation.openScreen(screenID: "first", runValues: ExperienceRunValues(), pixelWidth: 100, pixelHeight: 100)
        _ = try await screen.applyStateCommand(.snapshot([
            .init(viewModelName: "Runtime first scr_screens_sfirst", instanceID: "first-root", instanceName: nil,
                path: "experience/trip_days", value: .number(999)),
        ]))
        let value = try await screen.snapshot()
        XCTAssertEqual(value.values.first { $0.name == "trip_days" }?.value, .number(23))
        let root = try await screen.rootViewModel()
        let mutation = try await screen.mutateState([.setNumber(root, path: "experience/trip_days", value: 30)])
        XCTAssertTrue(mutation.effects.isEmpty, "Native run values must not enter the SDK's screen state store")
        try await screen.close()
    }

    func testRetiredRunRejectsNewScreensWhileMountedScreenCanClose() async throws {
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: SharedValuesFixture.payload())
        let run = ExperienceRunValues()
        let screen = try await preparation.openScreen(screenID: "first", runValues: run, pixelWidth: 100, pixelHeight: 100)
        await run.retire()
        do {
            _ = try await preparation.openScreen(screenID: "long", runValues: run, pixelWidth: 100, pixelHeight: 100)
            XCTFail("An ended run cannot open another screen")
        } catch {
            XCTAssertEqual(error as? ExperienceInteractiveScreenError, .stateContract("The run has ended"))
        }
        let retained = try await screen.snapshot()
        XCTAssertEqual(retained.values.first { $0.name == "trip_days" }?.value, .number(23))
        try await screen.close()
    }
    #endif

    func testJourneyReadsNativeRunValuesAfterEveryWrite() async throws {
        let prepared = try await NuxieNativePreparedFile.prepare(bytes: SharedValuesFixture.payload().sceneBytes)
        let run = ExperienceRunValues()
        let result = try await run.native(in: prepared)
        let native = try XCTUnwrap(result)
        for days: Float in [30, 7] {
            _ = try await native.sessions.mutate([.setNumber(instance: native.reference, path: "trip_days", value: days)])
            let fields = try await run.journeyValues()
            XCTAssertEqual(fields["trip_days"], .number(Double(days)))
            let context = ArmedJourney.Context(event: [:], responses: fields)
            XCTAssertEqual(JourneyValues.resolve(.responseField("trip_days"), context: context), .number(Double(days)))
        }
        await run.retire()
    }

    func testRetirementReleasesTheRunOwnedNativeHandle() async throws {
        let prepared = try await NuxieNativePreparedFile.prepare(bytes: SharedValuesFixture.payload().sceneBytes)
        let run = ExperienceRunValues()
        let result = try await run.native(in: prepared)
        let native = try XCTUnwrap(result)
        _ = try await native.sessions.snapshot(native.reference)
        await run.retire()
        do {
            _ = try await native.sessions.snapshot(native.reference)
            XCTFail("The ended run still owns its native handle")
        } catch {
            XCTAssertEqual(error as? NuxieNativeRuntimeError, .missingHandle("shared view model"))
        }
        await run.retire()
    }

    func testFileWithoutExperienceKeepsItsAuthoredScreenValues() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/native_input_owner.riv")
        let prepared = try await NuxieNativePreparedFile.prepare(bytes: Data(contentsOf: url))
        let run = ExperienceRunValues()
        let native = try await run.native(in: prepared)
        XCTAssertNil(native)
        let boards = try await prepared.artboards()
        let screen = try await prepared.openSession(artboardName: XCTUnwrap(boards.first).name,
            player: .defaultScene, pixelWidth: 100, pixelHeight: 100, bindDefaultViewModel: true)
        let before = try await screen.snapshot()
        XCTAssertEqual(before.values.first { $0.name == "answer" }?.value, .bytes(Data("answer".utf8)))
        await run.retire()
        let after = try await screen.snapshot()
        XCTAssertEqual(after.values.first { $0.name == "answer" }?.value, .bytes(Data("answer".utf8)))
        try await screen.close()
    }

    #if os(iOS)
    func testComponentCopyKeepsItsOwnCounter() async throws {
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: SharedValuesFixture.payload())
        let run = ExperienceRunValues()
        let screen = try await preparation.openScreen(screenID: "long", runValues: run, pixelWidth: 393, pixelHeight: 852)
        let catalog = await screen.viewModelCatalog
        let schema = try XCTUnwrap(catalog.schemas.first { $0.name == "Untitled" })
        let property = try XCTUnwrap(catalog.properties.first { $0.schemaIndex == schema.index && $0.name == "state:taps" })
        let layer = CAMetalLayer()
        layer.device = try await screen.metalDevice().value
        layer.pixelFormat = .bgra8Unorm
        layer.drawableSize = CGSize(width: 393, height: 852)
        let drawable = try XCTUnwrap(layer.nextDrawable())
        let completed = expectation(description: "Initial copy layout rendered")
        _ = try await screen.render(drawable: ExperienceInteractiveDrawable(drawable), completion: { completed.fulfill() })
        await fulfillment(of: [completed], timeout: 2)
        for _ in 0..<20 { _ = try await screen.step(elapsedSeconds: 0.016) }
        let expected = try SharedValuesFixture.expectations().component
        for expected in [expected.afterOneTap, expected.afterTwoTaps] {
            let down = try await screen.step(pointers: [.init(kind: .down, x: 100, y: 60)], elapsedSeconds: 0)
            let frame = try await screen.step(pointers: [.init(kind: .up, x: 100, y: 60)], elapsedSeconds: 0)
            let numbers = (down.effects + frame.effects).compactMap { effect -> Float? in
                guard case .viewModelChange(let change) = effect.kind,
                      change.propertyIndex == property.index,
                      case .number(let value) = change.value else { return nil }
                return value
            }
            XCTAssertTrue(numbers.contains(expected), "Component counter changes: \(numbers), hits: \(down.pointerHits), \(frame.pointerHits)")
        }
        try await screen.close()
    }
    #endif

}

enum SharedValuesFixture {
    struct Expectations: Decodable {
        struct StartingValues: Decodable {
            let trip: String
            let trip_days: Float
            let wants_reminder: Bool
        }
        struct Component: Decodable {
            let name: String
            let screen: String
            let privateValue: String
            let startingValue: Float
            let afterOneTap: Float
            let afterTwoTaps: Float
        }
        let model: String
        let property: String
        let startingValues: StartingValues
        let component: Component
    }

    static func expectations() throws -> Expectations {
        try JSONDecoder().decode(Expectations.self, from: Data(contentsOf: directory.appendingPathComponent("expectations.json")))
    }

    static var directory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/shared-values")
    }

    static func payload() throws -> AuthenticatedRuntimePayload {
        let scene = try Data(contentsOf: directory.appendingPathComponent("screen.riv"))
        struct Provenance: Decodable {
            struct Font: Decodable {
                let authoredAssetId: UInt64
                let assetUniqueName: String
                let weight: String
                let style: String
            }
            let fonts: [Font]
        }
        let provenance = try JSONDecoder().decode(Provenance.self,
            from: Data(contentsOf: directory.appendingPathComponent("provenance.json")))
        let screens = ["first", "long", "short"]
        return AuthenticatedRuntimePayload(authenticatedKeyID: "TEST_ONLY_DEV_KEYPAIR",
            requiredCapabilities: ["system-fonts"],
            renderPlan: NativeExperienceRenderPlan(
                identity: .init(experienceId: "shared-values", buildId: "shared-values-build", appId: "test-app", environment: "test"),
                scene: .init(key: "screen.riv", sha256: SHA256Provider.hexDigest(scene), sizeBytes: scene.count),
                entry: .init(screenId: "first"),
                screens: screens.map { .init(screenId: $0, artboardId: $0, artboardName: $0,
                    width: 393, height: 852, exit: nil) },
                transitions: [], textInputs: [], images: [], fonts: [],
                systemFonts: provenance.fonts.map { .init(authoredAssetId: $0.authoredAssetId,
                    assetUniqueName: $0.assetUniqueName, weight: $0.weight, style: $0.style) }),
            journey: JourneyDocument(screens: screens.map {
                JourneyScreen(id: $0, defaultViewModelName: "Runtime \($0) scr_screens_s\($0)", defaultInstanceId: "\($0)-root")
            }, viewModelValues: []), sceneBytes: scene, assets: [])
    }
}
#endif

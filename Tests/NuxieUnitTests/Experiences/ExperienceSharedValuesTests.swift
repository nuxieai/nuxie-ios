#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import QuartzCore
import XCTest
#if os(iOS)
import UIKit
#endif
@testable import Nuxie
@testable import NuxieRuntime

final class ExperienceSharedValuesTests: XCTestCase {
    // The published feedback screen declares the System font, which the SDK
    // prepares only where UIKit provides it (macOS refuses with unavailableFace).
    #if os(iOS)
    func testSaveCapturesItsStepBeforeAnotherScreenWritesOnTheSharedLane() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("forms-saves")
        let release = try JSONDecoder().decode(JourneyReleaseDescriptor.self,
            from: Data(contentsOf: directory.appendingPathComponent("release.json")))
        let base = try SharedValuesFixture.payload(directory: directory, screens: ["feedback"])
        let payload = AuthenticatedRuntimePayload(valuePolicy: release.valuePolicy,
            authenticatedKeyID: base.authenticatedKeyID, requiredCapabilities: base.requiredCapabilities,
            renderPlan: base.renderPlan, journey: base.journey, sceneBytes: base.sceneBytes, assets: base.assets)
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let a = try await preparation.openScreen(screenID: "feedback", runValues: run, pixelWidth: 393, pixelHeight: 852)
        let b = try await preparation.openScreen(screenID: "feedback", runValues: run, pixelWidth: 393, pixelHeight: 852)
        addTeardownBlock { try await a.close(); try await b.close() }
        let file = try await NuxieNativePreparedFile.prepare(bytes: base.sceneBytes, valuePolicy: release.valuePolicy.native)
        let prepared = try await run.native(in: file)
        let native = try XCTUnwrap(prepared)
        let aRuntime = try XCTUnwrap(Mirror(reflecting: a).children.first { $0.label == "runtime" }?.value as? NuxieNativeRuntime)
        let aRoot = try await aRuntime.rootViewModelReference()
        _ = try await aRuntime.mutateViewModel([.setNumber(instance: aRoot,
            path: "experience/responses:feedback/stars", value: 4)])
        _ = try await b.step(elapsedSeconds: 0)
        let pressed = try await b.step(pointers: [.init(kind: .down, x: 121, y: 1)], elapsedSeconds: 0)
        XCTAssertTrue(pressed.pointerHits.contains { $0 != .none }, "The enabled published Save button is hit")

        let entered = expectation(description: "shared lane is held")
        let releaseLane = DispatchSemaphore(value: 0)
        await native.sessions.enqueueForTesting { entered.fulfill(); releaseLane.wait() }
        defer { releaseLane.signal() }
        await fulfillment(of: [entered], timeout: 2)
        func waitForQueuedJobs(_ count: Int) async throws {
            let deadline = Date().addingTimeInterval(2)
            while await native.sessions.queuedJobCountForTesting < count {
                guard Date() < deadline else { throw CocoaError(.coderInvalidValue) }
                await Task.yield()
            }
        }
        let saving = Task { try await b.step(pointers: [.init(kind: .up, x: 121, y: 1)], elapsedSeconds: 0) }
        try await waitForQueuedJobs(1)
        let editing = Task { try await aRuntime.mutateViewModel([.setNumber(instance: aRoot,
            path: "experience/responses:feedback/stars", value: 5)]) }
        try await waitForQueuedJobs(2)
        releaseLane.signal()
        let result = try await saving.value
        _ = try await editing.value
        let save = try XCTUnwrap(result.effects.compactMap(\.responseSave).first)
        XCTAssertEqual(result.effects.compactMap(\.responseSave).count, 1)
        XCTAssertEqual(save.form, "feedback")
        XCTAssertEqual(save.answers, ["stars": .number(4)])
        let live = try await run.responseAnswers(form: "feedback", policy: release.valuePolicy)
        XCTAssertEqual(live, ["stars": .number(5)])
    }
    #endif

    #if os(iOS)
    func testBothPublishedGoalsScreensShareRestoredRows() async throws {
        let directory = SharedValuesFixture.directory.deletingLastPathComponent()
            .appendingPathComponent("forms-saves/goals")
        let payload = try SharedValuesFixture.payload(directory: directory, screens: ["goals", "quiet"])
        let prepared = try await NuxieNativePreparedFile.prepare(bytes: payload.sceneBytes)
        let original = ExperienceRunValues()
        addTeardownBlock { await original.retire() }
        let result = try await original.native(in: prepared)
        let native = try XCTUnwrap(result)
        _ = try await native.sessions.mutate([
            .listMove(instance: native.reference, path: "goals", from: 1, to: 0),
        ])
        let captured = try await original.snapshot()
        let checkpoint = try XCTUnwrap(captured)
        await original.retire()
        let restored = ExperienceRunValues(snapshot: checkpoint)
        addTeardownBlock { await restored.retire() }
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let first = try await preparation.openScreen(screenID: "goals", runValues: restored,
            pixelWidth: 393, pixelHeight: 852)
        addTeardownBlock { try await first.close() }
        let second = try await preparation.openScreen(screenID: "quiet", runValues: restored,
            pixelWidth: 393, pixelHeight: 852)
        addTeardownBlock { try await second.close() }
        let a = try await first.snapshot()
        let b = try await second.snapshot()
        let ownerA = try XCTUnwrap(a.values.first {
            $0.ownerInstanceID == a.rootInstanceID && $0.name == "experience"
        })
        let ownerB = try XCTUnwrap(b.values.first {
            $0.ownerInstanceID == b.rootInstanceID && $0.name == "experience"
        })
        XCTAssertEqual(ownerA.value, ownerB.value)
        guard case .referencedInstance(let owner) = ownerA.value else {
            return XCTFail("Both screens must bind the shared Experience")
        }
        let listA = try XCTUnwrap(a.values.first { $0.ownerInstanceID == owner && $0.name == "goals" })
        let listB = try XCTUnwrap(b.values.first { $0.ownerInstanceID == owner && $0.name == "goals" })
        XCTAssertEqual(listA.value, listB.value)
        guard case .list(let ids) = listA.value else { return XCTFail("Goals must remain a list") }
        XCTAssertEqual(ids.map { id in a.values.first { $0.ownerInstanceID == id && $0.name == "title" }?.value },
            [.bytes(Data("Walk".utf8)), .bytes(Data("Read".utf8))])
    }

    func testPublishedInputFocusTypingAndGreetingShareTheRun() async throws {
        let expected = try PublishedInputFixture.expectations()
        let payload = try SharedValuesFixture.payload(directory: PublishedInputFixture.directory,
            screens: expected.screens)
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let input = try await preparation.openScreen(screenID: "input", runValues: run,
            pixelWidth: 393, pixelHeight: 852)
        addTeardownBlock { try await input.close() }
        func handler(_ name: String) async throws -> ExperienceInteractiveViewModelValue? {
            let snapshot = try await input.snapshot()
            let state = snapshot.values.first { $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "state" }
            guard case .referencedInstance(let owner) = state?.value else {
                XCTFail("Published input has no screen state"); return nil
            }
            return snapshot.values.first { $0.ownerInstanceID == owner && $0.name == name }?.value
        }
        for item in expected.handlers.values {
            let value = try await handler(item.property)
            XCTAssertEqual(value, .number(item.before))
        }
        let initial = try await run.journeyValues()
        XCTAssertEqual(initial["name"], .string(expected.startingValues.name))
        let focused = try await input.step(focusInputs: [.next], elapsedSeconds: 0)
        XCTAssertEqual(focused.focusState, .init(hasFocus: true, expectsKeyboardInput: true))
        let focus = try XCTUnwrap(expected.handlers["focus"])
        let focusedValue = try await handler(focus.property)
        XCTAssertEqual(focusedValue, .number(focus.after))
        _ = try await input.step(focusInputs: [.key(code: 269, modifiers: 0, pressed: true, repeated: false)], elapsedSeconds: 0)
        let typed = try XCTUnwrap(expected.handlers["input"])
        let before = try await handler(typed.property)
        XCTAssertEqual(before, .number(typed.before), "Cursor movement must not invoke input")
        _ = try await input.step(focusInputs: [.text(expected.typing.append)], elapsedSeconds: 0)
        let edited = try await run.journeyValues()
        XCTAssertEqual(edited["name"], .string(expected.typing.after))
        let queued = try await handler(typed.property)
        XCTAssertEqual(queued, .number(typed.before), "The authored input reaction waits for the next advance")
        _ = try await input.step(elapsedSeconds: 0)
        let reacted = try await handler(typed.property)
        XCTAssertEqual(reacted, .number(typed.after))
        let blurred = try await input.step(focusInputs: [.next], elapsedSeconds: 0)
        XCTAssertEqual(blurred.focusState?.hasFocus, false)
        let blur = try XCTUnwrap(expected.handlers["blur"])
        let blurredValue = try await handler(blur.property)
        XCTAssertEqual(blurredValue, .number(blur.after))
        let greeting = try await preparation.openScreen(screenID: "greeting", runValues: run,
            pixelWidth: 393, pixelHeight: 852)
        addTeardownBlock { try await greeting.close() }
        let greetingSnapshot = try await greeting.snapshot()
        XCTAssertEqual(greetingSnapshot.values.first { $0.name == "name" }?.value,
            .bytes(Data(expected.typing.after.utf8)))
    }

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
    @MainActor
    func testFirstEntryChoiceUsesHostReduceMotionBeforeAnyAdvance() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/env-entry")
        let payload = try SharedValuesFixture.payload(directory: directory, screens: ["entry"])
        let experience = Experience(id: "env-entry", versionId: "entry-version", buildId: "entry-build",
            artifactContentHash: nil, authenticatedReleaseID: nil, behaviorPresentation: .fullScreenDefault,
            behaviorPresentationScreens: [:], assetBaseURL: directory, journey: payload.journey, definition: nil)
        for reduceMotion in [true, false] {
            let acquired = AcquiredExperienceArtifact(identity: .init(experienceId: experience.id, buildId: experience.buildId),
                sceneURL: directory.appendingPathComponent("screen.riv"), sceneBytes: payload.sceneBytes,
                assetURLsByUniqueName: [:], source: .cache, payload: payload,
                interactivePreparation: .init(cache: ExperienceInteractivePreparationCache(),
                    provenance: UUID().uuidString, payload: payload), products: [], resourceMetrics: .zero)
            let run = ExperienceRunValues()
            let controller = ExperienceScreenViewController(experience: experience, artifact: .init(acquired: acquired),
                screen: try XCTUnwrap(payload.renderPlan.screens.first), runValues: run, reduceMotion: reduceMotion,
                usesSystemDisplayLink: false, delegate: nil)
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            controller.view.layoutIfNeeded()
            addTeardownBlock { @MainActor in await controller.shutdownInteractiveScreen(); await run.retire() }
            try await controller.mountInteractiveScreen()
            let screen = try XCTUnwrap(Mirror(reflecting: controller).children.first {
                $0.label == "interactiveScreen"
            }?.value as? ExperienceInteractiveScreen)
            // Read the mounted state at the fixture's one-pixel-per-point resolution.
            _ = try await screen.resize(pixelWidth: 393, pixelHeight: 852, layoutScaleFactor: 1)
            let mountedEnv = try await screen.environmentSnapshot()
            XCTAssertEqual(mountedEnv?.values.first { $0.name == "reduceMotion" }?.value, .bool(reduceMotion))
            let pixels = try await renderCopyPixels(screen)
            let expectedX = reduceMotion ? 80 : 20
            let otherX = reduceMotion ? 20 : 80
            func pixel(_ data: Data, x: Int) -> [UInt8] {
                Array(data[(40 * 393 + x) * 4..<(40 * 393 + x) * 4 + 4])
            }
            XCTAssertEqual(pixel(pixels, x: expectedX), [0, 0, 0, 255],
                "First entry must select the host's still or motion state")
            XCTAssertEqual(pixel(pixels, x: otherX), [0x33, 0x22, 0x11, 255])
            try await screen.updateEnvironment(reduceMotion: !reduceMotion)
            let changedEnv = try await screen.environmentSnapshot()
            XCTAssertEqual(changedEnv?.values.first { $0.name == "reduceMotion" }?.value, .bool(!reduceMotion))
            _ = try await screen.step(elapsedSeconds: 0)
            let later = try await renderCopyPixels(screen)
            XCTAssertEqual(pixel(later, x: expectedX), [0, 0, 0, 255],
                "The fixture has no return transition: a late env write cannot repair entry")
        }
    }

    func testPublishedDeviceGlobalReachesScreenAndCopyBeforeFirstDraw() async throws {
        let expected = try PublishedRunValuesFixture.expectations()
        let payload = try SharedValuesFixture.payload(directory: PublishedRunValuesFixture.directory,
            screens: expected.screens)
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let file = try await NuxieNativePreparedFile.prepare(bytes: payload.sceneBytes)
        let catalog = await file.viewModelCatalog()
        let envSchema = try XCTUnwrap(catalog.schemas.first { $0.name == "env" })
        XCTAssertTrue(envSchema.isGlobal)
        XCTAssertEqual(Set(catalog.properties.filter { $0.schemaIndex == envSchema.index }.map(\.name)),
            Set(["reduceMotion", "safeArea"]))
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let first = try await preparation.openScreen(screenID: "device", runValues: run, pixelWidth: 393, pixelHeight: 852)
        let second = try await preparation.openScreen(screenID: "device", runValues: run, pixelWidth: 393, pixelHeight: 852)
        addTeardownBlock { try await first.close(); try await second.close() }
        let initialValue = try await first.environmentSnapshot()
        let initial = try XCTUnwrap(initialValue)
        let otherValue = try await second.environmentSnapshot()
        let other = try XCTUnwrap(otherValue)
        XCTAssertEqual(initial.rootInstanceID, other.rootInstanceID, "One run shares one env instance")
        XCTAssertEqual(initial.values.first { $0.name == "reduceMotion" }?.value, .bool(false))
        XCTAssertEqual(initial.values.first { $0.name == "top" }?.value, .number(0))
        try await first.enableSemantics()
        let before = try await renderCopyFrame(first, capturesSemantics: true)
        try await first.updateEnvironment(reduceMotion: true,
            safeArea: .init(top: 59, bottom: 0, left: 0, right: 0))
        _ = try await first.step(elapsedSeconds: 0)
        _ = try await second.step(elapsedSeconds: 0)
        let after = try await renderCopyFrame(first, capturesSemantics: true)
        // Static text in this published file has no semantic nodes. Inspect its actual ink.
        let beforeBands = renderedInkBands(before.pixels)
        let afterBands = renderedInkBands(after.pixels)
        XCTAssertEqual(beforeBands.count, 2, "Device and 0 are drawn before env writes")
        XCTAssertEqual(afterBands.count, 4, "Device, 59, Still and the input-free copy's Calm are drawn")
        let firstBand = try XCTUnwrap(beforeBands.first)
        let movedBand = try XCTUnwrap(afterBands.first)
        XCTAssertEqual(movedBand.lowerBound - firstBand.lowerBound, 39)
        let originalInk = before.pixels[(firstBand.lowerBound * 393 * 4)..<(firstBand.upperBound * 393 * 4)]
        let movedInk = after.pixels[(movedBand.lowerBound * 393 * 4)..<(movedBand.upperBound * 393 * 4)]
        XCTAssertEqual(originalInk.count, movedInk.count)
        // Integer translation can round Metal's antialiased channels by two units.
        XCTAssertTrue(zip(originalInk, movedInk).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
            "Device's unchanged ink moves by exactly the source's safe-area delta")
        let secondPixels = try await renderCopyPixels(second)
        XCTAssertEqual(secondPixels, after.pixels, "Both mounted screens draw the shared global")
        try await second.updateEnvironment(reduceMotion: false, safeArea: .zero)
        _ = try await first.step(elapsedSeconds: 0)
        let restored = try await renderCopyPixels(first)
        XCTAssertEqual(restored, before.pixels, "Live env updates restore the initial drawing on the other screen")
    }

    func testPublishedCopyDrawsSelectedValueOnItsFirstFrame() async throws {
        let expected = try PublishedRunValuesFixture.expectations()
        let payload = try SharedValuesFixture.payload(directory: PublishedRunValuesFixture.directory,
            screens: expected.screens)
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: payload)
        let file = try await NuxieNativePreparedFile.prepare(bytes: payload.sceneBytes)
        var frames: [Data] = []
        for level in [expected.level.tickValue, expected.level.noTickValue, expected.level.tickValue] {
            let run = ExperienceRunValues()
            addTeardownBlock { await run.retire() }
            // Prepare the run with the platform's imported System font before inspecting its handle.
            try await preparation.prepareRunValues(run)
            let prepared = try await run.native(in: file)
            let native = try XCTUnwrap(prepared)
            XCTAssertEqual(native.catalog.schemas.first { $0.index == native.schemaIndex }?.name, expected.model)
            let initial = try await run.journeyValues()
            XCTAssertEqual(initial["level"], .number(Double(expected.startingValues.level)))
            if level != expected.startingValues.level {
                _ = try await native.sessions.mutate([.setNumber(instance: native.reference, path: "level", value: level)])
            }
            let screen = try await preparation.openScreen(screenID: "level", runValues: run, pixelWidth: 393, pixelHeight: 852)
            addTeardownBlock { try await screen.close() }
            // No settling steps or preliminary draw: this is this copy's first rendered frame.
            frames.append(try await renderCopyPixels(screen))
        }
        for (index, frame) in frames.enumerated() {
            let provider = try XCTUnwrap(CGDataProvider(data: frame as CFData))
            let image = try XCTUnwrap(CGImage(width: 393, height: 852, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 393 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "F4 first frame \(index): level \(index == 1 ? expected.level.noTickValue : expected.level.tickValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(frames[0], frames[2], "Independent selected copies have identical first drawn pixels")
        // The republished source adds Next after the copy. Hiding Tick moves Next up.
        XCTAssertEqual(renderedInkBands(frames[0]).count, 3, "23, Tick and Next are drawn on the first selected frame")
        XCTAssertEqual(renderedInkBands(frames[1]).count, 2, "23 and Next remain when Tick is hidden")
        XCTAssertNotEqual(frames[0], frames[1])
    }

    func testComponentCopyKeepsItsOwnCounter() async throws {
        let preparation = try await ExperienceInteractivePreparation.prepare(payload: SharedValuesFixture.payload())
        let run = ExperienceRunValues()
        addTeardownBlock { await run.retire() }
        let screen = try await preparation.openScreen(screenID: "long", runValues: run, pixelWidth: 393, pixelHeight: 852)
        addTeardownBlock { try await screen.close() }
        _ = try await renderCopyPixels(screen)
        for _ in 0..<20 { _ = try await screen.step(elapsedSeconds: 0.016) }
        let initial = try await renderCopyPixels(screen)
        // Locate rendered ink using this platform's font, then ask the player which
        // ink belongs to an interactive copy. No authored size or probe point is assumed.
        var point: CGPoint?
        for y in 0..<852 {
            for x in 0..<393 where initial[(y * 393 + x) * 4..<(y * 393 + x) * 4 + 3] != initial[(y * 393 + 392) * 4..<(y * 393 + 392) * 4 + 3] {
                for subpixel in [0.125, 0.375, 0.625, 0.875] {
                    let candidate = CGPoint(x: Double(x) + 0.5, y: Double(y) + subpixel)
                    let hit = try await screen.step(pointers: [.init(kind: .down, x: Float(candidate.x), y: Float(candidate.y))], elapsedSeconds: 0)
                    _ = try await screen.step(pointers: [.init(kind: .exit, x: Float(candidate.x), y: Float(candidate.y))], elapsedSeconds: 0)
                    if hit.pointerHits.contains(where: { $0 != .none }) { point = candidate; break }
                }
                if point != nil { break }
            }
            if point != nil { break }
        }
        let ink = try XCTUnwrap(point, "The rendered copy has interactive ink")
        func hits(_ x: Double, _ y: Double) async throws -> Bool {
            let result = try await screen.step(pointers: [.init(kind: .down, x: Float(x), y: Float(y))], elapsedSeconds: 0)
            _ = try await screen.step(pointers: [.init(kind: .exit, x: Float(x), y: Float(y))], elapsedSeconds: 0)
            return result.pointerHits.contains { $0 != .none }
        }
        func edge(_ inside: Double, _ outside: Double, probe: (Double) async throws -> Bool) async throws -> Double {
            var yes = inside
            var no = outside
            for _ in 0..<20 {
                let mid = (yes + no) / 2
                if try await probe(mid) { yes = mid } else { no = mid }
            }
            return yes
        }
        let left = try await edge(ink.x, 0) { try await hits($0, ink.y) }
        let right = try await edge(ink.x, 393) { try await hits($0, ink.y) }
        let x = (left + right) / 2
        let top = try await edge(ink.y, 0) { try await hits(x, $0) }
        let bottom = try await edge(ink.y, 852) { try await hits(x, $0) }
        let bounds = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)
        let tap = CGPoint(x: bounds.midX, y: bounds.midY)
        let other = try await preparation.openScreen(screenID: "long", runValues: run, pixelWidth: 393, pixelHeight: 852)
        addTeardownBlock { try await other.close() }
        _ = try await renderCopyPixels(other)
        for _ in 0..<20 { _ = try await other.step(elapsedSeconds: 0.016) }
        let untouched = try await renderCopyPixels(other)
        let runBefore = try await run.journeyValues()
        var previous = try await renderCopyPixels(screen)
        XCTAssertEqual(previous, initial, "Probing bounds without releasing a press does not change the count")
        for _ in 0..<2 {
            let down = try await screen.step(pointers: [.init(kind: .down, x: Float(tap.x), y: Float(tap.y))], elapsedSeconds: 0)
            let up = try await screen.step(pointers: [.init(kind: .up, x: Float(tap.x), y: Float(tap.y))], elapsedSeconds: 0)
            XCTAssertTrue(down.pointerHits.contains(where: { $0 != .none }))
            XCTAssertTrue(up.pointerHits.contains(where: { $0 != .none }))
            for _ in 0..<3 { _ = try await screen.step(elapsedSeconds: 1.0 / 60.0) }
            let next = try await renderCopyPixels(screen)
            XCTAssertNotEqual(previous, next, "The private copy redraws its count after each tap")
            let otherPixels = try await renderCopyPixels(other)
            XCTAssertEqual(otherPixels, untouched, "Another copy sharing the run keeps its own counter")
            let runAfter = try await run.journeyValues()
            XCTAssertEqual(runAfter, runBefore, "The private counter does not change shared run values")
            previous = next
        }
    }
    private func renderedInkBands(_ pixels: Data) -> [Range<Int>] {
        let background = Array(pixels.suffix(4))
        let rows = (0..<852).filter { y in
            (0..<393).contains { x in
                let offset = (y * 393 + x) * 4
                return (0..<3).contains { abs(Int(pixels[offset + $0]) - Int(background[$0])) > 3 }
            }
        }
        var bands: [Range<Int>] = []
        for row in rows {
            if let last = bands.last, last.upperBound == row {
                bands[bands.count - 1] = last.lowerBound..<(row + 1)
            } else { bands.append(row..<(row + 1)) }
        }
        return bands
    }

    private func renderCopyPixels(_ screen: ExperienceInteractiveScreen) async throws -> Data {
        try await renderCopyFrame(screen, capturesSemantics: false).pixels
    }

    private func renderCopyFrame(_ screen: ExperienceInteractiveScreen, capturesSemantics: Bool) async throws
        -> (pixels: Data, semantics: NuxieNativeSemanticCapture?) {
        let device = try await screen.metalDevice().value
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 393, height: 852)
        let drawable = try XCTUnwrap(layer.nextDrawable())
        let stride = (393 * 4 + 255) & ~255
        let buffer = try XCTUnwrap(device.makeBuffer(length: stride * 852, options: .storageModeShared))
        let rendered = expectation(description: "Copy rendered")
        let frame = try await screen.renderFrame(layoutScaleFactor: 1, drawable: ExperienceInteractiveDrawable(drawable), clearColor: 0xFF11_2233,
            capturesSemantics: capturesSemantics, readback: NuxieNativeFrameReadback(buffer: buffer, bytesPerRow: stride),
            completion: { rendered.fulfill() })
        await fulfillment(of: [rendered], timeout: 2)
        var pixels = Data()
        for row in 0..<852 { pixels.append(buffer.contents().assumingMemoryBound(to: UInt8.self) + row * stride, count: 393 * 4) }
        XCTAssertEqual(frame.outcome.disposition, .presented)
        if capturesSemantics {
            let tree = XCTAttachment(string: String(describing: frame.semantics?.tree.nodes))
            tree.name = "F4 env semantic tree"; tree.lifetime = .keepAlways; add(tree)
            let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
            let image = try XCTUnwrap(CGImage(width: 393, height: 852, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 393 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue).union(.byteOrder32Little),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = "F4 env rendered frame"; attachment.lifetime = .keepAlways; add(attachment)
        }
        return (pixels, frame.semantics)
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

    static func payload(directory: URL = SharedValuesFixture.directory, screens: [String] = ["first", "long", "short"], scene suppliedScene: Data? = nil, textInputs: [NativeExperienceTextInput] = []) throws -> AuthenticatedRuntimePayload {
        let scene = try suppliedScene ?? Data(contentsOf: directory.appendingPathComponent("screen.riv"))
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
        return AuthenticatedRuntimePayload(authenticatedKeyID: "TEST_ONLY_DEV_KEYPAIR",
            requiredCapabilities: ["system-fonts"],
            renderPlan: NativeExperienceRenderPlan(
                identity: .init(experienceId: "shared-values", buildId: "shared-values-build", appId: "test-app", environment: "test"),
                scene: .init(key: "screen.riv", sha256: SHA256Provider.hexDigest(scene), sizeBytes: scene.count),
                entry: .init(screenId: try XCTUnwrap(screens.first)),
                screens: screens.map { .init(screenId: $0, artboardId: $0, artboardName: $0,
                    width: 393, height: 852, exit: nil) },
                transitions: [], textInputs: textInputs, images: [], fonts: [],
                systemFonts: provenance.fonts.map { .init(authoredAssetId: $0.authoredAssetId,
                    assetUniqueName: $0.assetUniqueName, weight: $0.weight, style: $0.style) }),
            journey: JourneyDocument(screens: screens.map {
                JourneyScreen(id: $0, defaultViewModelName: "Runtime \($0) scr_screens_s\($0)", defaultInstanceId: "\($0)-root")
            }, viewModelValues: []), sceneBytes: scene, assets: [])
    }
}

enum PublishedRunValuesFixture {
    struct Expectations: Decodable {
        struct StartingValues: Decodable { let trip_days: Float; let level: Float }
        struct Tap: Decodable { let buttonLabel: String; let before: Float; let after: Float }
        struct Level: Decodable { let tickValue: Float; let noTickValue: Float; let tickText: String }
        let model: String
        let property: String
        let screens: [String]
        let startingValues: StartingValues
        let tap: Tap
        let level: Level
    }

    static var directory: URL {
        SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("run-values")
    }

    static func expectations() throws -> Expectations {
        try JSONDecoder().decode(Expectations.self, from: Data(contentsOf: directory.appendingPathComponent("expectations.json")))
    }
}

enum PublishedInputFixture {
    struct Expectations: Decodable {
        struct StartingValues: Decodable { let name: String }
        struct Handler: Decodable { let property: String; let before: Float; let after: Float }
        struct Typing: Decodable { let append: String; let after: String }
        let screens: [String]
        let startingValues: StartingValues
        let handlers: [String: Handler]
        let typing: Typing
    }

    static var directory: URL {
        SharedValuesFixture.directory.deletingLastPathComponent().appendingPathComponent("published-input")
    }

    static func expectations() throws -> Expectations {
        try JSONDecoder().decode(Expectations.self,
            from: Data(contentsOf: directory.appendingPathComponent("expectations.json")))
    }
}
#endif

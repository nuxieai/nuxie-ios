#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import Foundation
import QuartzCore
import XCTest
@_spi(Testing) @testable import Nuxie
@testable import NuxieRuntime

final class ExperienceScreenExitReasonBindingTests: XCTestCase {
    func testDismissalAnimatesToCompletionWhileNavigationSkipsAndTheFinalPoseStaysHidden() async throws {
        let eventName = "nuxie:screen-exit-complete:scr_screens_stap"
        for reason in [ExperienceScreenExitReason.navigation, .dismissed] {
            let screen = try await openWitness("dismissed-only", player: .stateMachine("lifecycle"))
            do {
                var state = ExperienceScreenLifecycleState(reduceMotion: false)
                for phase in [ExperienceScreenLifecyclePhase.entering, .active] {
                    _ = try await screen.applyStateCommand(state.move(to: phase).stateCommand(
                        viewModelName: try modelName(), instanceID: "root-sdk-id"
                    ))
                    _ = try await screen.step(elapsedSeconds: 0)
                }
                let activeGreen = try await centerGreen(screen)
                XCTAssertGreaterThan(activeGreen, 245)
                _ = try await screen.applyStateCommand(state.move(to: .exiting, exitReason: reason).stateCommand(
                    viewModelName: try modelName(), instanceID: "root-sdk-id"
                ))
                let start = try await screen.step(elapsedSeconds: 0)
                if reason == .navigation {
                    XCTAssertEqual(completions(start, named: eventName), 1)
                    let skippedGreen = try await centerGreen(screen)
                    XCTAssertEqual(skippedGreen, activeGreen)
                } else {
                    XCTAssertEqual(completions(start, named: eventName), 0)
                    let middle = try await screen.step(elapsedSeconds: 0.2)
                    XCTAssertEqual(completions(middle, named: eventName), 0)
                    let middleGreen = try await centerGreen(screen)
                    XCTAssertGreaterThan(middleGreen, 20)
                    XCTAssertLessThan(Int(middleGreen), Int(activeGreen) - 20)
                    let beforeEnd = try await screen.step(elapsedSeconds: 0.19)
                    XCTAssertEqual(completions(beforeEnd, named: eventName), 0)
                    let completed = try await screen.step(elapsedSeconds: 0.02)
                    XCTAssertEqual(completions(completed, named: eventName), 1)
                    let finalGreen = try await centerGreen(screen)
                    XCTAssertLessThan(finalGreen, 5)
                    let settled = try await screen.step(elapsedSeconds: 0.1)
                    XCTAssertEqual(completions(settled, named: eventName), 0)
                    let settledGreen = try await centerGreen(screen)
                    XCTAssertEqual(settledGreen, finalGreen, "Completion must preserve the terminal pose")
                }
                try await screen.close()
            } catch {
                try? await screen.close()
                throw error
            }
        }
    }

    func testDeclaredExitReasonReceivesBothReasonsAndClearsAcrossVisits() async throws {
        let screen = try await openWitness("dismissed-only", player: .stateMachine("lifecycle"))
        do {
            let supportsReason = await screen.supportsScreenExitReason(viewModelName: try modelName())
            XCTAssertTrue(supportsReason)
            var state = ExperienceScreenLifecycleState(reduceMotion: false)
            let visits: [(ExperienceScreenLifecyclePhase, ExperienceScreenExitReason, UInt64)] = [
                (.entering, .none, 0),
                (.active, .none, 0),
                (.exiting, .navigation, 2),
                (.hidden, .none, 0),
                (.entering, .none, 0),
                (.active, .none, 0),
                (.exiting, .dismissed, 1),
            ]
            for (phase, reason, expected) in visits {
                let snapshot = state.move(to: phase, exitReason: reason)
                let written = try await screen.applyStateCommand(snapshot.stateCommand(
                    viewModelName: try modelName(), instanceID: "root-sdk-id"
                ))
                XCTAssertGreaterThanOrEqual(written.appliedCount, 4)
                _ = try await screen.step(elapsedSeconds: 0)
                let value = try await nativeScreenValue(screen, name: "exitReason")
                XCTAssertEqual(value, .integer(expected), "The real enum must accept the lifecycle reason")
            }
            try await screen.updateEnvironment(reduceMotion: true)
            let reduced = state.updateReduceMotion(true)
            _ = try await screen.applyStateCommand(reduced.stateCommand(
                viewModelName: try modelName(), instanceID: "root-sdk-id"
            ))
            let retainedReason = try await nativeScreenValue(screen, name: "exitReason")
            XCTAssertEqual(retainedReason, .integer(1))
            let appearances = try await nativeScreenValue(screen, name: "appearances")
            XCTAssertEqual(appearances, .number(2))
            try await screen.close()
        } catch {
            try? await screen.close()
            throw error
        }
    }

    func testOlderScreenKeepsItsLifecycleWritesWithoutAnExitReasonField() async throws {
        let screen = try await openWitness("field-absent", player: .staticArtboard)
        do {
            let supportsReason = await screen.supportsScreenExitReason(viewModelName: try modelName())
            XCTAssertFalse(supportsReason)
            var state = ExperienceScreenLifecycleState(reduceMotion: false)
            for phase in [ExperienceScreenLifecyclePhase.entering, .active, .exiting, .hidden, .entering] {
                let snapshot = state.move(to: phase, exitReason: .dismissed)
                let written = try await screen.applyStateCommand(snapshot.stateCommand(
                    viewModelName: try modelName(), instanceID: "root-sdk-id", includesExitReason: supportsReason
                ))
                XCTAssertGreaterThanOrEqual(written.appliedCount, 3)
                _ = try await screen.step(elapsedSeconds: 0)
            }
            let phase = try await nativeScreenValue(screen, name: "phase")
            let appearances = try await nativeScreenValue(screen, name: "appearances")
            let transition = try await nativeScreenValue(screen, name: "transition")
            XCTAssertEqual(phase, .integer(1))
            XCTAssertEqual(appearances, .number(2))
            XCTAssertEqual(transition, .bytes(Data()))
            try await screen.close()
        } catch {
            try? await screen.close()
            throw error
        }
    }

    private func modelName(_ variant: String = "dismissed-only") throws -> String {
        let path = experiencePreparationRepositoryRoot()
            .appendingPathComponent("fixtures/runtime/screen-exit-reason/\(variant)/mounted-screen.json")
        let descriptor = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let leg = try XCTUnwrap(descriptor["leg"] as? [String: Any])
        let screens = try XCTUnwrap(leg["screens"] as? [[String: Any]])
        return try XCTUnwrap(screens.first?["defaultViewModelName"] as? String)
    }

    private func openWitness(
        _ variant: String,
        player: ExperienceInteractivePlayerSelection
    ) async throws -> ExperienceInteractiveScreen {
        let path = experiencePreparationRepositoryRoot()
            .appendingPathComponent("fixtures/runtime/screen-exit-reason/\(variant)/screen.nux")
        let payload = try await statePayload(
            defaultViewModelName: try modelName(variant), values: [], scene: Data(contentsOf: path), artboardName: "tap"
        )
        return try await ExperienceInteractiveScreen.open(
            payload: payload, player: player, pixelWidth: 100, pixelHeight: 100
        )
    }

    private func nativeScreenValue(
        _ screen: ExperienceInteractiveScreen,
        name: String
    ) async throws -> ExperienceInteractiveViewModelValue {
        let snapshot = try await screen.snapshot()
        let group = try XCTUnwrap(snapshot.values.first {
            $0.ownerInstanceID == snapshot.rootInstanceID && $0.name == "screen"
        })
        guard case .referencedInstance(let screenID) = group.value else {
            XCTFail("The compiled Screen schema must bind a native child instance")
            throw WitnessError.screenNotBound
        }
        return try XCTUnwrap(snapshot.values.first {
            $0.ownerInstanceID == screenID && $0.name == name
        }).value
    }

    private func completions(_ step: ExperienceInteractiveStepResult, named name: String) -> Int {
        step.effects.filter {
            guard case .reportedEvent(let event) = $0.kind else { return false }
            return event.name == name
        }.count
    }

    private func centerGreen(_ screen: ExperienceInteractiveScreen) async throws -> UInt8 {
        let device = try await screen.metalDevice().value
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.drawableSize = CGSize(width: 100, height: 100)
        let drawable = try XCTUnwrap(layer.nextDrawable())
        let stride = (100 * 4 + 255) & ~255
        let buffer = try XCTUnwrap(device.makeBuffer(length: stride * 100, options: .storageModeShared))
        let rendered = expectation(description: "Read native exit pose")
        let frame = try await screen.renderFrame(
            layoutScaleFactor: 1, drawable: ExperienceInteractiveDrawable(drawable), clearColor: 0xFF00_0000,
            capturesSemantics: false, readback: NuxieNativeFrameReadback(buffer: buffer, bytesPerRow: stride),
            completion: { rendered.fulfill() }
        )
        await fulfillment(of: [rendered], timeout: 2)
        XCTAssertEqual(frame.outcome.disposition, .presented)
        return buffer.contents().assumingMemoryBound(to: UInt8.self)[50 * stride + 50 * 4 + 1]
    }

    private enum WitnessError: Error {
        case screenNotBound
    }
}
#endif

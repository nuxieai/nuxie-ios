import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class ExperiencePresentationServiceTests: AsyncSpec {
    override class func spec() {
        // nonisolated(unsafe): Quick runs beforeEach and each example strictly
        // serially, so these spec-level fixtures are never accessed
        // concurrently despite being captured by @MainActor example closures.
        nonisolated(unsafe) var service: ExperiencePresentationService!
        nonisolated(unsafe) var mockExperienceService: MockExperienceService!
        nonisolated(unsafe) var mockEventLog: MockEventLog!
        nonisolated(unsafe) var mockWindowProvider: MockWindowProvider!
        
        beforeEach { @MainActor in
            // Setup mock flow service
            mockExperienceService = MockExperienceService()

            // Setup mock event service
            mockEventLog = MockEventLog()

            // Setup mock window provider
            mockWindowProvider = MockWindowProvider()

            // Create service with mock collaborators
            service = ExperiencePresentationService(
                windowProvider: mockWindowProvider,
                experiences: mockExperienceService,
                eventLog: mockEventLog,
                triggerBroker: TriggerBroker(),
                dateProvider: MockDateProvider()
            )
        }

        func makeExperience(id: String) -> Experience {
            let publishedAt = ISO8601DateFormatter().string(from: Date())
            return Experience(
                id: id,
                versionId: "flow-test",
                name: "Test Experience",
                reentry: .oneTime,
                publishedAt: publishedAt,
                trigger: .event(EventTriggerConfig(eventName: "test_event", condition: nil)),
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                experienceType: nil
            )
        }
        
        afterEach { @MainActor in
            // Clean up
            mockWindowProvider.reset()
        }
        
        describe("presentExperience") {
            context("when presenting for a journey") {
                it("tracks $experience_shown exactly once on success") { @MainActor in
                    let flowId = "test-flow-journey"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    let experience = makeExperience(id: "experience-1")
                    let journey = Journey(experience: experience, distinctId: "user-1", now: Date())

                    try! await service.presentExperience(flowId, from: journey, runtimeDelegate: nil)

                    let experienceShownCount = mockEventLog.trackedEvents
                        .filter { $0.name == JourneyEvents.experienceShown }
                        .count
                    expect(experienceShownCount).to(equal(1))
                }

                it("does not track $experience_shown when presentation fails") { @MainActor in
                    let experience = makeExperience(id: "experience-1")
                    let journey = Journey(experience: experience, distinctId: "user-1", now: Date())

                    mockExperienceService.shouldFailExperienceDisplay = true
                    mockExperienceService.failureError = MockExperienceServiceError.experienceNotFound("missing-flow")

                    do {
                        _ = try await service.presentExperience("missing-flow", from: journey, runtimeDelegate: nil)
                        fail("Expected presentExperience to throw")
                    } catch {
                        // Expected.
                    }

                    let experienceShownCount = mockEventLog.trackedEvents
                        .filter { $0.name == JourneyEvents.experienceShown }
                        .count
                    expect(experienceShownCount).to(equal(0))
                }
            }

            context("when window scene is available") {
                it("should create a presentation window") { @MainActor in
                    // Setup
                    let flowId = "test-flow-1"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    
                    // Act
                    do {
                        _ = try await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    } catch {
                        fail("Unexpected presentExperience error: \(error)")
                    }
                    
                    // Assert
                    expect(service.isExperiencePresented).to(beTrue())
                    expect(mockWindowProvider.createdWindows.count).to(equal(1))
                    
                    let window = mockWindowProvider.createdWindows.first
                    expect(window?.presentCalled).to(beTrue())
                    expect(window?.presentedViewController).to(equal(mockVC))
                }
                
                it("should set up dismissal handler on flow view controller") { @MainActor in
                    // Setup
                    let flowId = "test-flow-handler"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    
                    // Present flow
                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    
                    // Verify onClose handler is set
                    expect(mockVC.onClose).toNot(beNil())
                }

                it("prepares a fresh runtime presentation before showing a cached controller") { @MainActor in
                    let flowId = "test-flow-reuse"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC

                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    expect(mockVC.prepareForPresentationCallCount).to(equal(1))

                    await service.dismissCurrentExperience()
                    expect(mockVC.shutdownRuntimeCallCount).to(equal(1))

                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    expect(mockVC.prepareForPresentationCallCount).to(equal(2))
                }
                
                it("should handle flow dismissal and cleanup") { @MainActor in
                    // Setup
                    let flowId = "test-flow-dismissal"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    
                    // Present flow
                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    expect(mockWindowProvider.createdWindows.count).to(equal(1))
                    
                    // Simulate dismissal via onClose callback
                    mockVC.onClose?(.userDismissed)
                    
                    // Wait for cleanup to complete
                    await polling(expect(service.isExperiencePresented)).value
                        .toEventually(beFalse(), timeout: .seconds(2))
                    
                    // Verify window was cleaned up
                    let window = mockWindowProvider.createdWindows.first
                    expect(window?.destroyCalled).to(beTrue())
                    expect(window?.presentedViewController).to(beNil())
                }
                
                it("should dismiss existing flow before presenting new one") { @MainActor in
                    // Present first flow
                    let flowId1 = "flow-1"
                    let mockVC1 = MockExperienceViewController(mockExperienceVersionId: flowId1)
                    mockExperienceService.mockViewControllers[flowId1] = mockVC1
                    
                    try! await service.presentExperience(flowId1, from: nil, runtimeDelegate: nil)
                    expect(service.isExperiencePresented).to(beTrue())
                    expect(mockWindowProvider.createdWindows.count).to(equal(1))
                    
                    // Present second flow
                    let flowId2 = "flow-2"
                    let mockVC2 = MockExperienceViewController(mockExperienceVersionId: flowId2)
                    mockExperienceService.mockViewControllers[flowId2] = mockVC2
                    
                    try! await service.presentExperience(flowId2, from: nil, runtimeDelegate: nil)
                    
                    // Should still be presenting (the new one)
                    expect(service.isExperiencePresented).to(beTrue())
                    
                    // Should have created a new window
                    expect(mockWindowProvider.createdWindows.count).to(equal(2))
                }

                it("ignores an old controller close callback after a newer flow is presented") { @MainActor in
                    let firstExperienceVersionId = "stale-close-first"
                    let firstVC = MockExperienceViewController(mockExperienceVersionId: firstExperienceVersionId)
                    mockExperienceService.mockViewControllers[firstExperienceVersionId] = firstVC
                    try! await service.presentExperience(firstExperienceVersionId, from: nil, runtimeDelegate: nil)
                    let staleOnClose = firstVC.onClose

                    let secondExperienceVersionId = "stale-close-second"
                    let secondVC = MockExperienceViewController(mockExperienceVersionId: secondExperienceVersionId)
                    mockExperienceService.mockViewControllers[secondExperienceVersionId] = secondVC
                    try! await service.presentExperience(secondExperienceVersionId, from: nil, runtimeDelegate: nil)
                    let secondWindow = mockWindowProvider.createdWindows[1]

                    staleOnClose?(.userDismissed)
                    await Task.yield()

                    expect(service.currentExperienceId).to(equal(secondExperienceVersionId))
                    expect(service.currentExperienceViewController).to(beIdenticalTo(secondVC))
                    expect(secondWindow.destroyCalled).to(beFalse())
                    expect(service.isExperiencePresented).to(beTrue())
                }

                it("ignores a delayed close fallback after reusing the same controller") { @MainActor in
                    let flowId = "stale-close-reused-controller"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)

                    mockVC.performDismiss(reason: .userDismissed)
                    await polling(expect(service.isExperiencePresented)).value
                        .toEventually(beFalse(), timeout: .seconds(1))

                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    try? await Task.sleep(nanoseconds: 600_000_000)

                    expect(service.currentExperienceViewController).to(beIdenticalTo(mockVC))
                    expect(service.isExperiencePresented).to(beTrue())
                }

                it("serializes cached-controller cleanup before a third presentation claims it") { @MainActor in
                    let flowId = "serialized-cleanup"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    mockWindowProvider.createdWindows[0].dismissDelay = 0.2

                    let superseded = Task { @MainActor in
                        // Boxed: Task success types must be Sendable.
                        PollingBox(try await service.presentExperience(flowId, from: nil, runtimeDelegate: nil))
                    }
                    await polling(expect { mockWindowProvider.createdWindows[0].dismissCalled }).value
                        .toEventually(beTrue(), timeout: .seconds(1))

                    let newest = Task { @MainActor in
                        // Boxed: Task success types must be Sendable.
                        PollingBox(try await service.presentExperience(flowId, from: nil, runtimeDelegate: nil))
                    }
                    do {
                        _ = try await superseded.value
                        fail("Expected the middle presentation attempt to be superseded")
                    } catch is CancellationError {
                        // Expected.
                    }
                    let newestController = try await newest.value.value

                    expect(newestController).to(beIdenticalTo(mockVC))
                    expect(mockVC.runtimeLifecycleEvents).to(equal([
                        "prepare",
                        "shutdown",
                        "prepare",
                    ]))
                    expect(mockWindowProvider.createdWindows.count).to(equal(2))
                    expect(service.currentExperienceViewController).to(beIdenticalTo(mockVC))
                }

                it("cancels an owned presentation attempt and tears down its window") { @MainActor in
                    let flowId = "cancelled-presentation"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    let gate = ExperiencePresentationTestGate()
                    mockVC.prepareForPresentationHandler = {
                        await gate.wait()
                    }
                    mockExperienceService.mockViewControllers[flowId] = mockVC

                    let presentation = Task { @MainActor in
                        // Boxed: Task success types must be Sendable.
                        PollingBox(try await service.presentExperience(flowId, from: nil, runtimeDelegate: nil))
                    }
                    await gate.waitUntilSuspended()
                    presentation.cancel()
                    gate.resume()

                    do {
                        _ = try await presentation.value
                        fail("Expected presentation cancellation")
                    } catch is CancellationError {
                        // Expected.
                    }

                    expect(mockVC.shutdownRuntimeCallCount).to(equal(1))
                    expect(mockWindowProvider.createdWindows.first?.destroyCalled).to(beTrue())
                    expect(service.currentExperienceViewController).to(beNil())
                    expect(service.isExperiencePresented).to(beFalse())
                }
                
                it("should present view controller in window") { @MainActor in
                    // Setup
                    let flowId = "test-key-window"
                    let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                    mockExperienceService.mockViewControllers[flowId] = mockVC
                    
                    // Present flow
                    try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                    
                    // Verify window presentation
                    let window = mockWindowProvider.createdWindows.first
                    expect(window?.presentCalled).to(beTrue())
                    expect(window?.isPresenting).to(beTrue())
                    expect(window?.presentedViewController).to(equal(mockVC))
                }
            }
            
            context("when window scene is not available") {
                beforeEach { @MainActor in
                    mockWindowProvider.simulateNoScene()
                }
                
                it("should throw noActiveScene error") { @MainActor in
                    do {
                        _ = try await service.presentExperience("test-flow", from: nil, runtimeDelegate: nil)
                        fail("Expected presentExperience to throw noActiveScene")
                    } catch let error as ExperiencePresentationError {
                        guard case .noActiveScene = error else {
                            fail("Expected .noActiveScene, got \(error)")
                            return
                        }
                    } catch {
                        fail("Unexpected error: \(error)")
                    }
                    
                    // Should not create any windows
                    expect(mockWindowProvider.createdWindows).to(beEmpty())
                }
            }
            
            context("when flow service fails") {
                it("should propagate flow service errors") { @MainActor in
                    // Setup flow service to fail
                    mockExperienceService.shouldFailExperienceDisplay = true
                    mockExperienceService.failureError = MockExperienceServiceError.experienceNotFound("missing-flow")
                    
                    // Act & Assert
                    do {
                        _ = try await service.presentExperience("missing-flow", from: nil, runtimeDelegate: nil)
                        fail("Expected presentExperience to throw")
                    } catch {
                        // Expected.
                    }
                    
                    // Should not create any windows
                    expect(mockWindowProvider.createdWindows).to(beEmpty())
                    expect(service.isExperiencePresented).to(beFalse())
                }
            }
        }
        
        describe("dismissCurrentExperience") {
            it("should dismiss presented flow") { @MainActor in
                // Present a flow first
                let flowId = "test-dismiss"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                expect(service.isExperiencePresented).to(beTrue())
                
                // Dismiss it
                await service.dismissCurrentExperience()
                
                // Verify dismissal
                expect(service.isExperiencePresented).to(beFalse())
                let window = mockWindowProvider.createdWindows.first
                expect(window?.dismissCalled).to(beTrue())
            }
            
            it("should handle dismissal when no flow is presented") { @MainActor in
                // No flow presented
                expect(service.isExperiencePresented).to(beFalse())
                
                // Should not crash
                await service.dismissCurrentExperience()
                
                // Still no flow
                expect(service.isExperiencePresented).to(beFalse())
            }

            it("detaches runtime ownership before destroying the window") { @MainActor in
                var lifecycle: [String] = []
                mockWindowProvider.onWindowLifecycleEvent = { lifecycle.append($0) }
                let flowId = "ordered-cleanup"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockVC.onRuntimeLifecycleEvent = { lifecycle.append("runtime-\($0)") }
                mockExperienceService.mockViewControllers[flowId] = mockVC
                try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                lifecycle.removeAll()

                await service.dismissCurrentExperience()

                expect(lifecycle).to(equal([
                    "window-dismiss",
                    "runtime-shutdown",
                    "window-destroy",
                ]))
            }
        }
        
        describe("isExperiencePresented") {
            it("should reflect presentation state accurately") { @MainActor in
                // Initially no flow
                expect(service.isExperiencePresented).to(beFalse())
                
                // Present flow
                let flowId = "state-test"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                expect(service.isExperiencePresented).to(beTrue())
                
                // Dismiss flow
                await service.dismissCurrentExperience()
                expect(service.isExperiencePresented).to(beFalse())
            }
        }
        
        describe("journey integration") {
            it("should accept journey context") { @MainActor in
                // Create mock experience and journey using TestBuilders
                let experience = makeExperience(id: "experience-1")

                let journey = Journey(
                    experience: experience,
                    distinctId: "user-1",
                    now: Date()
                )
                
                // Present with journey
                let flowId = "journey-flow"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                do {
                    _ = try await service.presentExperience(flowId, from: journey, runtimeDelegate: nil)
                } catch {
                    fail("Unexpected presentExperience error: \(error)")
                }
                
                // Verify presentation
                expect(service.isExperiencePresented).to(beTrue())
                
                // Verify journey context is stored
                expect(service.currentJourney?.id).toNot(beNil())
            }
            
            it("should handle nil journey context") { @MainActor in
                let flowId = "no-journey-flow"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                do {
                    _ = try await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                } catch {
                    fail("Unexpected presentExperience error: \(error)")
                }
                
                expect(service.isExperiencePresented).to(beTrue())
                expect(service.currentJourney).to(beNil())
            }
        }
        
        describe("window management") {
            it("should create window and present view controller") { @MainActor in
                let flowId = "window-props"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                
                let window = mockWindowProvider.createdWindows.first
                expect(window).toNot(beNil())
                expect(window?.presentCalled).to(beTrue())
                expect(window?.presentedViewController).to(equal(mockVC))
                expect(window?.isPresenting).to(beTrue())
            }
            
            it("should properly clean up window on dismissal") { @MainActor in
                let flowId = "cleanup-test"
                let mockVC = MockExperienceViewController(mockExperienceVersionId: flowId)
                mockExperienceService.mockViewControllers[flowId] = mockVC
                
                try! await service.presentExperience(flowId, from: nil, runtimeDelegate: nil)
                let window = mockWindowProvider.createdWindows.first
                
                // Simulate dismissal
                mockVC.onClose?(.purchaseCompleted)
                
                // Wait for cleanup
                await polling(expect(service.isExperiencePresented)).value
                    .toEventually(beFalse(), timeout: .seconds(2))
                
                // Verify cleanup
                expect(window?.destroyCalled).to(beTrue())
                expect(window?.presentedViewController).to(beNil())
            }
        }
    }
}

@MainActor
private final class ExperiencePresentationTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let waiters = suspensionWaiters
            suspensionWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilSuspended() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { continuation in
            suspensionWaiters.append(continuation)
        }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

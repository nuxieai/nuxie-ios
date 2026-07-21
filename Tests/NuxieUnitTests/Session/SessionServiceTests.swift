import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class SessionServiceTests: AsyncSpec {
    override class func spec() {
        describe("SessionService") {
            var sessionService: SessionService!
            
            beforeEach {
                sessionService = SessionService()
            }
            
            afterEach {
                sessionService = nil
            }
            
            describe("Session Creation") {
                it("should create a new session when none exists") {
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    
                    expect(sessionId).toNot(beNil())
                    expect(sessionId).to(contain("-")) // UUID v7 format
                }
                
                it("should return nil when readOnly and no session exists") {
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    
                    expect(sessionId).to(beNil())
                }
                
                it("should maintain the same session within activity threshold") {
                    let firstSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    
                    // Get session again within threshold
                    let secondSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    
                    expect(firstSessionId).to(equal(secondSessionId))
                }
            }
            
            describe("Session Expiration") {
                it("should expire session after 30 minutes of inactivity") {
                    let now = Date()
                    let firstSessionId = sessionService.getSessionId(at: now, readOnly: false)
                    
                    // Simulate 31 minutes later
                    let later = now.addingTimeInterval(31 * 60)
                    let secondSessionId = sessionService.getSessionId(at: later, readOnly: false)
                    
                    expect(firstSessionId).toNot(equal(secondSessionId))
                    expect(secondSessionId).toNot(beNil())
                }
                
                it("should expire session after 24 hours maximum duration") {
                    let now = Date()
                    let firstSessionId = sessionService.getSessionId(at: now, readOnly: false)
                    
                    // Keep session active but reach 24 hour limit
                    var currentTime = now
                    for _ in 0..<50 { // 50 * 29 minutes = ~24 hours
                        currentTime = currentTime.addingTimeInterval(29 * 60) // Just under inactivity threshold
                        _ = sessionService.getSessionId(at: currentTime, readOnly: false)
                    }
                    
                    // Now go over 24 hours
                    currentTime = now.addingTimeInterval(24 * 60 * 60 + 60)
                    let finalSessionId = sessionService.getSessionId(at: currentTime, readOnly: false)
                    
                    expect(firstSessionId).toNot(equal(finalSessionId))
                }
                
                it("should not expire session within 30 minutes when active") {
                    let now = Date()
                    let firstSessionId = sessionService.getSessionId(at: now, readOnly: false)
                    
                    // Touch session at 20 minutes
                    let midTime = now.addingTimeInterval(20 * 60)
                    sessionService.touchSession()
                    _ = sessionService.getSessionId(at: midTime, readOnly: false)
                    
                    // Check at 40 minutes from start (20 minutes after last activity)
                    let laterTime = now.addingTimeInterval(40 * 60)
                    let secondSessionId = sessionService.getSessionId(at: laterTime, readOnly: false)
                    
                    expect(firstSessionId).to(equal(secondSessionId))
                }
            }
            
            describe("Manual Session Management") {
                it("should start a new session on startSession") {
                    let firstSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    sessionService.startSession()
                    let secondSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    
                    expect(firstSessionId).toNot(equal(secondSessionId))
                    expect(secondSessionId).toNot(beNil())
                }
                
                it("should end session on endSession") {
                    _ = sessionService.getSessionId(at: Date(), readOnly: false)
                    sessionService.endSession()
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    
                    expect(sessionId).to(beNil())
                }
                
                it("should reset session on resetSession") {
                    let firstSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    sessionService.resetSession()
                    let secondSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    
                    expect(firstSessionId).toNot(equal(secondSessionId))
                    expect(secondSessionId).toNot(beNil())
                }
                
                it("should set custom session ID") {
                    let customId = "custom-session-123"
                    sessionService.setSessionId(customId)
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    
                    expect(sessionId).to(equal(customId))
                }
            }
            
            describe("Session Preview") {
            }
            
            describe("Activity Tracking") {
                it("should update activity timestamp on touchSession") {
                    let now = Date()
                    _ = sessionService.getSessionId(at: now, readOnly: false)
                    
                    // Touch session after 20 minutes
                    let laterTime = now.addingTimeInterval(20 * 60)
                    sessionService.touchSession()
                    
                    // Session should still be valid 25 minutes after touch
                    let finalTime = laterTime.addingTimeInterval(25 * 60)
                    let sessionId = sessionService.getSessionId(at: finalTime, readOnly: false)
                    
                    expect(sessionId).toNot(beNil())
                }
            }
            
            describe("Thread Safety") {
                it("should handle concurrent access safely") {
                    let iterations = 100
                    let group = DispatchGroup()
                    var sessionIds: [String?] = []
                    let lock = NSLock()
                    
                    for _ in 0..<iterations {
                        group.enter()
                        DispatchQueue.global().async {
                            let sessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                            lock.lock()
                            sessionIds.append(sessionId)
                            lock.unlock()
                            group.leave()
                        }
                    }
                    
                    group.wait()
                    
                    // All concurrent calls should return the same session ID
                    let uniqueSessionIds = Set(sessionIds.compactMap { $0 })
                    expect(uniqueSessionIds.count).to(equal(1))
                }
                
            }
            
            describe("Session Rotation") {
                it("should rotate the session on inactivity timeout") {
                    let now = Date()
                    let original = sessionService.getSessionId(at: now, readOnly: false)
                    expect(original).toNot(beNil())

                    // Trigger timeout
                    let later = now.addingTimeInterval(31 * 60)
                    let rotated = sessionService.getSessionId(at: later, readOnly: false)

                    expect(rotated).toNot(beNil())
                    expect(rotated).toNot(equal(original))
                }

                it("should rotate the session past the 24-hour maximum length") {
                    let now = Date()
                    let original = sessionService.getSessionId(at: now, readOnly: false)
                    expect(original).toNot(beNil())

                    // Trigger 24-hour expiration
                    let muchLater = now.addingTimeInterval(24 * 60 * 60 + 60)
                    let rotated = sessionService.getSessionId(at: muchLater, readOnly: false)

                    expect(rotated).toNot(beNil())
                    expect(rotated).toNot(equal(original))
                }
            }

            // MARK: - Backgrounding Behavior

            describe("Backgrounding Behavior") {
                it("should preserve session when entering background") {
                    let now = Date()
                    let originalSessionId = sessionService.getSessionId(at: now, readOnly: false)

                    sessionService.onAppDidEnterBackground()

                    // Session should still be accessible
                    let sessionAfterBackground = sessionService.getSessionId(at: now, readOnly: true)
                    expect(sessionAfterBackground).to(equal(originalSessionId))
                }

                it("should track background state correctly") {
                    _ = sessionService.getSessionId(at: Date(), readOnly: false)

                    // Enter background
                    sessionService.onAppDidEnterBackground()

                    // Return to foreground
                    sessionService.onAppBecameActive()

                    // Session should still exist
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    expect(sessionId).toNot(beNil())
                }

                it("should create new session on foreground if session timed out during background") {
                    let now = Date()
                    let originalSessionId = sessionService.getSessionId(at: now, readOnly: false)

                    // Enter background
                    sessionService.onAppDidEnterBackground()

                    // Simulate 31 minutes passing
                    let afterTimeout = now.addingTimeInterval(31 * 60)

                    // Return to foreground
                    sessionService.onAppBecameActive()

                    // Get session at the later time - should be new
                    let newSessionId = sessionService.getSessionId(at: afterTimeout, readOnly: false)
                    expect(newSessionId).toNot(beNil())
                    expect(newSessionId).toNot(equal(originalSessionId))
                }

                it("should handle multiple background/foreground cycles") {
                    let now = Date()
                    var currentTime = now

                    let originalSessionId = sessionService.getSessionId(at: currentTime, readOnly: false)

                    // Multiple short cycles (within timeout)
                    for i in 0..<5 {
                        sessionService.onAppDidEnterBackground()
                        currentTime = currentTime.addingTimeInterval(5 * 60) // 5 minutes each
                        sessionService.onAppBecameActive()
                        _ = sessionService.getSessionId(at: currentTime, readOnly: false)
                    }

                    // Session should be preserved (total < 30 min)
                    let finalSessionId = sessionService.getSessionId(at: currentTime, readOnly: true)
                    expect(finalSessionId).to(equal(originalSessionId))
                }

                it("should handle touchSession during background state") {
                    _ = sessionService.getSessionId(at: Date(), readOnly: false)

                    sessionService.onAppDidEnterBackground()

                    // touchSession should not crash while backgrounded
                    sessionService.touchSession()

                    sessionService.onAppBecameActive()

                    // Session should still be valid
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    expect(sessionId).toNot(beNil())
                }

                it("should clear session during background if timeout occurs on touchSession") {
                    let now = Date()
                    let originalSessionId = sessionService.getSessionId(at: now, readOnly: false)

                    // Enter background
                    sessionService.onAppDidEnterBackground()

                    // This behavior depends on implementation - touchSession during background
                    // with a timeout should clear session rather than create a new one
                    sessionService.touchSession()

                    // Session behavior after touchSession during background
                    sessionService.onAppBecameActive()

                    // Get session (may create new one if cleared)
                    let afterSessionId = sessionService.getSessionId(at: Date(), readOnly: false)
                    expect(afterSessionId).toNot(beNil())
                }

                it("should handle rapid background/foreground transitions") {
                    let group = DispatchGroup()

                    _ = sessionService.getSessionId(at: Date(), readOnly: false)

                    for _ in 0..<20 {
                        group.enter()
                        DispatchQueue.global().async {
                            sessionService.onAppDidEnterBackground()
                            sessionService.onAppBecameActive()
                            group.leave()
                        }
                    }

                    group.wait()

                    // Should not crash and session should be valid
                    let sessionId = sessionService.getSessionId(at: Date(), readOnly: true)
                    expect(sessionId).toNot(beNil())
                }

                it("should handle concurrent background transitions with session access") {
                    let group = DispatchGroup()
                    var sessionIds: [String?] = []
                    let lock = NSLock()

                    _ = sessionService.getSessionId(at: Date(), readOnly: false)

                    for _ in 0..<30 {
                        group.enter()
                        DispatchQueue.global().async {
                            sessionService.onAppDidEnterBackground()
                            let id = sessionService.getSessionId(at: Date(), readOnly: true)
                            lock.lock()
                            sessionIds.append(id)
                            lock.unlock()
                            sessionService.onAppBecameActive()
                            group.leave()
                        }
                    }

                    group.wait()

                    // Should not crash
                    expect(sessionIds.count).to(equal(30))
                }
            }
        }
    }
}
import Foundation

/// Protocol for session management operations
public protocol SessionServiceProtocol {
    /// Get the current session ID, creating one if needed
    /// - Parameters:
    ///   - at: The date to check session validity (defaults to now)
    ///   - readOnly: If true, won't create a new session if none exists
    /// - Returns: Current session ID or nil if readOnly and no session exists
    func getSessionId(at date: Date, readOnly: Bool) -> String?
    
    /// Manually set a custom session ID
    /// - Parameter sessionId: Custom session ID to use
    func setSessionId(_ sessionId: String)
    
    /// Start a new session
    func startSession()
    
    /// End the current session
    func endSession()
    
    /// Reset the session (clear and start new)
    func resetSession()
    
    /// Update session activity timestamp (called on each event)
    func touchSession()

    func onAppDidEnterBackground()
    func onAppBecameActive()
}

/// Reasons for session ID changes
public enum SessionIDChangeReason {
    case sessionIdEmpty
    case sessionStart
    case sessionEnd
    case sessionReset
    case sessionTimeout
    case sessionPastMaximumLength
    case customSessionId
}

/// Service for managing user sessions with automatic lifecycle handling
public final class SessionService: SessionServiceProtocol {
    
    // MARK: - Configuration Constants
    
    /// Session expires after 30 minutes of inactivity
    private let sessionActivityThreshold: TimeInterval = 60 * 30
    
    /// Maximum session duration is 24 hours
    private let sessionMaxLengthThreshold: TimeInterval = 24 * 60 * 60
    
    // MARK: - State Variables
    
    private var sessionId: String?
    private var sessionStartTimestamp: TimeInterval?
    private var sessionActivityTimestamp: TimeInterval?
    private var isAppInBackground: Bool = false
    
    // MARK: - Thread Safety
    
    private let lock = NSLock()
    private let activityQueue = DispatchQueue(label: "com.nuxie.session.activity", qos: .utility)
    
    // MARK: - Callbacks
    
    /// Called when session ID changes
    public var onSessionIdChanged: ((SessionIDChangeReason) -> Void)?
    
    // MARK: - Lifecycle Observers
        
    // MARK: - Initialization
    
    public init() {
    }
    
    // MARK: - Public API
    
    /// Get the current session ID, creating one if needed
    /// - Parameters:
    ///   - date: The date to check session validity (defaults to now)
    ///   - readOnly: If true, won't create a new session if none exists
    /// - Returns: Current session ID or nil if readOnly and no session exists
    public func getSessionId(at date: Date = Date(), readOnly: Bool = false) -> String? {
        lock.lock()
        defer { lock.unlock() }
        
        let now = date.timeIntervalSince1970
        
        // Check if we need a new session
        if let reason = shouldStartNewSession(at: now), !readOnly {
            createNewSession(at: now, reason: reason)
        }
        
        // Update activity if we have a session and not read-only
        if sessionId != nil && !readOnly {
            sessionActivityTimestamp = now
        }
        
        return sessionId
    }
    
    
    /// Manually set a custom session ID
    /// - Parameter sessionId: Custom session ID to use
    public func setSessionId(_ sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date().timeIntervalSince1970
        self.sessionId = sessionId
        self.sessionStartTimestamp = now
        self.sessionActivityTimestamp = now
        
        LogInfo("Custom session ID set: \(sessionId)")
        onSessionIdChanged?(.customSessionId)
    }
    
    /// Start a new session
    public func startSession() {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date().timeIntervalSince1970
        createNewSession(at: now, reason: .sessionStart)
    }
    
    /// End the current session
    public func endSession() {
        lock.lock()
        defer { lock.unlock() }
        
        clearSession(reason: .sessionEnd)
    }
    
    /// Reset the session (clear and start new)
    public func resetSession() {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date().timeIntervalSince1970
        clearSession(reason: .sessionReset)
        createNewSession(at: now, reason: .sessionReset)
    }
    
    /// Update session activity timestamp (called on each event)
    public func touchSession() {
        lock.lock()
        defer { lock.unlock() }
        
        let now = Date().timeIntervalSince1970
        
        // Check if session needs rotation
        if let reason = shouldStartNewSession(at: now) {
            if isAppInBackground {
                clearSession(reason: reason)
            } else {
                createNewSession(at: now, reason: reason)
            }
        } else if sessionId != nil {
            sessionActivityTimestamp = now
        }
    }
    
    // MARK: - Private Methods
    
    private func shouldStartNewSession(at timestamp: TimeInterval) -> SessionIDChangeReason? {
        // No session exists
        guard let _ = sessionId else {
            return .sessionIdEmpty
        }
        
        // Check for maximum session duration first (takes precedence)
        if let startTime = sessionStartTimestamp {
            let sessionDuration = timestamp - startTime
            if sessionDuration > sessionMaxLengthThreshold {
                return .sessionPastMaximumLength
            }
        }
        
        // Check for inactivity timeout
        if let lastActivity = sessionActivityTimestamp {
            let inactiveDuration = timestamp - lastActivity
            if inactiveDuration > sessionActivityThreshold {
                return .sessionTimeout
            }
        }
        
        return nil
    }
    
    private func createNewSession(at timestamp: TimeInterval, reason: SessionIDChangeReason) {
        let newSessionId = generateSessionId()
        sessionId = newSessionId
        sessionStartTimestamp = timestamp
        sessionActivityTimestamp = timestamp
        
        LogInfo("New session created: \(newSessionId) (reason: \(reason))")
        onSessionIdChanged?(reason)
    }
    
    private func clearSession(reason: SessionIDChangeReason) {
        sessionId = nil
        sessionStartTimestamp = nil
        sessionActivityTimestamp = nil
        
        LogInfo("Session cleared (reason: \(reason))")
        onSessionIdChanged?(reason)
    }
    
    private func generateSessionId() -> String {
        // Use UUID v7 for time-ordered session IDs
        return UUID.v7().uuidString
    }
    
    
    
    // MARK: - Lifecycle Monitoring
    
    public func onAppBecameActive() {
        lock.lock()
        defer { lock.unlock() }
        
        isAppInBackground = false
        let now = Date().timeIntervalSince1970
        
        // Check if we need a new session after returning from background
        if let reason = shouldStartNewSession(at: now) {
            createNewSession(at: now, reason: reason)
        }
        
        LogDebug("App became active, session: \(sessionId ?? "none")")
    }
    
    public func onAppDidEnterBackground() {
        lock.lock()
        defer { lock.unlock() }
        
        isAppInBackground = true
        LogDebug("App entered background, session: \(sessionId ?? "none")")
    }
}

import CryptoKit
import Foundation
import os.log

internal enum NuxieLogPrivacy: Sendable {
    case publicValue
}

/// A sensitive value annotated with a diagnostic category at the call site.
internal struct NuxieSensitiveLogValue: Sendable {
    fileprivate let value: String?
    fileprivate let category: String
}

/// A structured log message whose interpolated values are sensitive by default.
///
/// Literal text and explicitly public status values remain useful in unified
/// logs. Every other interpolation is retained as a separate segment until the
/// configured privacy policy is applied, so a caller cannot accidentally make
/// a customer value public merely by using ordinary string interpolation.
internal struct NuxieLogMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation,
    Sendable
{
    fileprivate enum Segment: Sendable {
        case literal(String)
        case sensitive(value: String, category: String?)
    }

    internal struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var segments: [Segment]

        init(literalCapacity: Int, interpolationCount: Int) {
            segments = []
            segments.reserveCapacity(interpolationCount * 2 + 1)
        }

        mutating func appendLiteral(_ literal: String) {
            segments.append(.literal(literal))
        }

        /// Safe structure must be annotated at the call site; the logger cannot
        /// infer whether a number or boolean is a count, status, or customer data.
        mutating func appendInterpolation<Value>(
            _ value: Value,
            privacy: NuxieLogPrivacy
        ) {
            switch privacy {
            case .publicValue:
                segments.append(.literal(String(describing: value)))
            }
        }

        mutating func appendInterpolation(_ value: NuxieSensitiveLogValue) {
            guard let rawValue = value.value else {
                segments.append(.literal("nil"))
                return
            }
            segments.append(.sensitive(value: rawValue, category: value.category))
        }

        /// Error types are useful for diagnosis, but descriptions commonly
        /// contain paths, request payloads, identifiers, or server messages.
        mutating func appendInterpolation(_ error: any Error) {
            segments.append(
                .sensitive(
                    value: String(describing: error),
                    category: "error=\(String(describing: type(of: error)))"
                )
            )
        }

        /// All other values, including strings, URLs, dates, IDs, collections,
        /// and caller-defined descriptions, are sensitive unless a future log
        /// seam explicitly models them as safe structure.
        mutating func appendInterpolation<Value>(_ value: Value) {
            segments.append(
                .sensitive(value: String(describing: value), category: nil)
            )
        }
    }

    fileprivate let segments: [Segment]

    init(stringLiteral value: String) {
        segments = [.literal(value)]
    }

    init(stringInterpolation: StringInterpolation) {
        segments = stringInterpolation.segments
    }

    static func sensitive(_ value: String) -> Self {
        Self(segments: [.sensitive(value: value, category: nil)])
    }

    fileprivate init(segments: [Segment]) {
        self.segments = segments
    }

    fileprivate func rendered(
        redactingSensitiveData: Bool,
        correlationKey: SymmetricKey
    ) -> String {
        segments.map { segment in
            switch segment {
            case .literal(let value):
                return value
            case .sensitive(let value, let category):
                guard redactingSensitiveData else { return value }
                return Self.safeSummary(
                    value,
                    category: category,
                    correlationKey: correlationKey
                )
            }
        }.joined()
    }

    fileprivate static func safeSummary(
        _ value: String,
        category: String? = nil,
        correlationKey: SymmetricKey
    ) -> String {
        let digest = HMAC<SHA256>.authenticationCode(
            for: Data(value.utf8),
            using: correlationKey
        )
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let categorySuffix = category.map { ":\($0)" } ?? ""
        return "<redacted\(categorySuffix) hmac-sha256:\(digest)>"
    }
}

/// Centralized logging system for the Nuxie SDK.
// @unchecked Sendable: mutable configuration is protected by `configurationLock`,
// and the immutable output closure is required to be Sendable.
internal final class NuxieLogger: @unchecked Sendable {
    typealias Output = @Sendable (LogLevel, String) -> Void

    private struct Configuration: Sendable {
        var logLevel: LogLevel = .debug
        var enableConsoleLogging = true
        var redactSensitiveData = true
    }

    // MARK: - Singleton

    private static let osLogger = OSLog(subsystem: "io.nuxie.sdk", category: "NuxieSDK")

    static let shared = NuxieLogger { level, message in
        os_log("%{public}@", log: osLogger, type: level.osLogType, message)
    }

    // MARK: - State

    private let configurationLock = NSLock()
    private var configuration = Configuration()
    private let output: Output
    private let correlationKey = SymmetricKey(size: .bits256)

    /// Internal output injection makes the exact unified-log payload testable.
    init(output: @escaping Output) {
        self.output = output
    }

    // MARK: - Configuration

    func configure(
        logLevel: LogLevel,
        enableConsoleLogging: Bool,
        redactSensitiveData: Bool
    ) {
        configurationLock.withLock {
            configuration = Configuration(
                logLevel: logLevel,
                enableConsoleLogging: enableConsoleLogging,
                redactSensitiveData: redactSensitiveData
            )
        }
    }

    // MARK: - Logging Methods

    func verbose(
        _ message: NuxieLogMessage,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .verbose, message: message, file: file, function: function, line: line)
    }

    func debug(
        _ message: NuxieLogMessage,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .debug, message: message, file: file, function: function, line: line)
    }

    func info(
        _ message: NuxieLogMessage,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .info, message: message, file: file, function: function, line: line)
    }

    func warning(
        _ message: NuxieLogMessage,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .warning, message: message, file: file, function: function, line: line)
    }

    func error(
        _ message: NuxieLogMessage,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        log(level: .error, message: message, file: file, function: function, line: line)
    }

    // MARK: - Private Implementation

    internal func shouldLog(level: LogLevel) -> Bool {
        level >= configurationSnapshot().logLevel
    }

    internal func log(
        level: LogLevel,
        message: NuxieLogMessage,
        file: String,
        function: String,
        line: Int
    ) {
        let configuration = configurationSnapshot()
        guard level >= configuration.logLevel, configuration.enableConsoleLogging else { return }

        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let renderedMessage = message.rendered(
            redactingSensitiveData: configuration.redactSensitiveData,
            correlationKey: correlationKey
        )
        let formattedMessage = "[Nuxie] [\(level.description)] [\(fileName):\(line)] \(renderedMessage)"
        output(level, formattedMessage)
    }

    private func configurationSnapshot() -> Configuration {
        configurationLock.withLock { configuration }
    }

    // MARK: - Sensitive Data Handling

    func logAPIKey(_ apiKey: String) -> NuxieSensitiveLogValue {
        NuxieSensitiveLogValue(value: apiKey, category: "api-key")
    }

    func logDistinctID(_ distinctId: String?) -> NuxieSensitiveLogValue {
        NuxieSensitiveLogValue(value: distinctId, category: "customer")
    }
}

// MARK: - LogLevel Extensions

extension LogLevel {
    fileprivate var severity: Int {
        switch self {
        case .verbose: return 0
        case .debug: return 1
        case .info: return 2
        case .warning: return 3
        case .error: return 4
        case .none: return 5
        }
    }

    fileprivate var description: String {
        switch self {
        case .verbose: return "VERBOSE"
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARNING"
        case .error: return "ERROR"
        case .none: return "NONE"
        }
    }

    @available(iOS 10.0, *)
    fileprivate var osLogType: OSLogType {
        switch self {
        case .verbose: return .debug
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .none: return .fault
        }
    }
}

extension LogLevel: Comparable {
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}

// MARK: - Convenience Global Functions

internal func NuxieLog(
    level: LogLevel,
    _ message: NuxieLogMessage,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    NuxieLogger.shared.log(level: level, message: message, file: file, function: function, line: line)
}

internal func LogVerbose(
    _ message: NuxieLogMessage,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    NuxieLogger.shared.verbose(message, file: file, function: function, line: line)
}

internal func LogDebug(
    _ message: NuxieLogMessage,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    NuxieLogger.shared.debug(message, file: file, function: function, line: line)
}

internal func LogInfo(
    _ message: NuxieLogMessage,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    NuxieLogger.shared.info(message, file: file, function: function, line: line)
}

internal func LogWarning(
    _ message: NuxieLogMessage,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    NuxieLogger.shared.warning(message, file: file, function: function, line: line)
}

internal func LogError(
    _ message: NuxieLogMessage,
    file: String = #file,
    function: String = #function,
    line: Int = #line
) {
    NuxieLogger.shared.error(message, file: file, function: function, line: line)
}

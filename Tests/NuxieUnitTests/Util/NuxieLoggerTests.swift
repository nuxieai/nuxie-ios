import Foundation
import Quick
import Nimble
import XCTest
@testable import Nuxie
@testable import NuxieTestSupport

private final class CapturedLogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var messages: [String] {
        lock.withLock { storage }
    }

    func append(_ message: String) {
        lock.withLock { storage.append(message) }
    }
}

private enum LoggerFixtureError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let value):
            return "storage failed for \(value)"
        }
    }
}

final class NuxieLoggerTests: QuickSpec {
    override class func spec() {
        describe("LogLevel ordering") {
            it("uses severity order instead of raw string order") {
                expect(LogLevel.verbose < .debug).to(beTrue())
                expect(LogLevel.debug < .info).to(beTrue())
                expect(LogLevel.info < .warning).to(beTrue())
                expect(LogLevel.warning < .error).to(beTrue())
                expect(LogLevel.error < .none).to(beTrue())
            }
        }

        describe("NuxieLogger filtering") {
            beforeEach {
                NuxieLogger.shared.configure(
                    logLevel: .warning,
                    enableConsoleLogging: false,
                    redactSensitiveData: true
                )
            }

            afterEach {
                NuxieLogger.shared.configure(
                    logLevel: .debug,
                    enableConsoleLogging: true,
                    redactSensitiveData: true
                )
            }

            it("still emits errors when configured for warnings") {
                expect(NuxieLogger.shared.shouldLog(level: .warning)).to(beTrue())
                expect(NuxieLogger.shared.shouldLog(level: .error)).to(beTrue())
                expect(NuxieLogger.shared.shouldLog(level: .info)).to(beFalse())
            }

            it("suppresses verbose logs when configured for info") {
                NuxieLogger.shared.configure(
                    logLevel: .info,
                    enableConsoleLogging: false,
                    redactSensitiveData: true
                )

                expect(NuxieLogger.shared.shouldLog(level: .verbose)).to(beFalse())
                expect(NuxieLogger.shared.shouldLog(level: .info)).to(beTrue())
                expect(NuxieLogger.shared.shouldLog(level: .error)).to(beTrue())
            }
        }
    }
}

final class NuxieLoggerPrivacyTests: XCTestCase {
    func testSharedLoggingPolicy() throws {
        struct PolicyFixture: Decodable {
            struct Level: Decodable { let threshold: String; let emitted: [String] }
            struct Privacy: Decodable { let redactSensitiveData: Bool; let containsSensitiveValue: Bool }
            let defaultLevel: String
            let defaultRedactSensitiveData: Bool
            let levels: [Level]
            let privacy: [Privacy]
        }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/logging/policy.json")
        let fixture = try JSONDecoder().decode(PolicyFixture.self, from: Data(contentsOf: url))
        let levels: [String: LogLevel] = ["NONE": .none, "ERROR": .error, "WARN": .warning,
                                         "INFO": .info, "DEBUG": .debug, "VERBOSE": .verbose]
        let configuration = NuxieConfiguration(apiKey: "pk_test_logging")
        XCTAssertEqual(configuration.logLevel, levels[fixture.defaultLevel])
        XCTAssertEqual(configuration.redactSensitiveData, fixture.defaultRedactSensitiveData)
        for vector in fixture.levels {
            let sink = CapturedLogSink()
            let logger = NuxieLogger { level, _ in sink.append(level.rawValue) }
            logger.configure(logLevel: try XCTUnwrap(levels[vector.threshold]), enableConsoleLogging: true,
                             redactSensitiveData: true)
            for name in ["ERROR", "WARN", "INFO", "DEBUG", "VERBOSE"] {
                logger.log(level: try XCTUnwrap(levels[name]), message: "Diagnostic", file: "Test.swift", function: "test", line: 1)
            }
            XCTAssertEqual(sink.messages, try vector.emitted.map { try XCTUnwrap(levels[$0]).rawValue }, vector.threshold)
        }
        for vector in fixture.privacy {
            let sink = CapturedLogSink()
            let logger = NuxieLogger { _, message in sink.append(message) }
            logger.configure(logLevel: .warning, enableConsoleLogging: true,
                             redactSensitiveData: vector.redactSensitiveData)
            logger.warning("Customer \("fixture-customer-secret")")
            XCTAssertEqual(sink.messages.joined().contains("fixture-customer-secret"), vector.containsSensitiveValue)
        }
    }

    func testRedactsNetworkStorageIdentityAndCallerInterpolations() {
        let sink = CapturedLogSink()
        let logger = NuxieLogger { _, message in sink.append(message) }
        logger.configure(
            logLevel: .debug,
            enableConsoleLogging: true,
            redactSensitiveData: true
        )

        let responseBody = #"{"email":"secret@example.com"}"#
        let storagePath = "/private/customer-123/events.sqlite"
        let customerId = "customer-123"
        let numericCustomerId = 8675309
        let callerValue = "authorization-token"
        let storageError: any Error = LoggerFixtureError.failed(storagePath)

        logger.error("HTTP \(401, privacy: .publicValue) response body: \(responseBody)")
        logger.error("Failed to open storage \(storagePath): \(storageError)")
        logger.info("Identifying user: \(customerId)")
        logger.info("Numeric customer: \(numericCustomerId)")
        logger.debug("Caller value: \(callerValue)")

        let output = sink.messages.joined(separator: "\n")
        XCTAssertTrue(output.contains("HTTP 401 response body:"))
        XCTAssertTrue(output.contains("LoggerFixtureError"))
        XCTAssertTrue(output.contains("sha256:"))
        XCTAssertFalse(output.contains("secret@example.com"))
        XCTAssertFalse(output.contains(storagePath))
        XCTAssertFalse(output.contains(customerId))
        XCTAssertFalse(output.contains(String(numericCustomerId)))
        XCTAssertFalse(output.contains(callerValue))
    }

    func testKeepsStableCorrelationSummariesWithoutDisclosure() {
        let sink = CapturedLogSink()
        let logger = NuxieLogger { _, message in sink.append(message) }
        logger.configure(
            logLevel: .debug,
            enableConsoleLogging: true,
            redactSensitiveData: true
        )

        logger.info("Customer \("customer-123")", file: "Test.swift", line: 1)
        logger.info("Customer \("customer-123")", file: "Test.swift", line: 1)
        logger.info("Customer \("customer-456")", file: "Test.swift", line: 1)

        XCTAssertEqual(sink.messages[0], sink.messages[1])
        XCTAssertNotEqual(sink.messages[2], sink.messages[0])
        XCTAssertFalse(sink.messages.joined().contains("customer-123"))
        XCTAssertFalse(sink.messages.joined().contains("customer-456"))
    }

    func testPreservesRawDiagnosticsWhenRedactionIsDisabled() {
        let sink = CapturedLogSink()
        let logger = NuxieLogger { _, message in sink.append(message) }
        logger.configure(
            logLevel: .debug,
            enableConsoleLogging: true,
            redactSensitiveData: false
        )

        let responseBody = #"{"email":"diagnostic@example.com"}"#
        let customerId = "diagnostic-customer"
        logger.error("HTTP \(503, privacy: .publicValue) response body: \(responseBody)")
        logger.info("Identifying user: \(customerId)")

        let output = sink.messages.joined(separator: "\n")
        XCTAssertTrue(output.contains("HTTP 503"))
        XCTAssertTrue(output.contains(responseBody))
        XCTAssertTrue(output.contains(customerId))
    }

    func testAppliesCurrentPrivacyPolicyWhenAnAnnotatedValueIsEmitted() {
        let sink = CapturedLogSink()
        let logger = NuxieLogger { _, message in sink.append(message) }
        logger.configure(
            logLevel: .debug,
            enableConsoleLogging: true,
            redactSensitiveData: false
        )
        let customer = logger.logDistinctID("customer-before-policy-change")

        logger.configure(
            logLevel: .debug,
            enableConsoleLogging: true,
            redactSensitiveData: true
        )
        logger.info("Customer: \(customer)")

        XCTAssertTrue(sink.messages.joined().contains("redacted:customer"))
        XCTAssertFalse(sink.messages.joined().contains("customer-before-policy-change"))
    }
}

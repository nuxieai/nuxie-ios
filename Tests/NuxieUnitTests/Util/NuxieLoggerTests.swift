import Quick
import Nimble
@testable import Nuxie
@testable import NuxieTestSupport

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

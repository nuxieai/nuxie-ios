import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class TimeWindowMathTests: QuickSpec {
    override class func spec() {
        let foundationUTC = TimeZone(secondsFromGMT: 0)!
        let utc = try! SignedTimezoneBundle.load().resolve("Etc/UTC")

        // 2026-07-15 is a Wednesday (weekday 4 in gregorian).
        func date(_ hour: Int, _ minute: Int, day: Int = 15) -> Date {
            var comps = DateComponents()
            comps.year = 2026
            comps.month = 7
            comps.day = day
            comps.hour = hour
            comps.minute = minute
            comps.timeZone = foundationUTC
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = foundationUTC
            return cal.date(from: comps)!
        }

        describe("resolveTimezone") {
            it("loads the pinned bundle and rejects aliases and unknown zones") {
                let bundle = try! SignedTimezoneBundle.load()
                expect(try? bundle.resolve("Etc/UTC")).toNot(beNil())
                expect(try? bundle.resolve("UTC")).to(beNil())
                expect(try? bundle.resolve("Not/AZone")).to(beNil())
            }

            it("maps the device token to the provided current timezone") {
                let tokyo = TimeZone(identifier: "Asia/Tokyo")!
                expect(TimeWindowMath.resolveTimezone("__current_device__", current: tokyo)?.identifier) == tokyo.identifier
            }

            it("resolves a named timezone") {
                expect(TimeWindowMath.resolveTimezone("America/New_York", current: .current)?.identifier)
                    == "America/New_York"
            }

            it("falls back to current for unknown identifiers") {
                let tokyo = TimeZone(identifier: "Asia/Tokyo")!
                expect(TimeWindowMath.resolveTimezone("Not/AZone", current: tokyo)).to(beNil())
            }
        }

        describe("parseTime") {
            it("parses HH:mm") {
                let parsed = TimeWindowMath.parseTime("09:30")
                expect(parsed?.hour) == 9
                expect(parsed?.minute) == 30
            }

            it("rejects malformed strings") {
                expect(TimeWindowMath.parseTime("930")).to(beNil())
                expect(TimeWindowMath.parseTime("9:30")).to(beNil())
                expect(TimeWindowMath.parseTime("9:3:0")).to(beNil())
                expect(TimeWindowMath.parseTime("aa:bb")).to(beNil())
                expect(TimeWindowMath.parseTime("24:00")).to(beNil())
                expect(TimeWindowMath.parseTime("23:60")).to(beNil())
                expect(TimeWindowMath.parseTime("💥:")).to(beNil())
                expect(TimeWindowMath.parseTime("-1:00")).to(beNil())
            }
        }

        describe("evaluate") {
            it("uses signed DST gap and fold rules") {
                let formatter = ISO8601DateFormatter()
                let spring = formatter.date(from: "2026-03-08T07:30:00Z")!
                let fold = formatter.date(from: "2026-11-01T05:15:00Z")!
                let newYork = try! SignedTimezoneBundle.load().resolve("America/New_York")
                expect(TimeWindowMath.evaluate(
                    now: spring, startTime: "03:00", endTime: "04:00", daysOfWeek: nil, timezone: newYork
                )) == .inWindow
                expect(TimeWindowMath.evaluate(
                    now: fold, startTime: "01:00", endTime: "01:30", daysOfWeek: nil, timezone: newYork
                )) == .inWindow
            }

            it("returns malformed for unparseable times") {
                let decision = TimeWindowMath.evaluate(
                    now: date(10, 0),
                    startTime: "oops",
                    endTime: "17:00",
                    daysOfWeek: nil,
                    timezone: utc
                )
                expect(decision) == .malformed
            }

            it("is in window between start and end") {
                let decision = TimeWindowMath.evaluate(
                    now: date(10, 0),
                    startTime: "09:00",
                    endTime: "17:00",
                    daysOfWeek: nil,
                    timezone: utc
                )
                expect(decision) == .inWindow
            }

            it("treats equal start and end as always open") {
                let decision = TimeWindowMath.evaluate(
                    now: date(3, 0),
                    startTime: "09:00",
                    endTime: "09:00",
                    daysOfWeek: nil,
                    timezone: utc
                )
                expect(decision) == .inWindow
            }

            it("handles windows crossing midnight") {
                expect(TimeWindowMath.evaluate(
                    now: date(23, 0),
                    startTime: "22:00",
                    endTime: "02:00",
                    daysOfWeek: nil,
                    timezone: utc
                )) == .inWindow
                expect(TimeWindowMath.evaluate(
                    now: date(1, 0),
                    startTime: "22:00",
                    endTime: "02:00",
                    daysOfWeek: nil,
                    timezone: utc
                )) == .inWindow
                expect(TimeWindowMath.evaluate(
                    now: date(12, 0),
                    startTime: "22:00",
                    endTime: "02:00",
                    daysOfWeek: nil,
                    timezone: utc
                )) == .pause(until: date(22, 0))
            }

            it("pauses until the same-day open when before the window") {
                let decision = TimeWindowMath.evaluate(
                    now: date(7, 30),
                    startTime: "09:00",
                    endTime: "17:00",
                    daysOfWeek: nil,
                    timezone: utc
                )
                expect(decision) == .pause(until: date(9, 0))
            }

            it("pauses until the next-day open when after the window") {
                let decision = TimeWindowMath.evaluate(
                    now: date(18, 0),
                    startTime: "09:00",
                    endTime: "17:00",
                    daysOfWeek: nil,
                    timezone: utc
                )
                expect(decision) == .pause(until: date(9, 0, day: 16))
            }

            it("pauses until midnight of the next valid day when today is excluded") {
                // Source weekday convention is 0=Sunday; Friday is 5.
                let decision = TimeWindowMath.evaluate(
                    now: date(10, 0),
                    startTime: "09:00",
                    endTime: "17:00",
                    daysOfWeek: [5],
                    timezone: utc
                )
                expect(decision) == .pause(until: date(0, 0, day: 17))
            }

            it("skips invalid days when computing the next open") {
                // Wednesday after close; valid days are Wednesday (3) and Friday (5):
                // next open is Friday 09:00 because Thursday is invalid.
                let decision = TimeWindowMath.evaluate(
                    now: date(18, 0),
                    startTime: "09:00",
                    endTime: "17:00",
                    daysOfWeek: [3, 5],
                    timezone: utc
                )
                expect(decision) == .pause(until: date(9, 0, day: 17))
            }

            it("treats Sunday as zero") {
                let decision = TimeWindowMath.evaluate(
                    now: date(10, 0, day: 19),
                    startTime: "09:00",
                    endTime: "17:00",
                    daysOfWeek: [0],
                    timezone: utc
                )
                expect(decision) == .inWindow
            }
        }
    }
}

import Foundation
import Quick
import Nimble
@testable import Nuxie
#if SWIFT_PACKAGE
@testable import NuxieTestSupport
#endif

final class TimeWindowMathTests: QuickSpec {
    override class func spec() {
        let utc = TimeZone(identifier: "UTC")!

        // 2026-07-15 is a Wednesday (weekday 4 in gregorian).
        func date(_ hour: Int, _ minute: Int, day: Int = 15) -> Date {
            var comps = DateComponents()
            comps.year = 2026
            comps.month = 7
            comps.day = day
            comps.hour = hour
            comps.minute = minute
            comps.timeZone = utc
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = utc
            return cal.date(from: comps)!
        }

        describe("resolveTimezone") {
            it("maps the device token to the provided current timezone") {
                let tokyo = TimeZone(identifier: "Asia/Tokyo")!
                expect(TimeWindowMath.resolveTimezone("__current_device__", current: tokyo)) == tokyo
            }

            it("resolves a named timezone") {
                expect(TimeWindowMath.resolveTimezone("America/New_York", current: .current))
                    == TimeZone(identifier: "America/New_York")!
            }

            it("falls back to current for unknown identifiers") {
                let tokyo = TimeZone(identifier: "Asia/Tokyo")!
                expect(TimeWindowMath.resolveTimezone("Not/AZone", current: tokyo)) == tokyo
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
                expect(TimeWindowMath.parseTime("9:3:0")).to(beNil())
                expect(TimeWindowMath.parseTime("aa:bb")).to(beNil())
            }
        }

        describe("evaluate") {
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
                // now is Wednesday (weekday 4); only Friday (6) is valid.
                let decision = TimeWindowMath.evaluate(
                    now: date(10, 0),
                    startTime: "09:00",
                    endTime: "17:00",
                    daysOfWeek: [6],
                    timezone: utc
                )
                expect(decision) == .pause(until: date(0, 0, day: 17))
            }

            it("skips invalid days when computing the next open") {
                // Wednesday after close; valid days are Wednesday (4) and Friday (6):
                // next open is Friday 09:00 because Thursday is invalid.
                let decision = TimeWindowMath.evaluate(
                    now: date(18, 0),
                    startTime: "09:00",
                    endTime: "17:00",
                    daysOfWeek: [4, 6],
                    timezone: utc
                )
                expect(decision) == .pause(until: date(9, 0, day: 17))
            }
        }
    }
}

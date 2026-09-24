import Foundation
import XCTest
@_spi(Testing) @testable import Nuxie

final class JourneyConversionWatchTests: XCTestCase {
    private struct Corpus: Decodable { let vectors: [Vector] }
    private struct Vector: Decodable {
        struct Event: Decodable {
            let id: String
            let name: String
            let occurredAt: Int
            let properties: [String: String]
            let journeyOrigin: JourneyEventOrigin?
        }
        let name: String
        let watches: [String: JourneyConversionWatch]
        let event: Event
        let acceptedAt: Int
        let expectedConversions: [String: String]
        let expectedBasis: [String: Int]?
    }

    func testIntegralWireMillisecondsSurviveFoundationDateRoundTrip() {
        for milliseconds in [1, 100, 60_101, 1_790_192_345_101] {
            let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            XCTAssertEqual(JourneyConversionWatch.millis(date), milliseconds)
        }
    }

    func testSharedAttributionVectors() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/conversion-watch.json")
        let corpus = try ExactJSONCodec.decode(Corpus.self, from: Data(contentsOf: url))
        for vector in corpus.vectors {
            var watches = vector.watches
            let event = NuxieEvent(id: vector.event.id, name: vector.event.name, forwardingName: vector.event.name, distinctId: "customer",
                properties: vector.event.properties,
                timestamp: Date(timeIntervalSince1970: Double(vector.event.occurredAt) / 1000),
                journeyOrigin: vector.event.journeyOrigin)
            let accepted = Date(timeIntervalSince1970: Double(vector.acceptedAt) / 1000)
            var matching = Set<String>()
            if let normalized = JourneyConversionWatch.normalized(event, acceptedAt: accepted) {
                for watch in watches.values where await watch.matches(normalized) {
                    matching.insert(watch.journeyId)
                }
            }
            JourneyConversionWatch.apply(event: event, acceptedAt: accepted, matching: matching, watches: &watches)
            XCTAssertEqual(watches.compactMapValues { $0.conversion?.eventId }, vector.expectedConversions, vector.name)
            for (journey, time) in vector.expectedBasis ?? [:] {
                XCTAssertEqual(watches[journey]?.basis?.occurredAt, time, vector.name)
            }
        }
    }
}

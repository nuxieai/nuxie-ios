import Foundation
import XCTest
@testable import Nuxie

final class ExactJSONCodecTests: XCTestCase {
    func testWideIntegersAndFailedArrayProbesPreserveTheirValues() throws {
        for value in [Int64.min, 9_007_199_254_740_993, Int64.max] {
            XCTAssertEqual(try ExactJSONCodec.decode(Int64.self, from: ExactJSONCodec.encode(value)), value)
        }
        XCTAssertEqual(try ExactJSONCodec.decode(UInt64.self, from: ExactJSONCodec.encode(UInt64.max)), UInt64.max)
        XCTAssertThrowsError(try ExactJSONCodec.decode(Int8.self, from: Data("128".utf8)))
        struct Probe: Decodable {
            let first: String
            let second: String
            init(from decoder: Decoder) throws {
                var values = try decoder.unkeyedContainer()
                XCTAssertThrowsError(try values.decode(Int.self))
                XCTAssertEqual(values.currentIndex, 0)
                XCTAssertThrowsError(try values.nestedUnkeyedContainer())
                XCTAssertEqual(values.currentIndex, 0)
                first = try values.decode(String.self)
                second = try values.decode(String.self)
                XCTAssertTrue(values.isAtEnd)
            }
        }
        let result = try ExactJSONCodec.decode(Probe.self, from: Data(#"["first","second"]"#.utf8))
        XCTAssertEqual(result.first, "first")
        XCTAssertEqual(result.second, "second")
    }

    func testExactNamesSurviveNestedValuesAndCanonicalOrder() throws {
        let left = Data(#"{"é":false,"e\u0301":true,"array":[{"é":1,"e\u0301":2}],"null":null}"#.utf8)
        let right = Data(#"{"null":null,"array":[{"e\u0301":2,"é":1}],"e\u0301":true,"é":false}"#.utf8)
        let object = try ExactJSONCodec.decode(ExactJSONObject<JourneyReleaseJSONValue>.self, from: left)
        XCTAssertThrowsError(try StrictJSONDuplicateKeyValidator.validate(left), "Legacy decoders still fail closed on keys they cannot retain")
        XCTAssertEqual(object.count, 4)
        guard case .bool(false) = object["é"], case .bool(true) = object["e\u{0301}"] else {
            return XCTFail("Each ordinal key must retain its own value")
        }
        let encoded = try ExactJSONCodec.encode(object)
        XCTAssertEqual(encoded, try ExactJSONCodec.canonicalize(left))
        XCTAssertEqual(encoded, try ExactJSONCodec.canonicalize(right))
        let decoded = try ExactJSONCodec.decode(ExactJSONObject<JourneyReleaseJSONValue>.self, from: encoded)
        XCTAssertEqual(decoded.count, 4)
        XCTAssertEqual(try ExactJSONCodec.encode(decoded), encoded)
    }

    func testDuplicateEscapesRemainRejectedAndInvalidScalarsFailClosed() throws {
        XCTAssertThrowsError(try ExactJSONCodec.decode(ExactJSONObject<Int>.self,
            from: Data(#"{"key":1,"\u006bey":2}"#.utf8)))
        XCTAssertThrowsError(try ExactJSONCodec.decode(Bool.self, from: Data("1".utf8)))
        XCTAssertThrowsError(try ExactJSONCodec.decode(Int.self, from: Data("true".utf8)))
        XCTAssertThrowsError(try ExactJSONCodec.decode(Int.self, from: Data("1.5".utf8)))
        XCTAssertThrowsError(try ExactJSONCodec.decode(UInt.self, from: Data("-1".utf8)))
        XCTAssertThrowsError(try ExactJSONCodec.encode(Double.infinity))
        XCTAssertThrowsError(try ExactJSONCodec.decode(JourneyReleaseJSONValue.self, from: Data("1e999".utf8)))
    }

    func testStandardContainersAndJournalDatesRoundTrip() throws {
        struct Record: Codable, Equatable {
            let id: String
            let values: [Int?]
            let flag: Bool
            let at: Date
            let fields: ExactJSONObject<String>
        }
        let original = Record(id: "journey", values: [1, nil, -2], flag: true,
                              at: Date(timeIntervalSince1970: 100.125), fields: ["é": "one", "e\u{0301}": "two"])
        XCTAssertEqual(try ExactJSONCodec.decode(Record.self, from: ExactJSONCodec.encode(original)), original)
    }
}

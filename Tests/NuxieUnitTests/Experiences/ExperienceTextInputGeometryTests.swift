#if canImport(UIKit)
import Foundation
import XCTest
@testable import Nuxie

final class ExperienceTextInputGeometryTests: XCTestCase {
    func testSharedEffectiveMetricCompatibility() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/text-input-effective-metrics.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 17)
        for item in cases {
            var values: [ExperienceInteractiveViewModelSnapshot.Value] = [
                .init(ownerInstanceID: 1, propertyIndex: 0, name: "nuxieTextInputs", value: .referencedInstance(2)),
                .init(ownerInstanceID: 2, propertyIndex: 0, name: "field", value: .referencedInstance(3)),
            ]
            let outputs = try XCTUnwrap(item["outputs"] as? [String: Any])
            for (index, entry) in outputs.sorted(by: { $0.key < $1.key }).enumerated() {
                let value: ExperienceInteractiveViewModelValue
                if let special = entry.value as? [String: String], let number = special["nativeNumber"] {
                    value = .number(number == "NaN" ? .nan : .infinity)
                } else if let number = entry.value as? NSNumber {
                    value = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.floatValue)
                } else if let string = entry.value as? String {
                    value = .bytes(Data(string.utf8))
                } else { value = .unsupported }
                values.append(.init(ownerInstanceID: 3, propertyIndex: index, name: entry.key, value: value))
            }
            let resolver = ExperienceTextInputGeometryResolver(snapshot: .init(rootInstanceID: 1, instances: [], values: values))
            let expected = (item["expected"] as? [String: NSNumber]).map {
                ExperienceTextInputMetrics(fontSize: $0["fontSize"]!.doubleValue, lineHeight: $0["lineHeight"]!.doubleValue)
            }
            let name = try XCTUnwrap(item["name"] as? String)
            for prefix in ["", "Root/"] {
                XCTAssertEqual(resolver.metrics(xPath: "\(prefix)nuxieTextInputs/field/x", authored: .init(fontSize: 18, lineHeight: 24)),
                    expected, name)
            }
        }
    }

    func testSharedGeometryPathsAndBounds() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/text-input-geometry.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let entries = try XCTUnwrap(fixture["values"] as? [[String: Any]])
        let values: [ExperienceInteractiveViewModelSnapshot.Value] = try entries.enumerated().map { index, entry in
            let value: ExperienceInteractiveViewModelValue
            switch try XCTUnwrap(entry["type"] as? String) {
            case "reference": value = .referencedInstance(try XCTUnwrap(entry["reference"] as? NSNumber).uint64Value)
            case "string": value = .bytes(Data())
            case "number":
                let number: Float
                if let finite = entry["number"] as? NSNumber {
                    number = finite.floatValue
                } else {
                    switch try XCTUnwrap(entry["number"] as? String) {
                    case "NaN": number = .nan
                    case "Infinity": number = .infinity
                    case "-Infinity": number = -.infinity
                    default: throw NSError(domain: "unknown fixture number", code: 1)
                    }
                }
                value = .number(number)
            default: throw NSError(domain: "unknown fixture value", code: 1)
            }
            return .init(ownerInstanceID: try XCTUnwrap(entry["owner"] as? NSNumber).uint64Value,
                         propertyIndex: index, name: try XCTUnwrap(entry["name"] as? String), value: value)
        }
        let instances: [ExperienceInteractiveViewModelSnapshot.Instance] = try XCTUnwrap(fixture["instances"] as? [NSNumber]).map { id in
            let indices = values.indices.filter { values[$0].ownerInstanceID == id.uint64Value }
            return .init(id: id.uint64Value, schemaIndex: 0,
                         valueRange: (indices.first ?? 0)..<((indices.last ?? -1) + 1))
        }
        let resolver = ExperienceTextInputGeometryResolver(snapshot: .init(
            rootInstanceID: try XCTUnwrap(fixture["rootInstanceId"] as? NSNumber).uint64Value,
            instances: instances, values: values))
        let queries = try XCTUnwrap(fixture["queries"] as? [[String: Any]])
        XCTAssertEqual(queries.count, 21)
        for query in queries {
            let path = try XCTUnwrap(query["path"] as? String)
            XCTAssertEqual(resolver.number(at: path), (query["expected"] as? NSNumber)?.doubleValue, path)
        }
        let cases = try XCTUnwrap(fixture["geometryCases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 12)
        for item in cases {
            let paths = try XCTUnwrap(item["paths"] as? [String: String])
            func path(_ key: String) throws -> String { try XCTUnwrap(paths[key]) }
            let actual = try resolver.geometry(for: .init(
                xPath: path("xPath"), yPath: path("yPath"), widthPath: path("widthPath"),
                heightPath: path("heightPath"), rotationPath: path("rotationPath"),
                scaleXPath: path("scaleXPath"), scaleYPath: path("scaleYPath")))
            let components = actual.map { [$0.x, $0.y, $0.width, $0.height, $0.rotation, $0.scaleX, $0.scaleY] }
            let name = try XCTUnwrap(item["name"] as? String)
            XCTAssertEqual(components, (item["expected"] as? [NSNumber])?.map(\.doubleValue), name)
        }
    }
}
#endif

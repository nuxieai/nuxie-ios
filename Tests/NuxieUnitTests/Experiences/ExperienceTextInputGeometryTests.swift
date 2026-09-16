#if canImport(UIKit)
import Foundation
import UIKit
@testable import NuxieRuntime
import XCTest
@testable import Nuxie

final class ExperienceTextInputGeometryTests: XCTestCase {
    @MainActor
    func testSharedAffineCornersAndNativeHitTesting() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/text-input-affine.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 8)
        let parent = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        let viewport = try XCTUnwrap(ExperienceContainCenterTransform(
            artboardBounds: CGRect(x: 0, y: 0, width: 400, height: 400),
            viewportBounds: CGRect(x: 100, y: 100, width: 400, height: 400)))
        for item in cases {
            let name = try XCTUnwrap(item["name"] as? String)
            let values = try XCTUnwrap(item["transform"] as? [Double])
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            let placement = ExperienceTextInputPlacement(geometry: .init(renderRevision: 1,
                worldTransform: matrix, contentTransform: matrix, textBounds: .zero,
                layout: .init(transform: matrix, bounds: CGRect(x: 0, y: 0, width: 10, height: 20)),
                firstBaseline: 7), viewport: viewport)
            guard let expected = item["corners"] as? [Double] else {
                XCTAssertNil(placement, name)
                continue
            }
            let resolved = try XCTUnwrap(placement, name)
            let editor = UITextView(frame: .zero)
            parent.addSubview(editor)
            resolved.apply(to: editor)
            let corners = [CGPoint.zero, CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 20), CGPoint(x: 0, y: 20)]
            for (index, point) in corners.enumerated() {
                let actual = editor.convert(point, to: parent)
                XCTAssertEqual(actual.x, expected[index * 2] + 100, accuracy: 0.001, name)
                XCTAssertEqual(actual.y, expected[index * 2 + 1] + 100, accuracy: 0.001, name)
            }
            let target = CGPoint(x: (expected[0] + expected[4]) / 2 + 100,
                y: (expected[1] + expected[5]) / 2 + 100)
            let hit = try XCTUnwrap(parent.hitTest(target, with: nil), name)
            XCTAssertTrue(hit === editor || hit.isDescendant(of: editor), name)
            XCTAssertEqual(try XCTUnwrap(resolved.firstBaseline).y, 7, accuracy: 0.001, name)
            editor.removeFromSuperview()
        }
    }

    func testAffinePlacementIncludesLayoutOriginAndContainOffset() throws {
        let viewport = try XCTUnwrap(ExperienceContainCenterTransform(
            artboardBounds: CGRect(x: 10, y: 20, width: 100, height: 100),
            viewportBounds: CGRect(x: 0, y: 0, width: 400, height: 200)))
        let matrix = CGAffineTransform(a: 2, b: 0, c: 0.5, d: 3, tx: 24, ty: 32)
        let placement = try XCTUnwrap(ExperienceTextInputPlacement(geometry: .init(renderRevision: 1,
            worldTransform: matrix, contentTransform: matrix, textBounds: .zero,
            layout: .init(transform: matrix, bounds: CGRect(x: 5, y: 7, width: 10, height: 20)),
            firstBaseline: 15), viewport: viewport))
        let origin = CGPoint.zero.applying(placement.transform)
        XCTAssertEqual(origin.x, 155, accuracy: 0.001)
        XCTAssertEqual(origin.y, 66, accuracy: 0.001)
        XCTAssertEqual(placement.textOrigin.x, -5, accuracy: 0.001)
        XCTAssertEqual(placement.textOrigin.y, -7, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(placement.firstBaseline).y, 8, accuracy: 0.001)
    }

    func testSharedEffectiveMetricCompatibility() throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/journeys/planes/text-input-effective-metrics.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let cases = try XCTUnwrap(fixture["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, 18)
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

import Foundation
import XCTest

final class CanonicalExperienceContractTests: XCTestCase {
    func testMigrationVocabularyAndAdaptersCannotReturn() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scopedRoots = [
            root.appendingPathComponent("Sources/Nuxie/Experiences"),
            root.appendingPathComponent("Sources/Nuxie/Journey"),
            root.appendingPathComponent("Sources/Nuxie/Profile"),
            root.appendingPathComponent("fixtures/journeys/planes"),
            root.appendingPathComponent("Tests/ExperienceRuntimeHostApp/Fixtures"),
        ]
        let forbidden = [
            #"\b(?:Experience|Journey)[A-Za-z0-9_]*V2\b"#,
            #"definitionV2"#,
            #"screen-actions-v2"#,
            #"experience-release-descriptor-v2"#,
            #"nuxie\.response\.v2"#,
            #"LEGACY_JOURNEY_TESTS"#,
            #"set_response_field"#,
            #"\bDevice"# + #"Leg[A-Za-z0-9_]*\b"#,
            #"\bdevice[- ]"# + #"leg(?:s)?\b"#,
            #"\$(?:event_sent|experiment_exposure_(?:error|fallback)|journey_(?:claimed|converted|effect_(?:completed|requested)|enrolled|exited|handoff|parked|started|superseded|transition))\b"#,
        ].map { try! NSRegularExpression(pattern: $0) }

        var violations: [String] = []
        for scopedRoot in scopedRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: scopedRoot,
                includingPropertiesForKeys: [.isRegularFileKey]
            ) else {
                return XCTFail("Missing canonical contract root: \(scopedRoot.path)")
            }
            for case let file as URL in enumerator {
                if file.lastPathComponent == "CanonicalExperienceContractTests.swift" { continue }
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                      let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                for pattern in forbidden where pattern.firstMatch(in: text, range: range) != nil {
                    violations.append(file.path.replacingOccurrences(of: root.path + "/", with: ""))
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "Migration-era Experience/Journey contract returned in: \(Set(violations).sorted())"
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "Sources/Nuxie/Experiences/Runtime/ExperienceDefinitionV2.swift"
            ).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                "fixtures/experience-release-descriptor-v2"
            ).path
        ))
    }
}

import Foundation
import XCTest

@testable import Nuxie

final class JourneyStorePathSafetyTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "JourneyStorePathSafetyTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
        temporaryRoot = nil
    }

    func testActiveJourneyIdentifiersBecomeBoundedOpaqueV1FileNames() throws {
        let identifiers = hostileIdentifiers
        let store = makeStore()

        for identifier in identifiers {
            try store.saveJourney(makeJourney(id: identifier))
        }

        let files = try contents(of: activeDirectory)
        XCTAssertEqual(files.count, identifiers.count)
        XCTAssertTrue(files.allSatisfy { isOpaqueV1Name(
            $0.lastPathComponent,
            prefix: "journey_v1_",
            suffix: ".json"
        ) })
        XCTAssertTrue(files.allSatisfy { $0.lastPathComponent.utf8.count < 128 })
        XCTAssertTrue(try files.allSatisfy {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        })
        XCTAssertEqual(try contents(of: temporaryRoot).map(\.lastPathComponent), ["nuxie"])

        for identifier in identifiers {
            XCTAssertEqual(store.loadJourney(id: identifier)?.id, identifier)
        }
    }

    func testUnicodeNormalizationVariantsUseDifferentExactByteKeys() throws {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let store = makeStore()

        try store.saveJourney(makeJourney(id: composed))
        let firstName = try XCTUnwrap(contents(of: activeDirectory).first?.lastPathComponent)
        try store.saveJourney(makeJourney(id: decomposed))
        let names = Set(try contents(of: activeDirectory).map(\.lastPathComponent))

        XCTAssertEqual(names.count, 2)
        XCTAssertTrue(names.contains(firstName))
        XCTAssertEqual(store.loadJourney(id: composed)?.id.unicodeScalars.map(\.value),
                       composed.unicodeScalars.map(\.value))
        XCTAssertEqual(store.loadJourney(id: decomposed)?.id.unicodeScalars.map(\.value),
                       decomposed.unicodeScalars.map(\.value))
    }

    func testLegacyRawJourneyFileIsIgnored() throws {
        let store = makeStore()
        let journey = makeJourney(id: "legacy")
        let file = activeDirectory.appendingPathComponent("journey_legacy.json")
        try encoded(journey).write(to: file, options: .atomic)

        XCTAssertNil(store.loadJourney(id: journey.id))
        XCTAssertTrue(store.loadActiveJourneys().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testActiveJourneyPayloadMustMatchItsOpaqueKey() throws {
        let store = makeStore()
        try store.saveJourney(makeJourney(id: "requested"))
        let file = try XCTUnwrap(contents(of: activeDirectory).first)
        try encoded(makeJourney(id: "substituted")).write(to: file, options: .atomic)

        XCTAssertNil(store.loadJourney(id: "requested"))
        XCTAssertTrue(store.loadActiveJourneys().isEmpty)
    }

    func testCompletionIdentifiersBecomeBoundedOpaqueV1Components() throws {
        let store = makeStore()
        let record = makeCompletion(
            distinctId: String(repeating: "../customer/", count: 1_000),
            experienceId: String(repeating: "../../experience/", count: 1_000)
        )

        try store.recordCompletion(record)

        let userDirectories = try contents(of: completedDirectory)
        XCTAssertEqual(userDirectories.count, 1)
        XCTAssertTrue(isOpaqueV1Name(
            userDirectories[0].lastPathComponent,
            prefix: "user_v1_",
            suffix: ""
        ))
        let files = try contents(of: userDirectories[0])
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(isOpaqueV1Name(
            files[0].lastPathComponent,
            prefix: "experience_v1_",
            suffix: ".json"
        ))
        XCTAssertTrue(store.hasCompletedExperience(
            distinctId: record.distinctId,
            experienceId: record.experienceId
        ))
        XCTAssertEqual(store.lastCompletionTime(
            distinctId: record.distinctId,
            experienceId: record.experienceId
        ), record.completedAt)
    }

    func testCompletionPayloadMustMatchItsOpaqueKeys() throws {
        let store = makeStore()
        let requested = makeCompletion(distinctId: "customer", experienceId: "experience")
        try store.recordCompletion(requested)
        let userDirectory = try XCTUnwrap(contents(of: completedDirectory).first)
        let file = try XCTUnwrap(contents(of: userDirectory).first)
        let substituted = makeCompletion(
            distinctId: "another-customer",
            experienceId: "another-experience"
        )
        try encoded([substituted]).write(to: file, options: .atomic)

        XCTAssertFalse(store.hasCompletedExperience(
            distinctId: requested.distinctId,
            experienceId: requested.experienceId
        ))
        XCTAssertNil(store.lastCompletionTime(
            distinctId: requested.distinctId,
            experienceId: requested.experienceId
        ))
        XCTAssertThrowsError(try store.recordCompletion(requested))
    }

    func testCompletionValidationUsesExactUnicodeBytes() throws {
        let composed = "caf\u{00E9}"
        let decomposed = "cafe\u{0301}"
        let store = makeStore()
        let requested = makeCompletion(
            distinctId: composed,
            experienceId: composed
        )
        try store.recordCompletion(requested)
        let userDirectory = try XCTUnwrap(contents(of: completedDirectory).first)
        let file = try XCTUnwrap(contents(of: userDirectory).first)
        let substituted = makeCompletion(
            distinctId: decomposed,
            experienceId: decomposed
        )
        try encoded([substituted]).write(to: file, options: .atomic)

        XCTAssertFalse(store.hasCompletedExperience(
            distinctId: composed,
            experienceId: composed
        ))
        XCTAssertThrowsError(try store.recordCompletion(requested))
    }

    func testLegacyRawCompletionFileIsIgnored() throws {
        let store = makeStore()
        let record = makeCompletion(distinctId: "customer", experienceId: "experience")
        let legacyUserDirectory = completedDirectory.appendingPathComponent(
            record.distinctId,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: legacyUserDirectory,
            withIntermediateDirectories: true
        )
        let legacyFile = legacyUserDirectory.appendingPathComponent(
            "experience_\(record.experienceId).json"
        )
        try encoded([record]).write(to: legacyFile, options: .atomic)

        XCTAssertFalse(store.hasCompletedExperience(
            distinctId: record.distinctId,
            experienceId: record.experienceId
        ))
        XCTAssertNil(store.lastCompletionTime(
            distinctId: record.distinctId,
            experienceId: record.experienceId
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
    }

    private var hostileIdentifiers: [String] {
        [
            "",
            "../escape",
            "nested/path",
            "windows\\path",
            String(repeating: "x", count: 20_000),
            "null-byte-like-%00",
            "emoji-🧑🏽‍💻",
        ]
    }

    private var journeysDirectory: URL {
        temporaryRoot.appendingPathComponent("nuxie/journeys", isDirectory: true)
    }

    private var activeDirectory: URL {
        journeysDirectory.appendingPathComponent("active", isDirectory: true)
    }

    private var completedDirectory: URL {
        journeysDirectory.appendingPathComponent("completed", isDirectory: true)
    }

    private func makeStore() -> JourneyStore {
        JourneyStore(
            customStoragePath: temporaryRoot,
            dateProvider: SystemDateProvider()
        )
    }

    private func makeJourney(id: String) -> JourneySnapshot {
        JourneySnapshot(
            id: id,
            experience: Experience(
                id: "experience",
                versionId: "flow",
                name: "Experience",
                reentry: .everyTime,
                releaseCreatedAt: "2026-01-01T00:00:00Z",
                trigger: nil,
                goal: nil,
                exitPolicy: nil,
                conversionAnchor: nil,
                experienceType: nil
            ),
            distinctId: "customer",
            now: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func makeCompletion(
        distinctId: String,
        experienceId: String
    ) -> JourneyCompletionRecord {
        JourneyCompletionRecord(
            experienceId: experienceId,
            distinctId: distinctId,
            journeyId: "journey",
            completedAt: Date(timeIntervalSince1970: 2_000),
            exitReason: .completed
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func contents(of directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func isOpaqueV1Name(
        _ name: String,
        prefix: String,
        suffix: String
    ) -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let digest = name[start..<end]
        return digest.count == 64 && digest.allSatisfy {
            $0.isHexDigit && !$0.isUppercase
        }
    }
}

import CoreText
import Foundation
import NuxieRuntime
import XCTest
#if canImport(UIKit)
import UIKit
#endif

final class ExperienceRuntimeSystemFontProviderTests: XCTestCase {
    #if canImport(UIKit)
    func testDeviceFontExtractionPreservesVariableTablesAndChecksums() throws {
        for weight in ["100", "400", "700", "900"] {
            let candidate = try ExperienceRuntimeSystemFontProvider.prepare(weight: weight, style: "normal")
            XCTAssertEqual(candidate.extraction, .file, "Supported simulator lane should exercise readable system font extraction")
            let face = try ExperienceRuntimeFontData.face(in: candidate.bytes, at: 0)
            let native = UIFont.systemFont(ofSize: 17, weight: ExperienceRuntimeSystemFontProvider.uiWeight(Int(weight)!)) as CTFont
            for tag: UInt32 in [0x66766172, 0x67766172, 0x61766172, 0x48564152, 0x4D564152] {
                XCTAssertEqual(face.tables[tag], CTFontCopyTable(native, tag, []) as Data?)
            }
            XCTAssertTrue(ExperienceRuntimeFontRegistry.isValidFontData(candidate.bytes))
            XCTAssertEqual(checksum(candidate.bytes), 0xB1B0AFBA)
            XCTAssertEqual(candidate.contentSHA256.count, 64)
            XCTAssertTrue(candidate.sourceIdentity.contains(ProcessInfo.processInfo.operatingSystemVersionString))
        }
    }

    func testExtractedAndReassembledFacesImportThroughExistingNativeCallback() async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/runtime/font-scale-policy")
        let scene = try Data(contentsOf: directory.appendingPathComponent("screen.riv"))
        let assets = try await NuxieNativeRuntime.inspectAssets(bytes: scene)
        let font = try XCTUnwrap(assets.first { $0.kind == .font })
        for weight in ["400", "700"] {
            for useFallback in [false, true] {
                let candidate = useFallback
                    ? try ExperienceRuntimeSystemFontProvider.prepare(weight: weight, style: "normal", readFile: { _ in Data() })
                    : try ExperienceRuntimeSystemFontProvider.prepare(weight: weight, style: "normal")
                let runtime = try await NuxieNativeRuntime.open(
                    bytes: scene, artboardName: "Paywall", player: .defaultScene,
                    pixelWidth: 390, pixelHeight: 844, bindDefaultViewModel: true,
                    importMode: .configured(moduleName: "nuxie", expectedAssets: assets,
                        externalAssets: [font.ordinal: candidate.bytes])
                )
                do {
                    let step = try await runtime.step(elapsedSeconds: 0, textRunNames: ["bound Run", "fixed Run", "natural Run"])
                    guard case .captured(let fields) = step.textGeometry else {
                        try await runtime.close()
                        return XCTFail("Expected text geometry after System font import")
                    }
                    XCTAssertEqual(fields.count, 3)
                    try await runtime.close()
                } catch {
                    try? await runtime.close()
                    throw error
                }
            }
        }
    }

    func testUnreadableBackingFileUsesCoreTextTableFallback() throws {
        struct Unreadable: Error {}
        let candidate = try ExperienceRuntimeSystemFontProvider.prepare(weight: "700", style: "normal", readFile: { _ in throw Unreadable() })
        XCTAssertEqual(candidate.extraction, .tables)
        XCTAssertTrue(ExperienceRuntimeFontRegistry.isValidFontData(candidate.bytes))
        XCTAssertEqual(checksum(candidate.bytes), 0xB1B0AFBA)
    }

    func testWrongOrMalformedBackingFileUsesSelectedFaceTables() throws {
        for data in [Data(), Data([0, 1, 0, 0])] {
            let candidate = try ExperienceRuntimeSystemFontProvider.prepare(weight: "400", style: "normal", readFile: { _ in data })
            XCTAssertEqual(candidate.extraction, .tables)
            XCTAssertTrue(ExperienceRuntimeFontRegistry.isValidFontData(candidate.bytes))
        }
    }
    #endif

    func testUnsupportedRequestsFailBeforeReadingFiles() {
        for (weight, style) in [("450", "normal"), ("0400", "normal"), ("400", "italic"), ("1000", "normal")] {
            XCTAssertThrowsError(try ExperienceRuntimeSystemFontProvider.prepare(weight: weight, style: style, readFile: { _ in
                XCTFail("invalid request must not read a font")
                return Data()
            })) { error in
                XCTAssertEqual(error as? ExperienceRuntimeSystemFontProvider.Failure, .unsupportedRequest)
            }
        }
    }

    func testReassemblyHasSortedDirectoryPaddingAndIndependentChecksum() throws {
        let head = Data(repeating: 0, count: 54)
        let face = ExperienceRuntimeFontData.Face(version: 0x00010000, tables: [
            0x68656164: head, 0x66766172: Data([1, 2, 3]), 0x44534947: Data([99]),
        ])
        let bytes = try ExperienceRuntimeFontData.assemble(face)
        XCTAssertEqual(bytes.prefix(12), Data([0, 1, 0, 0, 0, 2, 0, 32, 0, 1, 0, 0]))
        XCTAssertEqual(bytes.subdata(in: 12..<16), Data("fvar".utf8))
        XCTAssertEqual(bytes.subdata(in: 16..<20), Data([1, 2, 3, 0]))
        XCTAssertEqual(bytes.subdata(in: 20..<28), Data([0, 0, 0, 44, 0, 0, 0, 3]))
        XCTAssertEqual(bytes.subdata(in: 44..<48), Data([1, 2, 3, 0]))
        XCTAssertEqual(checksum(bytes), 0xB1B0AFBA)
    }

    func testCollectionUsesAbsoluteOffsetsAndSelectsRequestedFace() throws {
        // Two tiny directories share one header table, but have distinct fvar data.
        var bytes = Data([0x74, 0x74, 0x63, 0x66, 0, 1, 0, 0, 0, 0, 0, 2, 0, 0, 0, 20, 0, 0, 0, 64])
        for tableOffset: UInt8 in [162, 166] {
            bytes.append(contentsOf: [0, 1, 0, 0, 0, 2, 0, 32, 0, 1, 0, 0])
            bytes.append(contentsOf: [0x68, 0x65, 0x61, 0x64, 0, 0, 0, 0, 0, 0, 0, 108, 0, 0, 0, 54])
            bytes.append(contentsOf: [0x66, 0x76, 0x61, 0x72, 0, 0, 0, 0, 0, 0, 0, tableOffset, 0, 0, 0, 4])
        }
        bytes.append(Data(repeating: 0, count: 54))
        bytes.append(contentsOf: [1, 2, 3, 4, 5, 6, 7, 8])
        let offsets = try ExperienceRuntimeFontData.faceOffsets(in: bytes)
        XCTAssertEqual(offsets, [20, 64])
        let selected = try ExperienceRuntimeFontData.face(in: bytes, at: offsets[1])
        XCTAssertEqual(selected.tables[0x66766172], Data([5, 6, 7, 8]))
        XCTAssertEqual(checksum(try ExperienceRuntimeFontData.assemble(selected)), 0xB1B0AFBA)
        XCTAssertThrowsError(try ExperienceRuntimeFontData.face(in: bytes.dropLast(), at: offsets[1]))
    }

    func testTruncatedOrInvalidContainersFailWithoutIndexingOutsideData() {
        for data in [Data(), Data([0, 1, 0]), Data(repeating: 255, count: 20), Data([0x74, 0x74, 0x63, 0x66])] {
            XCTAssertThrowsError(try ExperienceRuntimeFontData.face(in: data, at: 0))
        }
        XCTAssertThrowsError(try ExperienceRuntimeFontData.faceOffsets(in: Data([0x74, 0x74, 0x63, 0x66])))
    }

    private func checksum(_ data: Data) -> UInt32 {
        var value: UInt32 = 0
        for (index, byte) in data.enumerated() {
            value = value &+ (UInt32(byte) << (24 - (index % 4) * 8))
        }
        return value
    }
}

import CoreText
import CryptoKit
import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Device-local preparation only. Callers must not cache a candidate as usable
/// until configured native import has accepted it.
package enum ExperienceRuntimeSystemFontProvider {
    package enum Failure: String, Error, Equatable, Sendable {
        case unsupportedRequest
        case unavailableFace
        case unavailableTables
        case unusableData
    }

    package enum Extraction: Equatable, Sendable { case file, tables }

    package struct Candidate: Sendable {
        package let bytes: Data
        package let sourceIdentity: String
        package let contentSHA256: String
        package let extraction: Extraction
    }

    package static func prepare(
        weight: String,
        style: String,
        readFile: (URL) throws -> Data = { try Data(contentsOf: $0, options: .mappedIfSafe) }
    ) throws -> Candidate {
        let font = try selectedFont(weight: weight, style: style)
        let tables = try copyTables(font)
        let version: UInt32 = tables[0x43464620] != nil || tables[0x43464632] != nil ? 0x4F54544F : 0x00010000
        let selected = ExperienceRuntimeFontData.Face(version: version, tables: tables)
        let descriptor = CTFontCopyFontDescriptor(font)
        let url = CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute) as? URL
        if let url, url.isFileURL, let file = try? readFile(url),
           let offsets = try? ExperienceRuntimeFontData.faceOffsets(in: file) {
            for offset in offsets {
                guard let face = try? ExperienceRuntimeFontData.face(in: file, at: offset),
                      matches(face.tables, selected: tables),
                      let bytes = try? ExperienceRuntimeFontData.assemble(face),
                      ExperienceRuntimeFontRegistry.isValidFontData(bytes) else { continue }
                return candidate(bytes, font: font, source: "\(url.path)#\(offset)", extraction: .file)
            }
        }
        guard let bytes = try? ExperienceRuntimeFontData.assemble(selected),
              ExperienceRuntimeFontRegistry.isValidFontData(bytes) else { throw Failure.unusableData }
        return candidate(bytes, font: font, source: "coretext-tables", extraction: .tables)
    }

    /// Cheap lookup identity for immutable OS font sources. Content digest and
    /// extraction identity remain on the candidate admitted after native import.
    package static func requestIdentity(weight: String, style: String) throws -> String {
        let font = try selectedFont(weight: weight, style: style)
        let url = CTFontDescriptorCopyAttribute(CTFontCopyFontDescriptor(font), kCTFontURLAttribute) as? URL
        return "\(ProcessInfo.processInfo.operatingSystemVersionString)|\(CTFontCopyPostScriptName(font))|\(url?.absoluteString ?? "coretext")|\(weight)|\(style)"
    }

    private static func selectedFont(weight: String, style: String) throws -> CTFont {
        guard style == "normal", let value = Int(weight), String(value) == weight,
              (100...900).contains(value), value % 100 == 0 else { throw Failure.unsupportedRequest }
        #if canImport(UIKit)
        return UIFont.systemFont(ofSize: 17, weight: uiWeight(value)) as CTFont
        #else
        throw Failure.unavailableFace
        #endif
    }

    #if canImport(UIKit)
    package static func uiWeight(_ weight: Int) -> UIFont.Weight {
        switch weight {
        case 100: .ultraLight
        case 200: .thin
        case 300: .light
        case 400: .regular
        case 500: .medium
        case 600: .semibold
        case 700: .bold
        case 800: .heavy
        case 900: .black
        default: .regular
        }
    }
    #endif

    private static func copyTables(_ font: CTFont) throws -> [UInt32: Data] {
        guard let tags = CTFontCopyAvailableTables(font, []) else { throw Failure.unavailableTables }
        var tables: [UInt32: Data] = [:]
        // CoreText returns unboxed integer tags, not CFNumber objects.
        for index in 0..<CFArrayGetCount(tags) {
            let tag = UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(tags, index)))
            guard let table = CTFontCopyTable(font, tag, []) else { throw Failure.unavailableTables }
            tables[tag] = table as Data
        }
        guard !tables.isEmpty else { throw Failure.unavailableTables }
        return tables
    }

    private static func matches(_ tables: [UInt32: Data], selected: [UInt32: Data]) -> Bool {
        // Do not select a collection's first face or trust a shared family name.
        // Compare actual tables from the OS-selected face, including variations.
        selected.allSatisfy { tag, expected in
            if tag == 0x44534947 { return true }
            guard var actual = tables[tag] else { return false }
            var normalized = expected
            if tag == ExperienceRuntimeFontData.head, actual.count >= 12, normalized.count >= 12 {
                actual.replaceSubrange(8..<12, with: [0, 0, 0, 0])
                normalized.replaceSubrange(8..<12, with: [0, 0, 0, 0])
            }
            return actual == normalized
        }
    }

    private static func candidate(_ bytes: Data, font: CTFont, source: String, extraction: Extraction) -> Candidate {
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return Candidate(
            bytes: bytes,
            sourceIdentity: "\(ProcessInfo.processInfo.operatingSystemVersionString)|\(CTFontCopyPostScriptName(font))|\(source)|\(digest)",
            contentSHA256: digest,
            extraction: extraction
        )
    }
}

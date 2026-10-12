#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import CoreText
import CryptoKit
import Foundation
@_implementationOnly import NuxieRuntimeC

/// CoreText selects the regular system face for each missing character.
/// The C hook borrows cached immutable handles for the life of the process.
package enum ExperienceRuntimeFontFallbackProvider {
    package struct Coordinate: Sendable {
        let axis: UInt32
        let value: Float
    }

    package struct Face: Sendable {
        let path: String
        let index: UInt32
        let coordinates: [Coordinate]
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var characters: [UInt32: OpaquePointer] = [:]
    private nonisolated(unsafe) static var fonts: [String: OpaquePointer] = [:]
    private nonisolated(unsafe) static var misses = Set<UInt32>()

    // Swift's static initialization installs the process hook exactly once.
    private static let installation: UInt32 = nux_font_set_fallback_proc({ _, missing, index, _ in
        guard index == 0 else { return nil }
        return fallback(for: missing)
    }, nil)

    package static func install() throws {
        guard installation == NUX_STATUS_OK else {
            throw ExperienceRuntimeSystemFontProvider.Failure.unavailableFace
        }
    }

    private static func fallback(for missing: UInt32) -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        if let font = characters[missing] { return font }
        guard !misses.contains(missing), let scalar = Unicode.Scalar(missing),
              let base = CTFontCreateUIFontForLanguage(.system, 17, nil) else { return nil }
        let string = String(scalar) as CFString
        let selected = CTFontCreateForStringWithLanguage(base, string,
            CFRange(location: 0, length: CFStringGetLength(string)), nil)
        do {
            let face = try backing(for: selected)
            let coordinates = face.coordinates.map { NuxFontAxisCoord(axis: $0.axis, value: $0.value) }
            let key = "\(face.path)#\(face.index)#\(face.coordinates.map { "\($0.axis)=\($0.value)" }.joined(separator: ","))"
            if let font = fonts[key] { characters[missing] = font; return font }
            var font: OpaquePointer?
            let status = Array(face.path.utf8).withUnsafeBufferPointer { path in
                coordinates.withUnsafeBufferPointer { coords in
                    var source = NuxFontSource()
                    source.struct_size = UInt32(MemoryLayout<NuxFontSource>.size)
                    source.immutable_path = NuxStringView(data: path.baseAddress, len: path.count)
                    source.face_index = face.index
                    source.coords = coords.baseAddress
                    source.coord_count = coords.count
                    return nux_font_new(&source, &font)
                }
            }
            guard status == NUX_STATUS_OK, let font else { misses.insert(missing); return nil }
            fonts[key] = font
            characters[missing] = font
            return font
        } catch {
            misses.insert(missing)
            return nil
        }
    }

    private static func backing(for font: CTFont) throws -> Face {
        let variations = CTFontCopyVariation(font) as? [NSNumber: NSNumber] ?? [:]
        let coordinates = variations.map { Coordinate(axis: $0.key.uint32Value, value: $0.value.floatValue) }
            .sorted { $0.axis < $1.axis }
        if let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
           url.isFileURL, let data = try? Data(contentsOf: url, options: .alwaysMapped),
           let index = try? collectionIndex(in: data, font: font) {
            return Face(path: url.path, index: index, coordinates: coordinates)
        }
        // Some OS faces expose tables but no readable sfnt. Extract once into
        // SDK-owned immutable content storage, never once per Experience.
        guard let available = CTFontCopyAvailableTables(font, []) else {
            throw ExperienceRuntimeSystemFontProvider.Failure.unavailableTables
        }
        var tables: [UInt32: Data] = [:]
        for index in 0..<CFArrayGetCount(available) {
            let tag = UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(available, index)))
            guard let data = CTFontCopyTable(font, tag, []) else {
                throw ExperienceRuntimeSystemFontProvider.Failure.unavailableTables
            }
            tables[tag] = data as Data
        }
        let version: UInt32 = tables[0x43464620] != nil || tables[0x43464632] != nil ? 0x4F54544F : 0x00010000
        let data = try ExperienceRuntimeFontData.assemble(.init(version: version, tables: tables),
            maximumBytes: 256 * 1_024 * 1_024)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Nuxie/SystemFontFallbacks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(digest + ".ttf")
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return Face(path: url.path, index: 0, coordinates: coordinates)
    }

    /// Compare small tables from the actual OS-selected face. Do not flatten
    /// or copy a large TTC just to locate its collection index.
    package static func collectionIndex(in data: Data, font: CTFont) throws -> UInt32 {
        func read32(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else {
                throw ExperienceRuntimeFontData.Failure.malformedContainer
            }
            return (0..<4).reduce(0) { ($0 << 8) | UInt32(data[offset + $1]) }
        }
        let collection = try read32(0) == 0x74746366
        let count = collection ? Int(try read32(8)) : 1
        guard (1...256).contains(count) else { throw ExperienceRuntimeFontData.Failure.malformedContainer }
        let tags: [UInt32] = [0x6E616D65, 0x636D6170] // name and cmap
        let selected = try tags.map { tag -> Data in
            guard let table = CTFontCopyTable(font, tag, []) else {
                throw ExperienceRuntimeSystemFontProvider.Failure.unavailableTables
            }
            return table as Data
        }
        for index in 0..<count {
            let offset = collection ? Int(try read32(12 + index * 4)) : 0
            let flavor = try read32(offset)
            guard [0x00010000, 0x4F54544F, 0x74727565].contains(flavor),
                  offset <= data.count - 12 else { throw ExperienceRuntimeFontData.Failure.malformedContainer }
            let records = Int(data[offset + 4]) * 256 + Int(data[offset + 5])
            guard (1...4095).contains(records), records <= (data.count - offset - 12) / 16 else {
                throw ExperienceRuntimeFontData.Failure.malformedContainer
            }
            var matches = Set<UInt32>()
            for record in 0..<records {
                let at = offset + 12 + record * 16
                let tag = try read32(at)
                guard let selectedIndex = tags.firstIndex(of: tag) else { continue }
                let start = Int(try read32(at + 8)), length = Int(try read32(at + 12))
                guard start <= data.count, length <= data.count - start else {
                    throw ExperienceRuntimeFontData.Failure.malformedContainer
                }
                if data[start..<(start + length)] == selected[selectedIndex] { matches.insert(tag) }
            }
            if matches.count == tags.count { return UInt32(index) }
        }
        throw ExperienceRuntimeSystemFontProvider.Failure.unavailableFace
    }
}

#endif

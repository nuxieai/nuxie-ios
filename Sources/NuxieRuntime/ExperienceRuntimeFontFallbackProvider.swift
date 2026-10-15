#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import CoreText
import CryptoKit
import Foundation
@_implementationOnly import NuxieRuntimeC
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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

    package struct Resolution {
        let handle: OpaquePointer
        let postScriptName: String
    }

    /// Owns process-lifetime handles. The backing closure permits a counted
    /// file/table acquisition in tests without replacing CoreText selection.
    package final class Cache: @unchecked Sendable {
        /// A file or disk failure is retried after this long, not on every shaping call.
        package static let transientRetryInterval: TimeInterval = 30

        /// What a failed acquisition leaves behind for one face identity.
        private enum FailedFace {
            /// Font data that CoreText or the runtime cannot use. OS font
            /// bytes cannot change while the process runs.
            case unusable
            /// File or disk trouble. The face is not tried again until then.
            case retryAfter(Date)
        }

        /// Runtime statuses that mean the font data itself was refused.
        private static let unusableStatuses: Set<NuxieNativeStatus> = [.importError, .invalidArgument, .limitExceeded]

        private let lock = NSLock()
        private var characters: [UInt32: Resolution] = [:]
        private var fonts: [String: Resolution] = [:]
        private var failures: [String: FailedFace] = [:]
        private let prepareBacking: (CTFont) throws -> Face
        private let now: () -> Date

        package init(prepareBacking: @escaping (CTFont) throws -> Face = ExperienceRuntimeFontFallbackProvider.backing,
                     now: @escaping () -> Date = { Date() }) {
            self.prepareBacking = prepareBacking
            self.now = now
        }

        package func resolve(_ missing: UInt32) -> Resolution? {
            lock.lock()
            defer { lock.unlock() }
            if let font = characters[missing] { return font }
            guard let scalar = Unicode.Scalar(missing),
                  let base = CTFontCreateUIFontForLanguage(.system, 20, nil) else { return nil }
            let string = String(scalar) as CFString
            let selected = CTFontCreateForStringWithLanguage(base, string,
                CFRange(location: 0, length: CFStringGetLength(string)), nil)
            let name = CTFontCopyPostScriptName(selected) as String
            let url = CTFontCopyAttribute(selected, kCTFontURLAttribute) as? URL
            let key = name + "#" + (url?.absoluteString ?? "")
            // Identity lookup precedes mapping, collection lookup and table copies.
            if let font = fonts[key] { characters[missing] = font; return font }
            switch failures[key] {
            case .unusable?:
                return nil
            case .retryAfter(let time)? where now() < time:
                return nil
            default:
                break
            }
            do {
                let face = try prepareBacking(selected)
                let coordinates = face.coordinates.map { NuxFontAxisCoord(axis: $0.axis, value: $0.value) }
                let context = Unmanaged.passRetained(OutlineFont(selected))
                var callbacks = NuxFontOutlineCallbacks()
                callbacks.struct_size = UInt32(MemoryLayout<NuxFontOutlineCallbacks>.size)
                callbacks.user_data = context.toOpaque()
                callbacks.release = { context in
                    guard let context else { return }
                    Unmanaged<OutlineFont>.fromOpaque(context).release()
                }
                callbacks.get_path = { context, glyph, _, _, sink, sinkContext in
                    guard let context, let sink else { return }
                    let owner = Unmanaged<OutlineFont>.fromOpaque(context).takeUnretainedValue()
                    guard let path = CTFontCreatePathForGlyph(owner.font, glyph, nil) else { return }
                    // Mirrors font_hb_apple.mm apply_element: normalized 2048
                    // scale, inverted y, and quadratic converted by the runtime.
                    path.applyWithBlock { element in
                        let element = element.pointee
                        let verb: UInt8
                        let pointCount: Int
                        switch element.type {
                        case .moveToPoint: verb = 0; pointCount = 1
                        case .addLineToPoint: verb = 1; pointCount = 1
                        case .addQuadCurveToPoint: verb = 2; pointCount = 2
                        case .addCurveToPoint: verb = 3; pointCount = 3
                        case .closeSubpath: verb = 4; pointCount = 0
                        @unknown default: return
                        }
                        var points: [Float] = []
                        for index in 0..<pointCount {
                            points.append(Float(element.points[index].x) / 2048)
                            points.append(-Float(element.points[index].y) / 2048)
                        }
                        points.withUnsafeBufferPointer { sink(sinkContext, verb, $0.baseAddress) }
                    }
                }
                var font: OpaquePointer?
                let status = face.path.utf8.map { CChar(bitPattern: $0) }.withUnsafeBufferPointer { path in
                    coordinates.withUnsafeBufferPointer { coords in
                        var source = NuxFontSource()
                        source.struct_size = UInt32(MemoryLayout<NuxFontSource>.size)
                        source.immutable_path = NuxStringView(data: path.baseAddress, len: path.count)
                        source.face_index = face.index
                        source.coords = coords.baseAddress
                        source.coord_count = coords.count
                        return nux_font_new_with_outline(&source, &callbacks, &font)
                    }
                }
                guard status == NuxieNativeStatus.ok.rawValue, let font else {
                    context.release()
                    let refused = NuxieNativeStatus(rawValue: status).map { Self.unusableStatuses.contains($0) } ?? false
                    remember(key, unusable: refused)
                    return nil
                }
                failures[key] = nil
                let resolution = Resolution(handle: font, postScriptName: name)
                fonts[key] = resolution
                characters[missing] = resolution
                return resolution
            } catch {
                // Bad or unsupported table data stays failed; file and disk
                // errors (writing the rebuilt face, folders) are retried later.
                remember(key, unusable: error is ExperienceRuntimeFontData.Failure
                    || error is ExperienceRuntimeSystemFontProvider.Failure)
                return nil
            }
        }

        private func remember(_ key: String, unusable: Bool) {
            failures[key] = unusable ? .unusable : .retryAfter(now().addingTimeInterval(Self.transientRetryInterval))
        }
    }

    private static let cache = Cache()
    private static let observerLock = NSLock()
    private nonisolated(unsafe) static var selectionObserver: (@Sendable (UInt32, String) -> Void)?

    /// Qualification observes successful answers from the actual C hook.
    package static func observeSelections(_ observer: (@Sendable (UInt32, String) -> Void)?) {
        observerLock.lock()
        selectionObserver = observer
        observerLock.unlock()
    }

    package static func request(missing: UInt32, index: UInt32) -> OpaquePointer? {
        // rive-ios b53bbb52's one default provider answers indices 0 and 1.
        // Index 1 selects for the new missing character; CoreText shaping itself
        // remains a separate runtime gap.
        guard index < 2, let resolution = cache.resolve(missing) else { return nil }
        observerLock.lock()
        let observer = selectionObserver
        observerLock.unlock()
        observer?(missing, resolution.postScriptName)
        return resolution.handle
    }

    // Swift static initialization registers once and logs a failure once.
    private static let installation: UInt32 = {
        let status = nux_font_set_fallback_proc({ _, missing, index, _ in
            request(missing: missing, index: index)
        }, nil)
        if status != NuxieNativeStatus.ok.rawValue {
            NSLog("Nuxie: system font fallback registration failed (status %u)", status)
        }
        return status
    }()

    package static func install() {
        _ = installation
    }

    private final class OutlineFont {
        let font: CTFont

        init(_ font: CTFont) {
            self.font = CTFontCreateCopyWithAttributes(font, 2048, nil, nil)
        }
    }

    package static func backing(for font: CTFont) throws -> Face {
        // Match rive-ios's native weight/width conversion. Optical size and
        // other CoreText axes are not passed to HarfBuzz.
        let traits = CTFontCopyTraits(font) as NSDictionary
        let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        #if os(iOS)
        let weights: [(UIFont.Weight, Float)] = [(.thin, 100), (.ultraLight, 200),
            (.light, 300), (.regular, 400), (.medium, 500), (.semibold, 600),
            (.bold, 700), (.heavy, 800), (.black, 900)]
        #else
        let weights: [(NSFont.Weight, Float)] = [(.thin, 100), (.ultraLight, 200),
            (.light, 300), (.regular, 400), (.medium, 500), (.semibold, 600),
            (.bold, 700), (.heavy, 800), (.black, 900)]
        #endif
        let value = weights.first { abs(Double($0.0.rawValue) - weight) < 0.001 }?.1 ?? 400
        let width = (traits[kCTFontWidthTrait] as? NSNumber)?.doubleValue ?? 0
        let coordinates = [Coordinate(axis: 0x77676874, value: value),
            Coordinate(axis: 0x77647468, value: Float((100 + 100 * width).rounded()))]
        if let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
           url.isFileURL, let data = try? Data(contentsOf: url, options: .alwaysMapped),
           let index = try? collectionIndex(in: data, font: font) {
            return Face(path: url.path, index: index, coordinates: coordinates)
        }
        return try rebuiltBacking(for: font, coordinates: coordinates) { try rebuiltFontDirectory() }
    }

    /// Some OS faces expose tables but no readable sfnt. Extract once into
    /// SDK-owned immutable content storage, never once per Experience.
    package static func rebuiltBacking(for font: CTFont, coordinates: [Coordinate],
                                       directory: () throws -> URL) throws -> Face {
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
        let root = try directory()
        let url = root.appendingPathComponent(digest + ".ttf")
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return Face(path: url.path, index: 0, coordinates: coordinates)
    }

    package static func rebuiltFontDirectory(parent: URL? = nil,
            operatingSystem os: String = ProcessInfo.processInfo.operatingSystemVersionString) throws -> URL {
        let manager = FileManager.default
        var parent = try parent ?? manager.url(for: .cachesDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Nuxie/SystemFontFallbacks", isDirectory: true)
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        // As DiskCache does: backup exclusion is best effort, never a reason to fail.
        try? parent.setResourceValues(values)
        let version = SHA256.hash(data: Data(os.utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        let current = "os-" + version
        let root = parent.appendingPathComponent(current, isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let olderDirectories = (try? manager.contentsOfDirectory(at: parent,
            includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        // Compare folder names; listed URLs need not spell the path the same way.
        for older in olderDirectories
            where older.lastPathComponent.hasPrefix("os-") && older.lastPathComponent != current {
            if (try? older.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                try? manager.removeItem(at: older)
            }
        }
        return root
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

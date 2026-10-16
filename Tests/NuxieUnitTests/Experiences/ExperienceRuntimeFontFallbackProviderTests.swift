#if (os(iOS) || os(macOS)) && !targetEnvironment(macCatalyst)
import CoreText
import CryptoKit
import Foundation
import ImageIO
import NuxieRuntimeC
import XCTest
@testable import NuxieRuntime

final class ExperienceRuntimeFontFallbackProviderTests: XCTestCase {
    private func selected(_ text: String) throws -> CTFont {
        let base = try XCTUnwrap(CTFontCreateUIFontForLanguage(.system, 20, nil))
        return CTFontCreateForStringWithLanguage(base, text as CFString,
            CFRange(location: 0, length: (text as NSString).length), nil)
    }

    private func glyph(_ character: UniChar, in font: CTFont) -> CGGlyph {
        var character = character
        var glyph: CGGlyph = 0
        _ = CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        return glyph
    }

    private final class PictureAnswer {
        var png = Data()
        var width: UInt32 = 0
        var height: UInt32 = 0
        var rectangle = CGRect.zero
        var calls = 0
    }

    func testOnlyColorFacesInstallPictureCallback() throws {
        for (text, color) in [("😀", true), ("ש", false)] {
            let owner = ExperienceRuntimeFontFallbackProvider.OutlineFont(try selected(text))
            let context = Unmanaged.passRetained(owner)
            let callbacks = ExperienceRuntimeFontFallbackProvider.callbacks(for: owner, context: context.toOpaque())
            defer { callbacks.release?(callbacks.user_data) }
            XCTAssertNotNil(callbacks.get_path)
            XCTAssertEqual(callbacks.get_picture != nil, color)
            XCTAssertEqual(callbacks.struct_size, UInt32(MemoryLayout<NuxFontOutlineCallbacks>.size))
        }
    }

    func testPictureCallbackDoesNotEmitForMissingOrInklessGlyphs() throws {
        let font = try selected("😀")
        let space = glyph(0x20, in: font)
        XCTAssertNotEqual(space, 0, "The colour face must have a real space glyph")
        let owner = ExperienceRuntimeFontFallbackProvider.OutlineFont(font)
        let context = Unmanaged.passRetained(owner)
        let callbacks = ExperienceRuntimeFontFallbackProvider.callbacks(for: owner, context: context.toOpaque())
        defer { callbacks.release?(callbacks.user_data) }
        let answer = PictureAnswer()
        let sinkContext = Unmanaged.passUnretained(answer).toOpaque()
        // Cluster code points are context only, even if they describe ink.
        var cluster: UInt32 = 0x1F600
        for glyph in [CGGlyph(0), space] {
            try XCTUnwrap(callbacks.get_picture)(callbacks.user_data, glyph, &cluster, 1, { context, _ in
                guard let context else { return }
                Unmanaged<PictureAnswer>.fromOpaque(context).takeUnretainedValue().calls += 1
            }, sinkContext)
        }
        XCTAssertEqual(answer.calls, 0)
    }

    func testPictureCallbackPNGAndBaselineMatchCoreText() throws {
        for text in ["😀", "🎉", "👍🏽", "👨‍👩‍👧‍👦"] {
            let font = CTFontCreateCopyWithAttributes(try selected(text), 160, nil, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            XCTAssertEqual(runs.count, 1, "The sequence must use one font run")
            let run = try XCTUnwrap(runs.first)
            XCTAssertEqual(CTRunGetGlyphCount(run), 1, "The sequence must shape to one emoji glyph")
            var glyph: CGGlyph = 0
            CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
            XCTAssertNotEqual(glyph, 0)
            let owner = ExperienceRuntimeFontFallbackProvider.OutlineFont(font)
            let context = Unmanaged.passRetained(owner)
            let callbacks = ExperienceRuntimeFontFallbackProvider.callbacks(for: owner, context: context.toOpaque())
            defer { callbacks.release?(callbacks.user_data) }
            let answer = PictureAnswer()
            let sinkContext = Unmanaged.passUnretained(answer).toOpaque()
            try XCTUnwrap(callbacks.get_picture)(callbacks.user_data, glyph, nil, 0, { context, value in
                guard let context, let value, let png = value.pointee.png else { return }
                let answer = Unmanaged<PictureAnswer>.fromOpaque(context).takeUnretainedValue()
                let picture = value.pointee
                answer.calls += 1
                answer.png = Data(bytes: png, count: picture.png_len)
                answer.width = picture.width
                answer.height = picture.height
                answer.rectangle = CGRect(x: CGFloat(picture.bearing_x),
                    y: CGFloat(picture.top - picture.extent_y),
                    width: CGFloat(picture.extent_x), height: CGFloat(picture.extent_y))
            }, sinkContext)
            XCTAssertEqual(answer.calls, 1)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(answer.png as CFData, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, Int(answer.width))
            XCTAssertEqual(image.height, Int(answer.height))
            let bounds = CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1).integral
            XCTAssertEqual(answer.rectangle.minX, bounds.minX / 160, accuracy: 0.000001)
            XCTAssertEqual(answer.rectangle.minY, bounds.minY / 160, accuracy: 0.000001)
            XCTAssertEqual(answer.rectangle.width, bounds.width / 160, accuracy: 0.000001)
            XCTAssertEqual(answer.rectangle.height, bounds.height / 160, accuracy: 0.000001)
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
            func canvas() throws -> CGContext {
                try XCTUnwrap(CGContext(data: nil, width: 400, height: 400, bitsPerComponent: 8,
                    bytesPerRow: 1600, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            }
            let reference = try canvas(), restored = try canvas()
            var origin = CGPoint(x: 100, y: 100)
            CTFontDrawGlyphs(font, &glyph, &origin, 1, reference)
            // Reconstruct from the ABI's em rectangle at the same baseline.
            restored.draw(image, in: CGRect(x: (answer.rectangle.minX * 160 + 100).rounded(),
                y: (answer.rectangle.minY * 160 + 100).rounded(),
                width: CGFloat(image.width), height: CGFloat(image.height)))
            try withExtendedLifetime((reference, restored)) {
                let expected = UnsafeBufferPointer(start: try XCTUnwrap(reference.data).assumingMemoryBound(to: UInt8.self), count: 640000)
                let actual = UnsafeBufferPointer(start: try XCTUnwrap(restored.data).assumingMemoryBound(to: UInt8.self), count: 640000)
                let mismatch = zip(expected, actual).filter { abs(Int($0.0) - Int($0.1)) > 2 }.count
                XCTAssertLessThan(mismatch, 100, "PNG placement and pixels must agree with a direct baseline draw for \(text)")
                let saturated = stride(from: 0, to: actual.count, by: 4).filter {
                    let rgb = [actual[$0], actual[$0 + 1], actual[$0 + 2]]
                    return Int(rgb.max()!) - Int(rgb.min()!) > 50 && actual[$0 + 3] > 100
                }.count
                XCTAssertGreaterThan(saturated, 100, "The PNG must contain colour artwork")
            }
        }
    }

    func testSecondMissingCharacterGetsAnotherCoreTextFaceAndStopsAtTwo() throws {
        let hebrew = try selected("ש")
        let bracket = try selected("「")
        XCTAssertNotEqual(glyph(0x05E9, in: hebrew), 0)
        XCTAssertEqual(glyph(0x300C, in: hebrew), 0,
                       "The mixed שלום「」 stretch must need a second face")
        XCTAssertNotEqual(glyph(0x300C, in: bracket), 0)
        XCTAssertNotEqual(CTFontCopyPostScriptName(hebrew) as String,
                          CTFontCopyPostScriptName(bracket) as String)
        let selections = ProviderSelectionRecorder()
        ExperienceRuntimeFontFallbackProvider.observeSelections { selections.record($0, name: $1) }
        defer { ExperienceRuntimeFontFallbackProvider.observeSelections(nil) }
        let first = try XCTUnwrap(ExperienceRuntimeFontFallbackProvider.request(missing: 0x05E9, index: 0))
        let second = try XCTUnwrap(ExperienceRuntimeFontFallbackProvider.request(missing: 0x300C, index: 1))
        XCTAssertNotEqual(first, second, "Index 1 must not reuse the first fallback face")
        // Index 1 must answer with CoreText's own face for the still-missing
        // character; that face covers it (checked above). Its private name
        // need not resolve through CTFontCreateWithName, so compare names.
        // The collection test checks the face index handed to the runtime.
        let name = try XCTUnwrap(selections.name(for: 0x300C))
        XCTAssertEqual(name, CTFontCopyPostScriptName(bracket) as String)
        XCTAssertNotEqual(name, CTFontCopyPostScriptName(hebrew) as String)
        XCTAssertNil(ExperienceRuntimeFontFallbackProvider.request(missing: 0x300C, index: 2))
    }

    func testOnlyRiveWeightAndWidthAxesReachRuntime() throws {
        let face = try ExperienceRuntimeFontFallbackProvider.backing(for: selected("م"))
        XCTAssertEqual(Set(face.coordinates.map(\.axis)), [0x77676874, 0x77647468])
        XCTAssertEqual(face.coordinates.first { $0.axis == 0x77676874 }?.value, 400)
        XCTAssertEqual(face.coordinates.first { $0.axis == 0x77647468 }?.value, 100)
    }

    func testTwoCharactersOfOneFaceAcquireBackingOnce() throws {
        let first = try selected("ש"), second = try selected("ל")
        XCTAssertEqual(CTFontCopyPostScriptName(first) as String, CTFontCopyPostScriptName(second) as String)
        var acquisitions = 0
        let cache = ExperienceRuntimeFontFallbackProvider.Cache { font in
            acquisitions += 1
            return try ExperienceRuntimeFontFallbackProvider.backing(for: font)
        }
        let one = try XCTUnwrap(cache.resolve(0x05E9))
        let two = try XCTUnwrap(cache.resolve(0x05DC))
        XCTAssertEqual(one.handle, two.handle)
        XCTAssertEqual(acquisitions, 1)
    }

    func testFailedRebuildOfAFaceIsNotRepeatedOnEveryRequest() throws {
        // Bad or unsupported font data cannot change while the process runs.
        var clock: TimeInterval = 1_000
        var rebuilds = 0
        let cache = ExperienceRuntimeFontFallbackProvider.Cache(prepareBacking: { _ in
            rebuilds += 1
            throw ExperienceRuntimeFontData.Failure.excessiveSize
        }, now: { clock })
        for _ in 0..<3 { XCTAssertNil(cache.resolve(0x05E9)) }
        clock += ExperienceRuntimeFontFallbackProvider.Cache.transientRetryInterval + 1
        XCTAssertNil(cache.resolve(0x05DC), "Another character from the same face reuses the failure, also after the retry wait")
        XCTAssertEqual(rebuilds, 1)
    }

    func testFontFileTheRuntimeCannotOpenIsRetriedLater() throws {
        // The runtime reports a file it cannot open or map as ImportError,
        // the same status as data it refuses, so neither stays failed for good.
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ttf")
        try Data("not a font".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        var clock: TimeInterval = 1_000
        var attempts = 0
        let cache = ExperienceRuntimeFontFallbackProvider.Cache(prepareBacking: { font in
            attempts += 1
            if attempts == 1 { return ExperienceRuntimeFontFallbackProvider.Face(path: junk.path, index: 0, coordinates: []) }
            return try ExperienceRuntimeFontFallbackProvider.backing(for: font)
        }, now: { clock })
        XCTAssertNil(cache.resolve(0x05E9))
        XCTAssertNil(cache.resolve(0x05E9), "Typing again at once must not repeat the refused file")
        XCTAssertEqual(attempts, 1)
        clock += ExperienceRuntimeFontFallbackProvider.Cache.transientRetryInterval + 1
        XCTAssertNotNil(cache.resolve(0x05E9))
        XCTAssertEqual(attempts, 2)
    }

    func testTransientBackingFailureWaitsBeforeItIsRetried() throws {
        var clock: TimeInterval = 1_000
        var attempts = 0
        let cache = ExperienceRuntimeFontFallbackProvider.Cache(prepareBacking: { font in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileWriteOutOfSpace) }
            return try ExperienceRuntimeFontFallbackProvider.backing(for: font)
        }, now: { clock })
        XCTAssertNil(cache.resolve(0x05E9))
        XCTAssertNil(cache.resolve(0x05E9), "Typing again at once must not repeat the failed work")
        clock += ExperienceRuntimeFontFallbackProvider.Cache.transientRetryInterval - 1
        XCTAssertNil(cache.resolve(0x05DC))
        XCTAssertEqual(attempts, 1)
        clock += 2
        XCTAssertNotNil(cache.resolve(0x05E9), "A disk or file failure is retried later")
        XCTAssertEqual(attempts, 2)
    }

    func testRebuiltFaceIsReadableByCoreTextAndKeepsCoordinates() throws {
        // A small face keeps the copy cheap; the large Han faces use the same path.
        let native = try selected("ש")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let coordinates = [ExperienceRuntimeFontFallbackProvider.Coordinate(axis: 0x77676874, value: 400)]
        let face = try ExperienceRuntimeFontFallbackProvider.rebuiltBacking(for: native,
            coordinates: coordinates) { folder }
        XCTAssertEqual(face.index, 0)
        XCTAssertEqual(face.coordinates.map(\.axis), [0x77676874])
        XCTAssertEqual(URL(fileURLWithPath: face.path).deletingLastPathComponent().lastPathComponent,
                       folder.lastPathComponent)
        // CoreText reads the rebuilt file on its own and finds the same face.
        let data = try Data(contentsOf: URL(fileURLWithPath: face.path))
        let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor])
        let rebuilt = CTFontCreateWithFontDescriptor(try XCTUnwrap(descriptors.first), 20, nil)
        XCTAssertEqual(CTFontCopyFamilyName(rebuilt) as String, CTFontCopyFamilyName(native) as String)
        XCTAssertNotEqual(glyph(0x05E9, in: rebuilt), 0)
    }

    func testRebuiltFontFolderKeepsCurrentOSAndRemovesOlderOnes() throws {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("SystemFontFallbacks")
        defer { try? manager.removeItem(at: parent.deletingLastPathComponent()) }
        let older = parent.appendingPathComponent("os-older", isDirectory: true)
        try manager.createDirectory(at: older, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: older.appendingPathComponent("old.ttf"))
        let current = try ExperienceRuntimeFontFallbackProvider.rebuiltFontDirectory(parent: parent,
            operatingSystem: "Version 27.0 (Build A)")
        let kept = current.appendingPathComponent("kept.ttf")
        try Data("kept".utf8).write(to: kept)
        XCTAssertFalse(manager.fileExists(atPath: older.path), "An older OS folder is removed")
        let again = try ExperienceRuntimeFontFallbackProvider.rebuiltFontDirectory(parent: parent,
            operatingSystem: "Version 27.0 (Build A)")
        XCTAssertEqual(again.lastPathComponent, current.lastPathComponent)
        XCTAssertTrue(manager.fileExists(atPath: kept.path), "The current folder and its files survive")
        var resolved = parent
        resolved.removeCachedResourceValue(forKey: .isExcludedFromBackupKey)
        XCTAssertEqual(try resolved.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let next = try ExperienceRuntimeFontFallbackProvider.rebuiltFontDirectory(parent: parent,
            operatingSystem: "Version 27.1 (Build B)")
        XCTAssertNotEqual(next.lastPathComponent, current.lastPathComponent)
        XCTAssertFalse(manager.fileExists(atPath: current.path), "A new OS version replaces the old folder")
        XCTAssertTrue(manager.fileExists(atPath: next.path))
    }

    func testSelectedDeviceReferencesReportNativeFacesAndAxes() throws {
        var records: [[String: Any]] = []
        for (identity, sample) in [("japanese-kana", "こ"), ("japanese-han", "日"),
                                   ("korean", "한"), ("arabic", "م"),
                                   ("devanagari", "न"), ("hebrew", "ש"), ("emoji", "😀"),
                                   ("symbols-triangle", "▷"), ("symbols-star", "✶"), ("symbols-circle", "●")] {
            let native = try selected(sample)
            let face = try ExperienceRuntimeFontFallbackProvider.backing(for: native)
            var hashes: [String: String] = [:]
            for tag in ["head", "name", "cmap", "fvar", "maxp"] {
                let code = tag.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                if let table = CTFontCopyTable(native, code, []) {
                    hashes[tag] = SHA256.hash(data: table as Data).map { String(format: "%02x", $0) }.joined()
                }
            }
            let axes = Dictionary(uniqueKeysWithValues: face.coordinates.map { coordinate in
                (String(format: "%08x", coordinate.axis), coordinate.value)
            })
            records.append(["id": identity, "postScriptName": CTFontCopyPostScriptName(native) as String,
                            "pointSize": CTFontGetSize(native), "file": face.path, "faceIndex": face.index,
                            "runtimeAxes": axes, "tableHashes": hashes])
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "text-fallback-final-device-reference-faces"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCollectionFacePostScriptNameMatchesCoreText() throws {
        for text in ["日", "م", "ש", "न", "「", "▷", "✶", "●"] {
            let font = try selected(text)
            let url = try XCTUnwrap(CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)
            let data = try Data(contentsOf: url, options: .alwaysMapped)
            let index = try ExperienceRuntimeFontFallbackProvider.collectionIndex(in: data, font: font)
            let name = try XCTUnwrap(fontTable(in: data, faceIndex: index, tag: 0x6E616D65))
            let variations = try fontTable(in: data, faceIndex: index, tag: 0x66766172)
            let names = try postScriptNames(name, nameIDs: postScriptNameIDs(in: variations))
            let selectedName = CTFontCopyPostScriptName(font) as String
            XCTAssertTrue(names.contains(selectedName),
                          "\(text): face \(index) must name CoreText's \(selectedName); found \(names.sorted())")
            // The face handed to the runtime must be one this independent
            // reader also finds under CoreText's PostScript name.
            var namedFaces = Set<UInt32>()
            for candidate in 0..<faceCount(in: data) {
                guard let table = try fontTable(in: data, faceIndex: candidate, tag: 0x6E616D65) else { continue }
                let ids = try postScriptNameIDs(in: fontTable(in: data, faceIndex: candidate, tag: 0x66766172))
                if try postScriptNames(table, nameIDs: ids).contains(selectedName) { namedFaces.insert(candidate) }
            }
            let face = try ExperienceRuntimeFontFallbackProvider.backing(for: font)
            XCTAssertEqual(face.path, url.path)
            XCTAssertTrue(namedFaces.contains(face.index),
                          "\(text): runtime face \(face.index) must be one of \(namedFaces.sorted())")
        }
    }

    private func faceCount(in data: Data) -> UInt32 {
        guard data.count >= 12, data.prefix(4) == Data("ttcf".utf8) else { return 1 }
        return data[8..<12].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private final class ProviderSelectionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [UInt32: String] = [:]
        func record(_ scalar: UInt32, name: String) {
            lock.lock(); names[scalar] = name; lock.unlock()
        }
        func name(for scalar: UInt32) -> String? {
            lock.lock(); defer { lock.unlock() }
            return names[scalar]
        }
    }

    // Read just this face's name table without the production font parser or
    // its whole-container size cap. Large OS collections are valid inputs.
    private func fontTable(in data: Data, faceIndex: UInt32, tag: Int) throws -> Data? {
        func word(_ offset: Int, bytes: Int) throws -> Int {
            guard offset >= 0, offset <= data.count - bytes else {
                throw NSError(domain: "FontNameOracle", code: 3)
            }
            return (0..<bytes).reduce(0) { ($0 << 8) | Int(data[offset + $1]) }
        }
        let isCollection = try word(0, bytes: 4) == 0x74746366
        let count = isCollection ? try word(8, bytes: 4) : 1
        guard Int(faceIndex) < count else { throw NSError(domain: "FontNameOracle", code: 4) }
        let start = isCollection ? try word(12 + Int(faceIndex) * 4, bytes: 4) : 0
        let records = try word(start + 4, bytes: 2)
        for record in 0..<records {
            let at = start + 12 + record * 16
            guard try word(at, bytes: 4) == tag else { continue }
            let offset = try word(at + 8, bytes: 4), length = try word(at + 12, bytes: 4)
            guard offset <= data.count, length <= data.count - offset else {
                throw NSError(domain: "FontNameOracle", code: 5)
            }
            return data.subdata(in: offset..<(offset + length))
        }
        return nil
    }

    // A variable face can use a named instance's PostScript name rather than
    // the base name ID 6. PingFang Display uses -Default for its base and
    // -Regular for the selected instance. Read the fvar IDs independently:
    // https://learn.microsoft.com/en-us/typography/opentype/spec/fvar
    private func postScriptNameIDs(in data: Data?) throws -> Set<Int> {
        guard let data else { return [6] }
        func word(_ at: Int) throws -> Int {
            guard at >= 0, at <= data.count - 2 else {
                throw NSError(domain: "FontNameOracle", code: 6)
            }
            return Int(data[at]) * 256 + Int(data[at + 1])
        }
        let axesOffset = try word(4), axisCount = try word(8), axisSize = try word(10)
        let instanceCount = try word(12), instanceSize = try word(14)
        let nameOffset = 4 + axisCount * 4
        var ids: Set<Int> = [6]
        guard instanceSize >= nameOffset + 2 else { return ids }
        for instance in 0..<instanceCount {
            let at = axesOffset + axisCount * axisSize + instance * instanceSize + nameOffset
            let id = try word(at)
            if id != 0xFFFF { ids.insert(id) }
        }
        return ids
    }

    // Parse only base or named-instance PostScript names, independently of
    // collectionIndex's whole-name-table/cmap equality.
    private func postScriptNames(_ data: Data, nameIDs: Set<Int>) throws -> Set<String> {
        func word(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else {
                throw NSError(domain: "FontNameOracle", code: 1)
            }
            return Int(data[offset]) * 256 + Int(data[offset + 1])
        }
        let count = try word(2), start = try word(4)
        var names = Set<String>()
        for record in 0..<count {
            let at = 6 + record * 12
            guard try nameIDs.contains(word(at + 6)) else { continue }
            let length = try word(at + 8), offset = try word(at + 10)
            guard start + offset + length <= data.count else {
                throw NSError(domain: "FontNameOracle", code: 2)
            }
            let bytes = data.subdata(in: (start + offset)..<(start + offset + length))
            let platform = try word(at)
            if let name = String(data: bytes, encoding: platform == 0 || platform == 3 ? .utf16BigEndian : .macOSRoman) {
                names.insert(name)
            }
        }
        return names
    }
}
#endif

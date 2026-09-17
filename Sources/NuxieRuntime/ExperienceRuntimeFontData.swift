import Foundation

/// Converts a selected collection face or CoreText tables into standalone sfnt
/// bytes. This checks the container, not renderability: native import remains
/// the authority for whether the font is usable by Nuxie's text renderer.
package enum ExperienceRuntimeFontData {
    package enum Failure: Error, Equatable {
        case malformedContainer
        case missingHeader
        case excessiveSize
    }

    package struct Face {
        package let version: UInt32
        package let tables: [UInt32: Data]

        package init(version: UInt32, tables: [UInt32: Data]) {
            self.version = version
            self.tables = tables
        }
    }

    package static let head: UInt32 = 0x68656164
    private static let collection: UInt32 = 0x74746366
    private static let signature: UInt32 = 0x44534947
    private static let maximumBytes = 32 * 1_024 * 1_024

    package static func faceOffsets(in data: Data) throws -> [Int] {
        guard data.count <= 256 * 1_024 * 1_024 else { throw Failure.excessiveSize }
        let bytes = [UInt8](data)
        guard try read32(bytes, 0) == collection else { return [0] }
        let version = try read32(bytes, 4)
        guard version == 0x00010000 || version == 0x00020000 else { throw Failure.malformedContainer }
        let count = Int(try read32(bytes, 8))
        guard (1...256).contains(count), bytes.count >= 12 + count * 4 else {
            throw Failure.malformedContainer
        }
        return try (0..<count).map { Int(try read32(bytes, 12 + $0 * 4)) }
    }

    package static func face(in data: Data, at offset: Int) throws -> Face {
        guard data.count <= 256 * 1_024 * 1_024 else { throw Failure.excessiveSize }
        let bytes = [UInt8](data)
        let version = try read32(bytes, offset)
        guard [0x00010000, 0x4F54544F, 0x74727565].contains(version),
              offset >= 0, offset <= bytes.count - 12 else { throw Failure.malformedContainer }
        let count = Int(bytes[offset + 4]) * 256 + Int(bytes[offset + 5])
        guard (1...4095).contains(count), count <= (bytes.count - offset - 12) / 16 else {
            throw Failure.malformedContainer
        }
        var tables: [UInt32: Data] = [:]
        var total = 0
        for index in 0..<count {
            let record = offset + 12 + index * 16
            let tag = try read32(bytes, record)
            let start = Int(try read32(bytes, record + 8))
            let length = Int(try read32(bytes, record + 12))
            guard start <= bytes.count, length <= bytes.count - start, tables[tag] == nil else {
                throw Failure.malformedContainer
            }
            total += length
            guard total <= maximumBytes else { throw Failure.excessiveSize }
            tables[tag] = Data(bytes[start..<(start + length)])
        }
        return Face(version: version, tables: tables)
    }

    package static func assemble(_ face: Face) throws -> Data {
        // A rebuilt font cannot retain a signature over the original container.
        var tables = face.tables.filter { $0.key != signature }
        guard var header = tables[head], header.count >= 54 else { throw Failure.missingHeader }
        header.replaceSubrange(8..<12, with: [0, 0, 0, 0])
        tables[head] = header
        let tags = tables.keys.sorted()
        guard (1...4095).contains(tags.count) else { throw Failure.malformedContainer }
        let total = tables.values.reduce(12 + tags.count * 16) { $0 + (($1.count + 3) & ~3) }
        guard total <= maximumBytes else { throw Failure.excessiveSize }
        var bytes = [UInt8](repeating: 0, count: 12 + tags.count * 16)
        write32(face.version, into: &bytes, at: 0)
        write16(tags.count, into: &bytes, at: 4)
        var power = 1
        var selector = 0
        while power * 2 <= tags.count { power *= 2; selector += 1 }
        write16(power * 16, into: &bytes, at: 6)
        write16(selector, into: &bytes, at: 8)
        write16(tags.count * 16 - power * 16, into: &bytes, at: 10)
        var headerOffset = 0
        for (index, tag) in tags.enumerated() {
            guard let table = tables[tag] else { throw Failure.malformedContainer }
            let tableBytes = [UInt8](table)
            let record = 12 + index * 16
            write32(tag, into: &bytes, at: record)
            write32(checksum(tableBytes), into: &bytes, at: record + 4)
            write32(UInt32(bytes.count), into: &bytes, at: record + 8)
            write32(UInt32(table.count), into: &bytes, at: record + 12)
            if tag == head { headerOffset = bytes.count }
            bytes.append(contentsOf: tableBytes)
            while bytes.count % 4 != 0 { bytes.append(0) }
        }
        let adjustment = 0xB1B0AFBA &- checksum(bytes)
        write32(adjustment, into: &bytes, at: headerOffset + 8)
        return Data(bytes)
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count - 4 else { throw Failure.malformedContainer }
        return (0..<4).reduce(0) { ($0 << 8) | UInt32(bytes[offset + $1]) }
    }

    private static func write16(_ value: Int, into bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private static func write32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (24 - index * 8)) }
    }

    private static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var sum: UInt32 = 0
        for start in stride(from: 0, to: bytes.count, by: 4) {
            var word: UInt32 = 0
            for index in 0..<4 {
                word = (word << 8) | (start + index < bytes.count ? UInt32(bytes[start + index]) : 0)
            }
            sum = sum &+ word
        }
        return sum
    }
}

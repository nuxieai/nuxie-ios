import Foundation

enum StrictJSONDuplicateKeyValidator {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.parseDocument()
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func parseDocument() throws {
            skipWhitespace()
            try parseValue(depth: 0)
            skipWhitespace()
            guard index == bytes.count else { throw Failure.invalid }
        }

        mutating func parseValue(depth: Int) throws {
            guard depth <= 128, index < bytes.count else { throw Failure.invalid }
            switch bytes[index] {
            case 0x7b: try parseObject(depth: depth)
            case 0x5b: try parseArray(depth: depth)
            case 0x22: _ = try parseString()
            case 0x74: try consume("true")
            case 0x66: try consume("false")
            case 0x6e: try consume("null")
            default: try parseNumber()
            }
        }

        mutating func parseObject(depth: Int) throws {
            index += 1
            skipWhitespace()
            var keys = Set<String>()
            if consumeIf(0x7d) { return }
            while true {
                let key = try parseString()
                guard keys.insert(key).inserted else { throw Failure.duplicate }
                skipWhitespace()
                guard consumeIf(0x3a) else { throw Failure.invalid }
                skipWhitespace()
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIf(0x7d) { return }
                guard consumeIf(0x2c) else { throw Failure.invalid }
                skipWhitespace()
            }
        }

        mutating func parseArray(depth: Int) throws {
            index += 1
            skipWhitespace()
            if consumeIf(0x5d) { return }
            while true {
                try parseValue(depth: depth + 1)
                skipWhitespace()
                if consumeIf(0x5d) { return }
                guard consumeIf(0x2c) else { throw Failure.invalid }
                skipWhitespace()
            }
        }

        mutating func parseString() throws -> String {
            guard consumeIf(0x22) else { throw Failure.invalid }
            let start = index - 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte == 0x22 {
                    let token = Data(bytes[start..<index])
                    guard let value = try? JSONDecoder().decode(String.self, from: token) else {
                        throw Failure.invalid
                    }
                    return value
                }
                guard byte >= 0x20 else { throw Failure.invalid }
                if byte == 0x5c {
                    guard index < bytes.count else { throw Failure.invalid }
                    let escaped = bytes[index]
                    index += 1
                    if escaped == 0x75 {
                        guard index + 4 <= bytes.count,
                              bytes[index..<index + 4].allSatisfy({
                                  (48...57).contains($0) || (65...70).contains($0) ||
                                      (97...102).contains($0)
                              }) else { throw Failure.invalid }
                        index += 4
                    } else if ![0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74]
                        .contains(escaped) {
                        throw Failure.invalid
                    }
                }
            }
            throw Failure.invalid
        }

        mutating func parseNumber() throws {
            let start = index
            while index < bytes.count,
                  [0x2d, 0x2b, 0x2e, 0x45, 0x65].contains(bytes[index]) ||
                    (48...57).contains(bytes[index]) {
                index += 1
            }
            guard index > start,
                  let text = String(bytes: bytes[start..<index], encoding: .utf8),
                  Double(text) != nil else { throw Failure.invalid }
        }

        mutating func consume(_ text: StaticString) throws {
            let expected = Array(String(describing: text).utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<index + expected.count]) == expected else {
                throw Failure.invalid
            }
            index += expected.count
        }

        mutating func consumeIf(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func skipWhitespace() {
            while index < bytes.count,
                  [0x20, 0x09, 0x0a, 0x0d].contains(bytes[index]) {
                index += 1
            }
        }
    }

    private enum Failure: Error { case invalid, duplicate }
}

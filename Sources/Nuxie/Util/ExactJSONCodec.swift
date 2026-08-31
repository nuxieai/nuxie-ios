import Foundation
import CoreFoundation

/// Codable JSON for compiled leg data. Foundation's JSONDecoder internally
/// indexes keys by Swift String and collapses distinct JSON property names.
/// NSDictionary retains NSString's ordinal identity; our Codable containers
/// keep that identity until an ExactJSONObject takes ownership of the fields.
enum ExactJSONCodec {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try StrictJSONDuplicateKeyValidator.validate(data)
        return try JSONReader(value: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])).decode(type)
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let node = JSONNode()
        try value.encode(to: JSONWriter(node: node))
        var data = Data()
        try append(node.foundation(), to: &data)
        return data
    }
    static func canonicalize(_ data: Data) throws -> Data {
        try StrictJSONDuplicateKeyValidator.validate(data)
        var result = Data()
        try append(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]), to: &result)
        return result
    }
    private static func append(_ value: Any, to data: inout Data) throws {
        if let object = value as? NSDictionary {
            data.append(0x7b)
            let keys = object.allKeys.compactMap { $0 as? String }
                .sorted { $0.utf16.lexicographicallyPrecedes($1.utf16) }
            for (index, key) in keys.enumerated() {
                if index > 0 { data.append(0x2c) }
                data.append(try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed]))
                data.append(0x3a)
                try append(object.object(forKey: key as NSString)!, to: &data)
            }
            data.append(0x7d)
        } else if let array = value as? NSArray {
            data.append(0x5b)
            for (index, value) in array.enumerated() {
                if index > 0 { data.append(0x2c) }
                try append(value, to: &data)
            }
            data.append(0x5d)
        } else {
            guard JSONSerialization.isValidJSONObject([value]) else {
                throw EncodingError.invalidValue(value, .init(codingPath: [], debugDescription: "Invalid JSON scalar"))
            }
            data.append(try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]))
        }
    }
}

private struct JSONReader: Decoder, SingleValueDecodingContainer {
    let value: Any
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func container<Key: CodingKey>(keyedBy: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard let object = value as? NSDictionary else { throw mismatch([String: Any].self) }
        return KeyedDecodingContainer(JSONKeyedReader<Key>(reader: self, object: object))
    }
    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard let array = value as? NSArray else { throw mismatch([Any].self) }
        return JSONArrayReader(reader: self, array: array)
    }
    func singleValueContainer() throws -> SingleValueDecodingContainer { self }
    func decodeNil() -> Bool { value is NSNull }
    func mismatch(_ type: Any.Type) -> Error {
        DecodingError.typeMismatch(type, .init(codingPath: codingPath, debugDescription: "Unexpected JSON value"))
    }
    func decode(_ type: Bool.Type) throws -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw mismatch(type) }
        return number.boolValue
    }
    func decode(_ type: String.Type) throws -> String {
        guard let string = value as? NSString else { throw mismatch(type) }; return string as String
    }
    func decode(_ type: Double.Type) throws -> Double {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw mismatch(type) }
        return number.doubleValue
    }
    func decode(_ type: Float.Type) throws -> Float {
        let result = Float(try decode(Double.self)); guard result.isFinite else { throw mismatch(type) }; return result
    }
    func decode(_ type: Int.Type) throws -> Int {
        guard let result = Int(exactly: try decode(Double.self)) else { throw mismatch(type) }; return result
    }
    func decode(_ type: Int8.Type) throws -> Int8 {
        guard let result = Int8(exactly: try decode(Double.self)) else { throw mismatch(type) }; return result
    }
    func decode(_ type: Int16.Type) throws -> Int16 {
        guard let result = Int16(exactly: try decode(Double.self)) else { throw mismatch(type) }; return result
    }
    func decode(_ type: Int32.Type) throws -> Int32 {
        guard let result = Int32(exactly: try decode(Double.self)) else { throw mismatch(type) }; return result
    }
    func decode(_ type: Int64.Type) throws -> Int64 {
        guard let result = Int64(exactly: try decode(Double.self)) else { throw mismatch(type) }; return result
    }
    func decode(_ type: UInt.Type) throws -> UInt {
        guard let result = UInt(exactly: try decode(Double.self)) else { throw mismatch(type) }; return result
    }
    func decode(_ type: UInt8.Type) throws -> UInt8 {
        guard let result = UInt8(exactly: try decode(Double.self)) else { throw mismatch(type) }; return result
    }
    func decode(_ type: UInt16.Type) throws -> UInt16 {
        guard let result = UInt16(exactly: try decode(Double.self)) else { throw mismatch(type) }; return result
    }
    func decode(_ type: UInt32.Type) throws -> UInt32 {
        guard let result = UInt32(exactly: try decode(Double.self)) else { throw mismatch(type) }; return result
    }
    func decode(_ type: UInt64.Type) throws -> UInt64 {
        guard let result = UInt64(exactly: try decode(Double.self)) else { throw mismatch(type) }; return result
    }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try T(from: self) }
    func child(_ value: Any, key: CodingKey) -> Self { .init(value: value, codingPath: codingPath + [key]) }
}

private struct JSONKeyedReader<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let reader: JSONReader
    let object: NSDictionary
    var codingPath: [CodingKey] { reader.codingPath }
    var allKeys: [Key] { object.allKeys.compactMap { ($0 as? String).flatMap(Key.init(stringValue:)) } }
    func contains(_ key: Key) -> Bool { object.object(forKey: key.stringValue as NSString) != nil }
    func child(_ key: CodingKey) throws -> JSONReader {
        guard let value = object.object(forKey: key.stringValue as NSString) else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "Missing JSON key"))
        }
        return reader.child(value, key: key)
    }
    func decodeNil(forKey key: Key) throws -> Bool { try child(key).decodeNil() }
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try child(key).decode(type) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try child(key).decode(type) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try child(key).decode(type) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try child(key).decode(type) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try child(key).decode(type) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try child(key).decode(type) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try child(key).decode(type) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try child(key).decode(type) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try child(key).decode(type) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try child(key).decode(type) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try child(key).decode(type) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try child(key).decode(type) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try child(key).decode(type) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try child(key).decode(type) }
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T { try child(key).decode(type) }
    func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> { try child(key).container(keyedBy: keyedBy) }
    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer { try child(key).unkeyedContainer() }
    func superDecoder() throws -> Decoder { try child(ExactJSONCodingKey("super")) }
    func superDecoder(forKey key: Key) throws -> Decoder { try child(key) }
}

private struct JSONArrayReader: UnkeyedDecodingContainer {
    let reader: JSONReader
    let array: NSArray
    var codingPath: [CodingKey] { reader.codingPath }
    var count: Int? { array.count }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex >= array.count }
    mutating func next() throws -> JSONReader {
        guard !isAtEnd else { throw DecodingError.valueNotFound(Any.self, .init(codingPath: codingPath, debugDescription: "End of JSON array")) }
        defer { currentIndex += 1 }
        return reader.child(array[currentIndex], key: ExactJSONCodingKey(intValue: currentIndex))
    }
    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { _ = try next(); return false }
        if array[currentIndex] is NSNull { currentIndex += 1; return true }; return false
    }
    mutating func decode(_ type: Bool.Type) throws -> Bool { try next().decode(type) }
    mutating func decode(_ type: String.Type) throws -> String { try next().decode(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try next().decode(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try next().decode(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try next().decode(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try next().decode(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try next().decode(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try next().decode(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try next().decode(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try next().decode(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try next().decode(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try next().decode(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try next().decode(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try next().decode(type) }
    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T { try next().decode(type) }
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> { try next().container(keyedBy: keyedBy) }
    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer { try next().unkeyedContainer() }
    mutating func superDecoder() throws -> Decoder { try next() }
}

private final class JSONNode {
    var scalar: Any = NSNull()
    var object: ExactJSONObject<JSONNode>?
    var array: [JSONNode]?
    func foundation() -> Any {
        if let object {
            let result = NSMutableDictionary(capacity: object.count)
            for (key, value) in object { result.setObject(value.foundation(), forKey: key as NSString) }
            return result
        }
        if let array { return array.map { $0.foundation() } }
        return scalar
    }
}

private struct JSONWriter: Encoder, SingleValueEncodingContainer {
    let node: JSONNode
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] { [:] }
    func container<Key: CodingKey>(keyedBy: Key.Type) -> KeyedEncodingContainer<Key> {
        if node.object == nil { node.object = [:] }
        return KeyedEncodingContainer(JSONKeyedWriter<Key>(writer: self))
    }
    func unkeyedContainer() -> UnkeyedEncodingContainer {
        if node.array == nil { node.array = [] }; return JSONArrayWriter(writer: self)
    }
    func singleValueContainer() -> SingleValueEncodingContainer { self }
    func encodeNil() { node.scalar = NSNull() }
    func encode(_ value: Bool) { node.scalar = value }
    func encode(_ value: String) { node.scalar = value }
    func encode(_ value: Double) { node.scalar = value }
    func encode(_ value: Float) { node.scalar = value }
    func encode(_ value: Int) { node.scalar = value }
    func encode(_ value: Int8) { node.scalar = value }
    func encode(_ value: Int16) { node.scalar = value }
    func encode(_ value: Int32) { node.scalar = value }
    func encode(_ value: Int64) { node.scalar = value }
    func encode(_ value: UInt) { node.scalar = value }
    func encode(_ value: UInt8) { node.scalar = value }
    func encode(_ value: UInt16) { node.scalar = value }
    func encode(_ value: UInt32) { node.scalar = value }
    func encode(_ value: UInt64) { node.scalar = value }
    func encode<T: Encodable>(_ value: T) throws { try value.encode(to: self) }
    func child(_ node: JSONNode, key: CodingKey) -> Self { .init(node: node, codingPath: codingPath + [key]) }
}

private struct JSONKeyedWriter<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let writer: JSONWriter
    var codingPath: [CodingKey] { writer.codingPath }
    func child(_ key: CodingKey) -> JSONWriter {
        let node = writer.node.object?[key.stringValue] ?? JSONNode()
        writer.node.object?[key.stringValue] = node
        return writer.child(node, key: key)
    }
    func encodeNil(forKey key: Key) { child(key).encodeNil() }
    func encode(_ value: Bool, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: String, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: Double, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: Float, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: Int, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: Int8, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: Int16, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: Int32, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: Int64, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: UInt, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: UInt8, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: UInt16, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: UInt32, forKey key: Key) { child(key).encode(value) }
    func encode(_ value: UInt64, forKey key: Key) { child(key).encode(value) }
    func encode<T: Encodable>(_ value: T, forKey key: Key) throws { try child(key).encode(value) }
    func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> { child(key).container(keyedBy: keyedBy) }
    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { child(key).unkeyedContainer() }
    func superEncoder() -> Encoder { child(ExactJSONCodingKey("super")) }
    func superEncoder(forKey key: Key) -> Encoder { child(key) }
}

private struct JSONArrayWriter: UnkeyedEncodingContainer {
    let writer: JSONWriter
    var codingPath: [CodingKey] { writer.codingPath }
    var count: Int { writer.node.array?.count ?? 0 }
    func next() -> JSONWriter {
        let node = JSONNode(), key = ExactJSONCodingKey(intValue: count)
        writer.node.array?.append(node)
        return writer.child(node, key: key)
    }
    func encodeNil() { next().encodeNil() }
    func encode(_ value: Bool) { next().encode(value) }
    func encode(_ value: String) { next().encode(value) }
    func encode(_ value: Double) { next().encode(value) }
    func encode(_ value: Float) { next().encode(value) }
    func encode(_ value: Int) { next().encode(value) }
    func encode(_ value: Int8) { next().encode(value) }
    func encode(_ value: Int16) { next().encode(value) }
    func encode(_ value: Int32) { next().encode(value) }
    func encode(_ value: Int64) { next().encode(value) }
    func encode(_ value: UInt) { next().encode(value) }
    func encode(_ value: UInt8) { next().encode(value) }
    func encode(_ value: UInt16) { next().encode(value) }
    func encode(_ value: UInt32) { next().encode(value) }
    func encode(_ value: UInt64) { next().encode(value) }
    func encode<T: Encodable>(_ value: T) throws { try next().encode(value) }
    func nestedContainer<NestedKey: CodingKey>(keyedBy: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> { next().container(keyedBy: keyedBy) }
    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { next().unkeyedContainer() }
    func superEncoder() -> Encoder { next() }
}

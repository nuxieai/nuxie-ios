import Foundation

/// JSON property names use code-unit equality. Swift String dictionary keys
/// instead treat canonically equivalent Unicode spellings as the same key.
struct ExactJSONObject<Value> {
    private struct StoredKey: Hashable, Sendable {
        let text: String
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.text.utf16.elementsEqual(rhs.text.utf16) }
        func hash(into hasher: inout Hasher) { for unit in text.utf16 { hasher.combine(unit) } }
    }
    private var storage: [StoredKey: Value] = [:]
    init() {}
    init(_ values: [String: Value]) { for (key, value) in values { self[key] = value } }
    subscript(_ key: String) -> Value? {
        get { storage[StoredKey(text: key)] }
        set { storage[StoredKey(text: key)] = newValue }
    }
    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    var keys: [String] { storage.keys.map(\.text) }
    var values: [Value] { Array(storage.values) }
    func mapValues<T>(_ transform: (Value) throws -> T) rethrows -> ExactJSONObject<T> {
        var result = ExactJSONObject<T>()
        for (key, value) in self { result[key] = try transform(value) }
        return result
    }
    func merging(_ other: Self, uniquingKeysWith combine: (Value, Value) throws -> Value) rethrows -> Self {
        var result = self
        for (key, value) in other { result[key] = try result[key].map { try combine($0, value) } ?? value }
        return result
    }
    func merging(_ other: [String: Value], uniquingKeysWith combine: (Value, Value) throws -> Value) rethrows -> Self {
        try merging(Self(other), uniquingKeysWith: combine)
    }
    /// Legacy callers already require Swift dictionaries. New leg boundaries
    /// use ExactJSONCodec so their arbitrary property names never take this path.
    var dictionary: [String: Value] { Dictionary(map { ($0.key, $0.value) }, uniquingKeysWith: { _, new in new }) }
}
extension ExactJSONObject: Sequence {
    func makeIterator() -> AnyIterator<(key: String, value: Value)> {
        var iterator = storage.makeIterator()
        return AnyIterator { iterator.next().map { (key: $0.key.text, value: $0.value) } }
    }
}
extension ExactJSONObject: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, Value)...) { for (key, value) in elements { self[key] = value } }
}
extension ExactJSONObject: Sendable where Value: Sendable {}
extension ExactJSONObject: Equatable where Value: Equatable {}
extension ExactJSONObject: Codable where Value: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: ExactJSONCodingKey.self)
        for key in container.allKeys { self[key.stringValue] = try container.decode(Value.self, forKey: key) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ExactJSONCodingKey.self)
        for (key, value) in self { try container.encode(value, forKey: ExactJSONCodingKey(key)) }
    }
}

struct ExactJSONCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { Int(stringValue) }
    init(_ value: String) { stringValue = value }
    init(stringValue: String) { self.stringValue = stringValue }
    init(intValue: Int) { stringValue = String(intValue) }
}

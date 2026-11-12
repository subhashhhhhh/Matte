import Foundation

/// A small, Sendable JSON value used for X's large, loosely-shaped GraphQL responses.
///
/// X's response layout shifts often, so parsers navigate it with
/// forgiving subscripts (missing keys yield `.null`) and recursive searches
/// rather than strict `Decodable` models.
nonisolated enum JSON: Sendable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
    /// Integers are kept exact: Instagram ids ("pk") are 19 digits, more than a Double holds.
    case integer(Int64)
    case bool(Bool)
    case null

    // MARK: Decoding / encoding

    init(data: Data) throws {
        self = JSON(any: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(any: Any) {
        switch any {
        case let d as [String: Any]: self = .object(d.mapValues(JSON.init(any:)))
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if !CFNumberIsFloatType(n), n.compare(NSNumber(value: Int64.max)) != .orderedDescending,
                      n.compare(NSNumber(value: Int64.min)) != .orderedAscending {
                self = .integer(n.int64Value)
            } else {
                self = .number(n.doubleValue)
            }
        default: self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .object(let o): o.mapValues(\.anyValue)
        case .array(let a): a.map(\.anyValue)
        case .string(let s): s
        case .number(let n): n
        case .integer(let n): NSNumber(value: n)
        case .bool(let b): b
        case .null: NSNull()
        }
    }

    /// Encodes the value. A bare scalar is written as a JSON fragment (JSONSerialization
    /// would otherwise raise an Objective-C exception); NaN and infinity throw.
    func data() throws -> Data {
        guard isEncodable else { throw CocoaError(.propertyListWriteInvalid) }
        return try JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed])
    }

    /// False if a NaN or infinity is anywhere inside (JSONSerialization would raise for it).
    private var isEncodable: Bool {
        switch self {
        case .number(let n): n.isFinite
        case .object(let o): o.values.allSatisfy(\.isEncodable)
        case .array(let a): a.allSatisfy(\.isEncodable)
        default: true
        }
    }

    // MARK: Navigation

    subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSON {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return .null
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var double: Double? {
        switch self {
        case .number(let n): n
        case .integer(let n): Double(n)
        case .string(let s): Double(s)
        default: nil
        }
    }
    /// The value as an integer: exact for integers and integer strings; nil for anything that
    /// isn't a finite whole number in range (never a crash).
    var int: Int? {
        switch self {
        case .integer(let n): Int(exactly: n)
        case .number(let n): Int(exactly: n.rounded(.towardZero))
        case .string(let s): Int(s) ?? Double(s).flatMap { Int(exactly: $0.rounded(.towardZero)) }
        default: nil
        }
    }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var array: [JSON] { if case .array(let a) = self { a } else { [] } }
    var object: [String: JSON]? { if case .object(let o) = self { o } else { nil } }
    var isNull: Bool { self == .null }

    // MARK: Recursive search

    /// Every value stored under `key`, anywhere in the tree (depth-first, document order).
    /// Does not descend into matched values.
    func all(_ key: String) -> [JSON] {
        var out: [JSON] = []
        collect(key, into: &out)
        return out
    }

    /// First value stored under `key`, anywhere in the tree: the same one `all(key).first`
    /// gives (sorted sibling keys, so it doesn't change between launches).
    func first(_ key: String) -> JSON? {
        switch self {
        case .object(let o):
            if let v = o[key] { return v }
            for k in o.keys.sorted() { if let hit = o[k]!.first(key) { return hit } }
            return nil
        case .array(let a):
            for v in a { if let hit = v.first(key) { return hit } }
            return nil
        default:
            return nil
        }
    }

    private func collect(_ key: String, into out: inout [JSON]) {
        switch self {
        case .object(let o):
            if let v = o[key] { out.append(v); return }
            // Dictionary order is unstable; sort keys so results keep a stable order.
            for k in o.keys.sorted() { o[k]!.collect(key, into: &out) }
        case .array(let a):
            for v in a { v.collect(key, into: &out) }
        default:
            break
        }
    }
}

// MARK: Equality

nonisolated extension JSON: Equatable {
    /// `.integer(1)` equals `.number(1)`: the same JSON number, read two ways.
    static func == (a: JSON, b: JSON) -> Bool {
        switch (a, b) {
        case (.object(let x), .object(let y)): x == y
        case (.array(let x), .array(let y)): x == y
        case (.string(let x), .string(let y)): x == y
        case (.number(let x), .number(let y)): x == y
        case (.integer(let x), .integer(let y)): x == y
        case (.integer(let x), .number(let y)), (.number(let y), .integer(let x)): Double(x) == y && Int64(exactly: y) == x
        case (.bool(let x), .bool(let y)): x == y
        case (.null, .null): true
        default: false
        }
    }
}

// MARK: Merging streamed parts

nonisolated extension JSON {
    /// Places `value` at `path` (object keys and array indices). An object there gets
    /// `value`'s keys merged in; anything else is replaced.
    func merging(_ value: JSON, at path: [JSON], label: String? = nil) -> JSON {
        guard let head = path.first else {
            if case .object(var mine) = self, case .object(let theirs) = value {
                for (k, v) in theirs { mine[k] = v }
                return .object(mine)
            }
            return value
        }
        let rest = Array(path.dropFirst())
        switch (self, head) {
        case (.object(var o), .string(let k)):
            o[k] = (o[k] ?? .null).merging(value, at: rest)
            return .object(o)
        case (.array, .integer(let n)):
            return merging(value, at: [.number(Double(n))] + rest)
        case (.array(var a), .number(let n)):
            // Only an existing index or the next one: a malformed part (negative, fractional
            // or huge index) is ignored rather than growing the array without bound.
            guard n >= 0, n.rounded() == n, n <= Double(a.count) else { return self }
            let i = Int(n)
            if i == a.count { a.append(.null) }
            a[i] = a[i].merging(value, at: rest)
            return .array(a)
        case (.null, .string(let k)):
            return .object([k: JSON.null.merging(value, at: rest)])
        case (.null, .number), (.null, .integer):
            return JSON.array([]).merging(value, at: path)
        default:
            return self
        }
    }
}

// MARK: Literals (for building request bodies)

nonisolated extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral {
    init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .integer(Int64(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(nilLiteral: ()) { self = .null }
}

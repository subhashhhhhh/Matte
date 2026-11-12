import Foundation

/// A small, Sendable JSON value used for X's large, loosely-shaped GraphQL responses.
///
/// X's response layout shifts often, so parsers navigate it with
/// forgiving subscripts (missing keys yield `.null`) and recursive searches
/// rather than strict `Decodable` models.
nonisolated enum JSON: Sendable, Equatable {
    case object([String: JSON])
    case array([JSON])
    case string(String)
    case number(Double)
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
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        default: self = .null
        }
    }

    var anyValue: Any {
        switch self {
        case .object(let o): o.mapValues(\.anyValue)
        case .array(let a): a.map(\.anyValue)
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .null: NSNull()
        }
    }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: anyValue, options: [])
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
        case .string(let s): Double(s)
        default: nil
        }
    }
    var int: Int? { double.map { Int($0) } }
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

    /// First value stored under `key`, anywhere in the tree.
    func first(_ key: String) -> JSON? {
        switch self {
        case .object(let o):
            if let v = o[key] { return v }
            for v in o.values { if let hit = v.first(key) { return hit } }
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
        case (.null, .number):
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
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(nilLiteral: ()) { self = .null }
}

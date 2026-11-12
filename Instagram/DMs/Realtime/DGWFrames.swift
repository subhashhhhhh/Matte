import Foundation

/// Meta's Direct Gateway ("DGW") framing, spoken over `wss://gateway.instagram.com/ws/…`
/// (docs/dm-protocol.md §5.2). Several frames may share one WebSocket message; integers are
/// little-endian and lengths are 3 bytes.
nonisolated enum DGWFrame: Equatable, Sendable {
    case drain(reason: UInt8)
    case deauth
    case ping
    case pong
    case ack(stream: UInt16, ackId: UInt16)
    /// `requiresAck` asks the receiver to answer with `.ack(stream, ackId)` once handled.
    case data(stream: UInt16, ackId: UInt16, requiresAck: Bool, payload: Data)
    case endOfData(stream: UInt16, reason: UInt8?)
    /// The client's request to open a stream (JSON parameters), or the server's answer
    /// (`{"code":200}` or a bare `200`).
    case establish(stream: UInt16, parameters: Data)
    /// A frame type this client doesn't handle; the rest of the message is dropped.
    case unsupported(type: UInt8)

    enum Kind: UInt8 {
        case drain = 0x03, deauth = 0x04, ping = 0x09, pong = 0x0A, ack = 0x0C, data = 0x0D
        case endOfData = 0x0E, establish = 0x0F, endOfDataWithReason = 0x10, extendedData = 0x11
    }

    /// A short name for logs and the probe (never the payload).
    var name: String {
        switch self {
        case .drain: "drain"
        case .deauth: "deauth"
        case .ping: "ping"
        case .pong: "pong"
        case .ack: "ack"
        case .data: "data"
        case .endOfData: "endOfData"
        case .establish: "establish"
        case .unsupported(let t): "unsupported(\(t))"
        }
    }

    // MARK: Encoding

    static func encode(_ frames: [DGWFrame]) -> Data {
        var out = Data()
        for f in frames { f.append(to: &out) }
        return out
    }

    func append(to out: inout Data) {
        switch self {
        case .drain(let reason):
            out.append(Kind.drain.rawValue); out.appendU24(1); out.append(reason)
        case .deauth: out.append(Kind.deauth.rawValue)
        case .ping: out.append(Kind.ping.rawValue)
        case .pong: out.append(Kind.pong.rawValue)
        case .ack(let stream, let ackId):
            out.append(Kind.ack.rawValue); out.appendU16(stream); out.appendU24(2); out.appendU16(ackId)
        case .data(let stream, let ackId, let requiresAck, let payload):
            out.append(Kind.data.rawValue); out.appendU16(stream); out.appendU24(UInt32(2 + payload.count))
            out.appendU16((ackId & 0x7FFF) | (requiresAck ? 0x8000 : 0))
            out.append(payload)
        case .endOfData(let stream, let reason):
            if let reason {
                out.append(Kind.endOfDataWithReason.rawValue); out.appendU16(stream); out.appendU24(1); out.append(reason)
            } else {
                out.append(Kind.endOfData.rawValue); out.appendU16(stream)
            }
        case .establish(let stream, let parameters):
            out.append(Kind.establish.rawValue); out.appendU16(stream); out.appendU24(UInt32(parameters.count))
            out.append(parameters)
        case .unsupported(let t): out.append(t)
        }
    }

    // MARK: Decoding

    /// Every frame in one WebSocket message. A malformed or unknown frame ends the list (its
    /// length can't be trusted), reported as `.unsupported`.
    static func decode(_ message: Data) -> [DGWFrame] {
        let b = [UInt8](message)
        var i = 0
        var out: [DGWFrame] = []
        func u16(_ at: Int) -> UInt16 { UInt16(b[at]) | UInt16(b[at + 1]) << 8 }
        func u24(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 }
        while i < b.count {
            let type = b[i]
            let rest = b.count - i
            switch Kind(rawValue: type) {
            case .ping: out.append(.ping); i += 1
            case .pong: out.append(.pong); i += 1
            case .deauth: out.append(.deauth); i += 1
            case .drain:
                guard rest >= 5 else { out.append(.unsupported(type: type)); return out }
                out.append(.drain(reason: b[i + 4])); i += 4 + max(1, u24(i + 1))
            case .ack:
                guard rest >= 8 else { out.append(.unsupported(type: type)); return out }
                out.append(.ack(stream: u16(i + 1), ackId: u16(i + 6) & 0x7FFF)); i += 6 + u24(i + 3)
            case .data, .extendedData:
                let header = type == Kind.extendedData.rawValue ? 9 : 8
                guard rest >= 6 else { out.append(.unsupported(type: type)); return out }
                let length = u24(i + 3)
                guard length >= header - 6, rest >= 6 + length else { out.append(.unsupported(type: type)); return out }
                let field = u16(i + 6)
                let payload = Data(b[(i + header)..<(i + 6 + length)])
                out.append(.data(stream: u16(i + 1), ackId: field & 0x7FFF, requiresAck: field & 0x8000 != 0, payload: payload))
                i += 6 + length
            case .endOfData:
                guard rest >= 3 else { out.append(.unsupported(type: type)); return out }
                out.append(.endOfData(stream: u16(i + 1), reason: nil)); i += 3
            case .endOfDataWithReason:
                guard rest >= 7 else { out.append(.unsupported(type: type)); return out }
                let length = u24(i + 3)
                guard length >= 1, rest >= 6 + length else { out.append(.unsupported(type: type)); return out }
                out.append(.endOfData(stream: u16(i + 1), reason: b[i + 6])); i += 6 + length
            case .establish:
                guard rest >= 6 else { out.append(.unsupported(type: type)); return out }
                let length = u24(i + 3)
                guard rest >= 6 + length else { out.append(.unsupported(type: type)); return out }
                out.append(.establish(stream: u16(i + 1), parameters: Data(b[(i + 6)..<(i + 6 + length)])))
                i += 6 + length
            case nil:
                out.append(.unsupported(type: type))
                return out
            }
        }
        return out
    }

    /// The status in a server's establish answer: `{"code":200,…}` or a bare `200`.
    static func establishCode(_ parameters: Data) -> Int? {
        guard let json = try? JSON(data: parameters) else { return nil }
        return json.int ?? json["code"].int
    }
}

/// WebSocket close codes the gateway uses (`dgw/frames.go`).
nonisolated enum DGWCloseCode {
    static let graceful = 4000
    static let keepaliveTimeout = 4001
    static let serverError = 4002
    static let unauthorized = 4003
    static let rejected = 4004
    static let badRequest = 4005
}

nonisolated private extension Data {
    mutating func appendU16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func appendU24(_ v: UInt32) { append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)); append(UInt8((v >> 16) & 0xFF)) }
}

// MARK: - Protobuf (the main stream's `LSResponse`)

/// The operations of an `LSResponse` (`MDCoreSync.proto`): only what the client acts on.
nonisolated enum LSOperation: Equatable, Sendable {
    case subscribe(subscribedSeqId: Int64, latestSeqId: Int64)
    case resnapshot(errorType: Int64, message: String)
    /// A JSON string: `[{"data":{"slide_delta_processor":[Delta…]}}]`.
    case delta(String)
    case noop
    case failure(String)
    case unknown

    var name: String {
        switch self {
        case .subscribe: "subscribe"
        case .resnapshot: "resnapshot"
        case .delta: "delta"
        case .noop: "noop"
        case .failure: "failure"
        case .unknown: "unknown"
        }
    }

    /// Reads `LSResponse { repeated Operation operations = 2; … }`. Nil if it isn't protobuf.
    static func decodeResponse(_ data: Data) -> [LSOperation]? {
        guard let fields = ProtoReader.fields(data) else { return nil }
        return fields.compactMap { f in
            guard f.number == 2, case .bytes(let op) = f.value else { return nil }
            return decodeOperation(op)
        }
    }

    private static func decodeOperation(_ data: Data) -> LSOperation {
        guard let field = ProtoReader.fields(data)?.first, case .bytes(let body) = field.value else { return .unknown }
        let inner = ProtoReader.fields(body) ?? []
        func int(_ n: Int) -> Int64 { inner.last { $0.number == n }?.value.int ?? 0 }
        func string(_ n: Int) -> String { inner.last { $0.number == n }?.value.string ?? "" }
        switch field.number {
        case 1: return .subscribe(subscribedSeqId: int(2), latestSeqId: int(3))
        case 2: return .resnapshot(errorType: int(3), message: string(2))
        case 3: return .delta(string(2))
        case 4: return .noop
        case 5: return .failure(string(2))
        default: return .unknown
        }
    }
}

/// A minimal protobuf wire-format reader (varints and length-delimited fields).
nonisolated enum ProtoReader {
    enum Value: Equatable {
        case varint(UInt64)
        case bytes(Data)
        case fixed(UInt64)

        var int: Int64? { if case .varint(let v) = self { Int64(bitPattern: v) } else { nil } }
        var string: String? { if case .bytes(let d) = self { String(decoding: d, as: UTF8.self) } else { nil } }
    }

    struct Field: Equatable {
        var number: Int
        var value: Value
    }

    static func fields(_ data: Data) -> [Field]? {
        let b = [UInt8](data)
        var i = 0
        var out: [Field] = []
        func varint() -> UInt64? {
            var v: UInt64 = 0
            var shift: UInt64 = 0
            while i < b.count, shift < 64 {
                let byte = b[i]; i += 1
                v |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { return nil }
            let number = Int(key >> 3)
            guard number > 0 else { return nil }
            switch key & 7 {
            case 0:
                guard let v = varint() else { return nil }
                out.append(Field(number: number, value: .varint(v)))
            case 1, 5:
                let n = key & 7 == 1 ? 8 : 4
                guard i + n <= b.count else { return nil }
                var v: UInt64 = 0
                for k in 0..<n { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                i += n
                out.append(Field(number: number, value: .fixed(v)))
            case 2:
                guard let len = varint(), len <= UInt64(b.count - i) else { return nil }
                out.append(Field(number: number, value: .bytes(Data(b[i..<(i + Int(len))]))))
                i += Int(len)
            default:
                return nil
            }
        }
        return out
    }
}

// MARK: - Thrift compact protocol (stream controller and MQTT bypass streams)

/// Just enough of Thrift's compact protocol for the typing streams (§5.8–5.9).
nonisolated enum Thrift {
    indirect enum Value: Equatable {
        case bool(Bool)
        case int(Int64)
        case double(Double)
        case binary(Data)
        case list([Value])
        case map([(Value, Value)])
        case structure([Int16: Value])

        static func == (a: Value, b: Value) -> Bool {
            switch (a, b) {
            case (.bool(let x), .bool(let y)): x == y
            case (.int(let x), .int(let y)): x == y
            case (.double(let x), .double(let y)): x == y
            case (.binary(let x), .binary(let y)): x == y
            case (.list(let x), .list(let y)): x == y
            case (.structure(let x), .structure(let y)): x == y
            case (.map(let x), .map(let y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            default: false
            }
        }

        subscript(field: Int16) -> Value? { if case .structure(let s) = self { s[field] } else { nil } }
        var int: Int64? { if case .int(let v) = self { v } else { nil } }
        var binary: Data? { if case .binary(let d) = self { d } else { nil } }
        var list: [Value] { if case .list(let l) = self { l } else { [] } }
    }

    // MARK: Encoding (the fixed payloads the web client sends)

    static func varint(_ v: UInt64) -> Data {
        var v = v
        var out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }

    private static func binaryField(_ header: UInt8, _ bytes: Data) -> Data {
        var d = Data([header])
        d.append(varint(UInt64(bytes.count)))
        d.append(bytes)
        return d
    }

    /// `requeststream.Payload{ 2: RequestStreamBody{ 1: body } }`: what a stream-controller
    /// subscription sends once its stream is open.
    static func requestStreamBody(_ json: Data) -> Data {
        var d = Data([0x2C])
        d.append(binaryField(0x18, json))
        d.append(contentsOf: [0x00, 0x00])
        return d
    }

    /// `mqttbypass.RequestPayload{ 1: ConnectRequest{…web values…} }`.
    static func mqttConnect(deviceId: String) -> Data {
        var d = Data([0x1C, 0x16, 0x00, 0x16, 0x00, 0x18, 0x00])
        d.append(binaryField(0x18, Data(deviceId.utf8)))
        d.append(contentsOf: [0x18, 0x00, 0x1C, 0x19, 0x08, 0x00, 0x00, 0x00])
        return d
    }

    /// `mqttbypass.RequestPayload{ 2: PublishRequest{ 1: payload, 2: topic } }`.
    static func mqttPublish(_ payload: Data, topic: String) -> Data {
        var d = Data([0x2C])
        d.append(binaryField(0x18, payload))
        d.append(binaryField(0x18, Data(topic.utf8)))
        d.append(contentsOf: [0x00, 0x00])
        return d
    }

    // MARK: Decoding

    /// Reads one struct (a union is a struct with one field). Nil if malformed.
    static func decodeStruct(_ data: Data) -> Value? {
        var r = Reader(bytes: [UInt8](data))
        return r.readStruct(depth: 0)
    }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0

        mutating func byte() -> UInt8? {
            guard i < bytes.count else { return nil }
            defer { i += 1 }
            return bytes[i]
        }

        mutating func varint() -> UInt64? {
            var v: UInt64 = 0
            var shift: UInt64 = 0
            while shift < 64 {
                guard let b = byte() else { return nil }
                v |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }

        mutating func zigzag() -> Int64? {
            guard let v = varint() else { return nil }
            return Int64(bitPattern: v >> 1) ^ -Int64(bitPattern: v & 1)
        }

        mutating func readStruct(depth: Int) -> Value? {
            guard depth < 32 else { return nil }
            var fields: [Int16: Value] = [:]
            var last: Int16 = 0
            while true {
                guard let header = byte() else { return nil }
                if header == 0 { return .structure(fields) }
                let type = header & 0x0F
                let delta = Int16(header >> 4)
                let id: Int16
                if delta == 0 {
                    guard let z = zigzag(), let v = Int16(exactly: z) else { return nil }
                    id = v
                } else {
                    id = last &+ delta
                }
                last = id
                // Booleans carry their value in the field header.
                if type == 1 || type == 2 { fields[id] = .bool(type == 1); continue }
                guard let v = read(type: type, depth: depth + 1) else { return nil }
                fields[id] = v
            }
        }

        mutating func read(type: UInt8, depth: Int) -> Value? {
            guard depth < 32 else { return nil }
            switch type {
            case 1, 2:
                // A boolean inside a list or map: one byte.
                guard let b = byte() else { return nil }
                return .bool(b == 1)
            case 3:
                guard let b = byte() else { return nil }
                return .int(Int64(Int8(bitPattern: b)))
            case 4, 5, 6:
                return zigzag().map(Value.int)
            case 7:
                guard i + 8 <= bytes.count else { return nil }
                var bits: UInt64 = 0
                for k in 0..<8 { bits |= UInt64(bytes[i + k]) << (8 * UInt64(k)) }
                i += 8
                return .double(Double(bitPattern: bits))
            case 8:
                guard let len = varint(), len <= UInt64(bytes.count - i) else { return nil }
                defer { i += Int(len) }
                return .binary(Data(bytes[i..<(i + Int(len))]))
            case 9, 10:
                guard let header = byte() else { return nil }
                var count = UInt64(header >> 4)
                if count == 15 { guard let c = varint() else { return nil }; count = c }
                // Each element takes at least one byte: a bigger count is corrupt.
                guard count <= UInt64(bytes.count - i) else { return nil }
                var items: [Value] = []
                for _ in 0..<count {
                    guard let v = read(type: header & 0x0F, depth: depth + 1) else { return nil }
                    items.append(v)
                }
                return .list(items)
            case 11:
                guard let count = varint(), count <= UInt64(bytes.count - i) else { return nil }
                if count == 0 { return .map([]) }
                guard let types = byte() else { return nil }
                var pairs: [(Value, Value)] = []
                for _ in 0..<count {
                    guard let k = read(type: types >> 4, depth: depth + 1),
                          let v = read(type: types & 0x0F, depth: depth + 1) else { return nil }
                    pairs.append((k, v))
                }
                return .map(pairs)
            case 12:
                return readStruct(depth: depth + 1)
            default:
                return nil
            }
        }
    }
}

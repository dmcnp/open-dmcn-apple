import Foundation

// The browser reads the stored documents with JSON.parse, so key order is free. What has to hold is
// the shape: a number stays a number, an absent optional stays absent, and a key this kit has never
// heard of comes back out exactly as it went in, because a newer web client may have put it there.

/// Any JSON value, kept exactly enough to write back what was read.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    /// Kept apart from `.double` so a timestamp is not rewritten through floating point.
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int64.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// A stored document held as the JSON it arrived as, with typed properties read through it.
///
/// The documents two clients edit in turn are built on this rather than on a fixed struct, so a
/// field the kit doesn't model, or one holding a type it doesn't expect, survives a
/// read-modify-write untouched. Setting a property to nil removes its key.
public protocol JSONDocument: Codable, Sendable, Equatable {
    var fields: [String: JSONValue] { get set }
    init(fields: [String: JSONValue])
}

extension JSONDocument {
    public init(from decoder: any Decoder) throws {
        self.init(fields: try decoder.singleValueContainer().decode([String: JSONValue].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fields)
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        if case .string(let v)? = self[key] { return v }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if case .bool(let v)? = self[key] { return v }
        return nil
    }

    func int(_ key: String) -> Int64? {
        switch self[key] {
        case .int(let v)?: return v
        case .double(let v)?: return Int64(exactly: v.rounded())
        default: return nil
        }
    }

    mutating func set(_ key: String, _ value: String?) { self[key] = value.map(JSONValue.string) }
    mutating func set(_ key: String, _ value: Bool?) { self[key] = value.map(JSONValue.bool) }
    mutating func set(_ key: String, _ value: Int64?) { self[key] = value.map(JSONValue.int) }

    func documents<D: JSONDocument>(_ key: String) -> [D] {
        guard case .array(let items)? = self[key] else { return [] }
        return items.compactMap {
            if case .object(let fields) = $0 { return D(fields: fields) }
            return nil
        }
    }

    mutating func set(_ key: String, _ documents: [some JSONDocument]) {
        self[key] = .array(documents.map { .object($0.fields) })
    }
}

/// The one JSON configuration everything stored goes through.
enum StoreJSON {
    static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        // Sorted so equal documents are equal bytes. Slashes are left alone so a document reads
        // the same here as it does in the browser's copy.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Reads JSON the browser wrote. JavaScript strings may hold half of a surrogate pair, the
    /// draft row's snippet does whenever its cut lands inside an emoji, and JSON.stringify writes
    /// that as an escape Foundation refuses outright. Without the second try a draft would vanish
    /// from the list here over one character of its preview.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            guard let repaired = replacingLoneSurrogates(in: data) else { throw error }
            return try JSONDecoder().decode(type, from: repaired)
        }
    }

    /// `data` with each unpaired `\uD800`-`\uDFFF` escape changed to U+FFFD, or nil if it has none.
    static func replacingLoneSurrogates(in data: Data) -> Data? {
        let bytes = [UInt8](data)
        let backslash = UInt8(ascii: "\\")
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var changed = false
        var i = 0

        func unit(at index: Int) -> UInt16? {
            guard index + 6 <= bytes.count, bytes[index] == backslash, bytes[index + 1] == UInt8(ascii: "u") else {
                return nil
            }
            return UInt16(String(decoding: bytes[(index + 2)..<(index + 6)], as: UTF8.self), radix: 16)
        }

        while i < bytes.count {
            guard bytes[i] == backslash else {
                out.append(bytes[i])
                i += 1
                continue
            }
            guard let first = unit(at: i) else {
                // Any other escape, including an escaped backslash: both bytes are copied so the
                // second is never read as the start of an escape.
                out.append(contentsOf: bytes[i..<min(i + 2, bytes.count)])
                i += 2
                continue
            }
            if (0xD800...0xDBFF).contains(first), let second = unit(at: i + 6), (0xDC00...0xDFFF).contains(second) {
                out.append(contentsOf: bytes[i..<(i + 12)])
                i += 12
            } else if (0xD800...0xDFFF).contains(first) {
                out.append(contentsOf: Array("\\ufffd".utf8))
                i += 6
                changed = true
            } else {
                out.append(contentsOf: bytes[i..<(i + 6)])
                i += 6
            }
        }
        return changed ? Data(out) : nil
    }
}

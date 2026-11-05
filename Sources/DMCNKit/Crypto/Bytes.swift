import Foundation

// Byte helpers the rest of the kit leans on. Everything on the wire is Data; hex is how the web
// host names messages (`hash`) and how the known-answer vectors are written.

extension Data {
    /// Lowercase hex, two characters per byte.
    public var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        return String(unsafeUninitializedCapacity: count * 2) { out in
            for (i, byte) in enumerated() {
                out[2 * i] = digits[Int(byte >> 4)]
                out[2 * i + 1] = digits[Int(byte & 0x0f)]
            }
            return count * 2
        }
    }

    /// Decodes lowercase or uppercase hex. Returns nil for an odd length or a non-hex character.
    public init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }

    /// `count` copies of `byte`, the shape every known-answer vector's fixed inputs take.
    static func filled(_ count: Int, with byte: UInt8) -> Data {
        Data(repeating: byte, count: count)
    }
}

/// Compares two byte strings in time independent of where they first differ.
func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(a, b) { diff |= x ^ y }
    return diff == 0
}

import Crypto
import Foundation

/// CIDv1(raw, sha2-256) of a body ciphertext blob, `0x01 0x55 0x12 0x20 ‖ SHA-256(nonce ‖
/// ciphertext ‖ tag)`. Carried in the clear on the envelope for keyless relay verification and
/// committed inside the signed header. Parity with Go message.ComputeBodyContentAddress.
public func bodyContentAddress(nonce: Data, ciphertext: Data, tag: Data) -> Data {
    Data([0x01, 0x55, 0x12, 0x20]) + Data(SHA256.hash(data: nonce + ciphertext + tag))
}

/// The header snippet: the longest valid-UTF-8 prefix of a text/plain body's first 140 bytes,
/// empty for any other content type (SPEC_CORE §3). It never splits a multibyte character.
public func snippet(contentType: String, content: Data) -> String {
    guard contentType == "text/plain" else { return "" }
    var prefix = content.prefix(140)
    while !prefix.isEmpty {
        // Decoding repairs invalid UTF-8 with U+FFFD, so a prefix is valid exactly when it
        // re-encodes to itself.
        let s = String(decoding: prefix, as: UTF8.self)
        if Data(s.utf8) == prefix { return s }
        prefix = prefix.dropLast()
    }
    return ""
}

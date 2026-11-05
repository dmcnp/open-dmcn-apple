import Foundation

/// Unkeyed BLAKE2b (RFC 7693), the hash Argon2 is built on. swift-crypto doesn't have it.
///
/// Argon2 calls this a few dozen times per run, so it favours being readable over being fast:
/// the time goes in Argon2's own block function. The buffers hold the passphrase on its way
/// through, so `finalize` wipes them.
struct BLAKE2b {
    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    private static let blockSize = 128

    private let digestLength: Int
    private var state = iv
    private var block = [UInt8](repeating: 0, count: blockSize)
    private var filled = 0
    private var total: UInt64 = 0
    private var message = [UInt64](repeating: 0, count: 16)
    private var work = [UInt64](repeating: 0, count: 16)

    /// `digestLength` is 1 to 64 bytes. It's part of the hash, not a truncation of it.
    init(digestLength: Int) {
        precondition((1...64).contains(digestLength))
        self.digestLength = digestLength
        // The parameter block, for an unkeyed sequential hash: only its first word is non-zero.
        state[0] ^= 0x0101_0000 ^ UInt64(digestLength)
    }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < bytes.count {
            // A full block waits here until more input arrives, because the last block of the
            // message is compressed differently and this might have been it.
            if filled == Self.blockSize {
                total &+= UInt64(Self.blockSize)
                compress(isLast: false)
                filled = 0
            }
            let count = min(Self.blockSize - filled, bytes.count - offset)
            block.withUnsafeMutableBytes { target in
                target.baseAddress!.advanced(by: filled).copyMemory(
                    from: bytes.baseAddress!.advanced(by: offset), byteCount: count)
            }
            filled += count
            offset += count
        }
    }

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    mutating func update(littleEndian value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { update($0) }
    }

    /// Writes the digest to the start of `out`, which must have room for it, and wipes the state.
    mutating func finalize(into out: UnsafeMutableRawBufferPointer) {
        precondition(out.count >= digestLength)
        total &+= UInt64(filled)
        for index in filled..<Self.blockSize { block[index] = 0 }
        compress(isLast: true)
        for index in 0..<digestLength {
            // Words go out little-endian whatever the host is.
            out[index] = UInt8(truncatingIfNeeded: state[index / 8] >> UInt64(8 * (index % 8)))
        }
        block.withUnsafeMutableBytes { secureZero($0) }
        message.withUnsafeMutableBytes { secureZero($0) }
        work.withUnsafeMutableBytes { secureZero($0) }
        state.withUnsafeMutableBytes { secureZero($0) }
    }

    /// One-shot, for tests.
    static func hash(_ input: Data, length: Int) -> Data {
        var hasher = BLAKE2b(digestLength: length)
        hasher.update(input)
        var digest = Data(count: length)
        digest.withUnsafeMutableBytes { hasher.finalize(into: $0) }
        return digest
    }

    private mutating func compress(isLast: Bool) {
        for word in 0..<16 {
            var value: UInt64 = 0
            for byte in (0..<8).reversed() { value = value << 8 | UInt64(block[word * 8 + byte]) }
            message[word] = value
        }
        for index in 0..<8 {
            work[index] = state[index]
            work[index + 8] = Self.iv[index]
        }
        work[12] ^= total
        if isLast { work[14] = ~work[14] }

        for round in 0..<12 {
            let s = Self.sigma[round % 10]
            mix(0, 4, 8, 12, message[s[0]], message[s[1]])
            mix(1, 5, 9, 13, message[s[2]], message[s[3]])
            mix(2, 6, 10, 14, message[s[4]], message[s[5]])
            mix(3, 7, 11, 15, message[s[6]], message[s[7]])
            mix(0, 5, 10, 15, message[s[8]], message[s[9]])
            mix(1, 6, 11, 12, message[s[10]], message[s[11]])
            mix(2, 7, 8, 13, message[s[12]], message[s[13]])
            mix(3, 4, 9, 14, message[s[14]], message[s[15]])
        }
        for index in 0..<8 { state[index] ^= work[index] ^ work[index + 8] }
    }

    private mutating func mix(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
        work[a] = work[a] &+ work[b] &+ x
        work[d] = rotateRight(work[d] ^ work[a], 32)
        work[c] = work[c] &+ work[d]
        work[b] = rotateRight(work[b] ^ work[c], 24)
        work[a] = work[a] &+ work[b] &+ y
        work[d] = rotateRight(work[d] ^ work[a], 16)
        work[c] = work[c] &+ work[d]
        work[b] = rotateRight(work[b] ^ work[c], 63)
    }

    private func rotateRight(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value >> count) | (value << (64 - count))
    }
}

import Foundation

/// Argon2id (RFC 9106, version 0x13), the passphrase hash the browser client wraps its keys
/// with. It must agree with @noble/hashes/argon2 bit for bit, or a backup made in one client
/// never opens in the other (`Argon2idTests` pins it to vectors from that code).
///
/// The cost is the point of the function, so the block loop is written to run close to the
/// metal on a phone: one allocation up front, raw pointers on 64-bit words after that. Debug
/// builds matter too, because every test goes through here: a `while` over a raw pointer is
/// many times cheaper unoptimised than a `for` over a range or a buffer's checked subscript.
public enum Argon2id {
    /// The parameters don't describe a valid Argon2 run.
    public struct InvalidParameters: Error, Equatable, Sendable {
        public let reason: String
    }

    private static let blockWords = 128
    private static let blockBytes = 1024
    private static let syncPoints = 4
    private static let version: UInt32 = 0x13
    private static let typeID: UInt32 = 2

    /// Derives a key. This blocks for as long as the parameters ask: from a UI or an actor,
    /// use the `async` overload, which the compiler picks in an async context.
    ///
    /// `password` is taken as bytes. Callers pass the UTF-8 of what was typed with no Unicode
    /// normalisation, as the browser's TextEncoder does, or the same word typed on two systems
    /// could give two keys.
    public static func derive(
        password: Data, salt: Data, memoryKiB: Int, iterations: Int, parallelism: Int, length: Int,
        secret: Data = Data(), associatedData: Data = Data()
    ) throws -> Data {
        try run(
            password: password, salt: salt, memoryKiB: memoryKiB, iterations: iterations, parallelism: parallelism,
            length: length, secret: secret, associatedData: associatedData)
    }

    /// Derives a key away from the caller's actor, because this takes real time.
    public static func derive(
        password: Data, salt: Data, memoryKiB: Int, iterations: Int, parallelism: Int, length: Int,
        secret: Data = Data(), associatedData: Data = Data()
    ) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try run(
                password: password, salt: salt, memoryKiB: memoryKiB, iterations: iterations,
                parallelism: parallelism, length: length, secret: secret, associatedData: associatedData)
        }.value
    }

    private static func run(
        password: Data, salt: Data, memoryKiB: Int, iterations: Int, parallelism: Int, length: Int,
        secret: Data, associatedData: Data
    ) throws -> Data {
        // The same limits as noble's, so a file one client refuses the other refuses too.
        guard length >= 4, length <= Int(UInt32.max) else {
            throw InvalidParameters(reason: "length must be at least 4 bytes")
        }
        guard parallelism >= 1, parallelism < 1 << 24 else {
            throw InvalidParameters(reason: "parallelism must be from 1 to 2^24 - 1")
        }
        guard iterations >= 1, iterations <= Int(UInt32.max) else {
            throw InvalidParameters(reason: "iterations must be at least 1")
        }
        guard memoryKiB >= 8 * parallelism, memoryKiB <= Int(UInt32.max) else {
            throw InvalidParameters(reason: "memory must be at least 8 KiB per lane")
        }
        guard salt.count >= 8, salt.count <= Int(UInt32.max) else {
            throw InvalidParameters(reason: "salt must be at least 8 bytes")
        }
        guard password.count <= Int(UInt32.max) else {
            throw InvalidParameters(reason: "password is too long")
        }

        // The memory actually used is rounded down so every lane splits into four equal segments.
        let segmentLength = memoryKiB / (syncPoints * parallelism)
        let laneLength = segmentLength * syncPoints
        let blockCount = laneLength * parallelism

        // One arena holds the blocks and all the scratch, so one wipe covers everything.
        let arena = UnsafeMutableBufferPointer<UInt64>.allocate(capacity: (blockCount + scratchBlocks) * blockWords)
        arena.initialize(repeating: 0)
        defer {
            secureZero(UnsafeMutableRawBufferPointer(arena))
            arena.deallocate()
        }
        let memory = arena.baseAddress!
        let scratch = Scratch(base: memory + blockCount * blockWords)

        initialHash(
            password: password, salt: salt, secret: secret, associatedData: associatedData, memoryKiB: memoryKiB,
            iterations: iterations, parallelism: parallelism, length: length, into: scratch.seed)
        fillFirstBlocks(memory: memory, scratch: scratch, laneLength: laneLength, lanes: parallelism)

        let shape = Shape(
            memory: memory, scratch: scratch, lanes: parallelism, laneLength: laneLength,
            segmentLength: segmentLength, blockCount: blockCount, iterations: iterations)
        for pass in 0..<iterations {
            for slice in 0..<syncPoints {
                // Lanes only read each other's finished slices, so running them in turn gives
                // the same result as running them at once.
                for lane in 0..<parallelism {
                    fillSegment(shape, pass: pass, slice: slice, lane: lane)
                }
            }
        }

        // The output is the hash of every lane's last block, XORed together.
        let final = UnsafeMutableRawBufferPointer(rebasing: scratch.bytes[0..<blockBytes])
        for word in 0..<blockWords {
            var value: UInt64 = 0
            for lane in 0..<parallelism {
                value ^= memory[((lane + 1) * laneLength - 1) * blockWords + word]
            }
            final.storeBytes(of: value.littleEndian, toByteOffset: word * 8, as: UInt64.self)
        }
        var tag = Data(count: length)
        tag.withUnsafeMutableBytes { out in
            variableHash(UnsafeRawBufferPointer(final), into: out, scratch: scratch)
        }
        return tag
    }

    // MARK: Setup

    /// Scratch space inside the arena, a block each.
    private struct Scratch {
        let base: UnsafeMutablePointer<UInt64>
        /// Holds X xor Y while the permutation runs on `product`.
        var xored: UnsafeMutablePointer<UInt64> { base }
        var product: UnsafeMutablePointer<UInt64> { base + blockWords }
        var addresses: UnsafeMutablePointer<UInt64> { base + 2 * blockWords }
        var addressInput: UnsafeMutablePointer<UInt64> { base + 3 * blockWords }
        var zero: UnsafePointer<UInt64> { UnsafePointer(base + 4 * blockWords) }
        /// Bytes for H': a block of input or output, then its 64-byte chain value.
        var bytes: UnsafeMutableRawBufferPointer {
            UnsafeMutableRawBufferPointer(start: base + 5 * blockWords, count: blockBytes + 64)
        }
        /// H0, with room after it for the two numbers each first block adds.
        var seed: UnsafeMutableRawBufferPointer {
            UnsafeMutableRawBufferPointer(start: base + 7 * blockWords, count: 72)
        }
    }
    private static let scratchBlocks = 8

    private struct Shape {
        let memory: UnsafeMutablePointer<UInt64>
        let scratch: Scratch
        let lanes: Int
        let laneLength: Int
        let segmentLength: Int
        let blockCount: Int
        let iterations: Int
    }

    /// H0, which binds every parameter and input into the run.
    private static func initialHash(
        password: Data, salt: Data, secret: Data, associatedData: Data, memoryKiB: Int, iterations: Int,
        parallelism: Int, length: Int, into out: UnsafeMutableRawBufferPointer
    ) {
        var hasher = BLAKE2b(digestLength: 64)
        for value in [parallelism, length, memoryKiB, iterations] {
            hasher.update(littleEndian: UInt32(value))
        }
        hasher.update(littleEndian: version)
        hasher.update(littleEndian: typeID)
        for input in [password, salt, secret, associatedData] {
            hasher.update(littleEndian: UInt32(input.count))
            hasher.update(input)
        }
        hasher.finalize(into: out)
    }

    /// Each lane starts from two blocks made from H0, the position and the lane's number.
    private static func fillFirstBlocks(
        memory: UnsafeMutablePointer<UInt64>, scratch: Scratch, laneLength: Int, lanes: Int
    ) {
        let out = UnsafeMutableRawBufferPointer(rebasing: scratch.bytes[0..<blockBytes])
        for lane in 0..<lanes {
            for position in 0..<2 {
                scratch.seed.storeBytes(of: UInt32(position).littleEndian, toByteOffset: 64, as: UInt32.self)
                scratch.seed.storeBytes(of: UInt32(lane).littleEndian, toByteOffset: 68, as: UInt32.self)
                variableHash(UnsafeRawBufferPointer(scratch.seed), into: out, scratch: scratch)
                let block = memory + (lane * laneLength + position) * blockWords
                for word in 0..<blockWords {
                    block[word] = UInt64(littleEndian: out.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self))
                }
            }
        }
    }

    /// H', the variable-length hash, sized by `out`.
    ///
    /// Short outputs are one BLAKE2b. Longer ones chain 64-byte hashes and keep the first half
    /// of each, with a last hash sized to land exactly on the length.
    private static func variableHash(
        _ input: UnsafeRawBufferPointer, into out: UnsafeMutableRawBufferPointer, scratch: Scratch
    ) {
        let length = out.count
        var hasher = BLAKE2b(digestLength: min(length, 64))
        hasher.update(littleEndian: UInt32(length))
        hasher.update(input)
        if length <= 64 {
            hasher.finalize(into: out)
            return
        }

        let chain = UnsafeMutableRawBufferPointer(rebasing: scratch.bytes[blockBytes..<(blockBytes + 64)])
        hasher.finalize(into: chain)
        var position = 0
        while true {
            out[position..<(position + 32)].copyBytes(from: chain[0..<32])
            position += 32
            guard length - position > 64 else { break }
            var next = BLAKE2b(digestLength: 64)
            next.update(UnsafeRawBufferPointer(chain))
            next.finalize(into: chain)
        }
        var last = BLAKE2b(digestLength: length - position)
        last.update(UnsafeRawBufferPointer(chain))
        last.finalize(into: UnsafeMutableRawBufferPointer(rebasing: out[position...]))
    }

    // MARK: The fill

    private static func fillSegment(_ shape: Shape, pass: Int, slice: Int, lane: Int) {
        let memory = shape.memory
        let scratch = shape.scratch
        let laneLength = shape.laneLength
        let segmentLength = shape.segmentLength
        // The id in Argon2id: the first half of the first pass picks blocks without looking at
        // the data, which resists timing attacks, and the rest depends on it, which resists GPUs.
        let dataIndependent = pass == 0 && slice < 2
        let firstSegment = pass == 0 && slice == 0
        let start = firstSegment ? 2 : 0

        let input = scratch.addressInput
        if dataIndependent {
            input[0] = UInt64(pass)
            input[1] = UInt64(lane)
            input[2] = UInt64(slice)
            input[3] = UInt64(shape.blockCount)
            input[4] = UInt64(shape.iterations)
            input[5] = UInt64(typeID)
            input[6] = 0
            if firstSegment { nextAddresses(scratch) }
        }

        var current = lane * laneLength + slice * segmentLength + start
        var index = start
        while index < segmentLength {
            let previous = current % laneLength == 0 ? current + laneLength - 1 : current - 1

            let random: UInt64
            if dataIndependent {
                if index % blockWords == 0 { nextAddresses(scratch) }
                random = scratch.addresses[index % blockWords]
            } else {
                random = memory[previous * blockWords]
            }

            let referenceLane = firstSegment ? lane : Int((random >> 32) % UInt64(shape.lanes))
            let referenceIndex = referenceIndex(
                pass: pass, slice: slice, index: index, random: random & 0xffff_ffff,
                sameLane: referenceLane == lane, laneLength: laneLength, segmentLength: segmentLength)

            compress(
                memory + previous * blockWords, memory + (referenceLane * laneLength + referenceIndex) * blockWords,
                into: memory + current * blockWords, xorIntoTarget: pass != 0, scratch: scratch)
            index += 1
            current += 1
        }
    }

    /// Maps a pseudo-random value onto the blocks a position may read, biased towards recent ones.
    @inline(__always)
    private static func referenceIndex(
        pass: Int, slice: Int, index: Int, random: UInt64, sameLane: Bool, laneLength: Int, segmentLength: Int
    ) -> Int {
        let area: Int
        if pass == 0 {
            if slice == 0 {
                area = index - 1
            } else if sameLane {
                area = slice * segmentLength + index - 1
            } else {
                area = slice * segmentLength - (index == 0 ? 1 : 0)
            }
        } else if sameLane {
            area = laneLength - segmentLength + index - 1
        } else {
            area = laneLength - segmentLength - (index == 0 ? 1 : 0)
        }

        let squared = (random &* random) >> 32
        let offset = Int((UInt64(area) &* squared) >> 32)
        let relative = area - 1 - offset
        let startPosition = pass != 0 && slice != syncPoints - 1 ? (slice + 1) * segmentLength : 0
        return (startPosition + relative) % laneLength
    }

    /// The next 128 data-independent addresses: the counter hashed twice through the block function.
    private static func nextAddresses(_ scratch: Scratch) {
        scratch.addressInput[6] &+= 1
        compress(
            scratch.zero, UnsafePointer(scratch.addressInput), into: scratch.addresses, xorIntoTarget: false,
            scratch: scratch)
        compress(
            scratch.zero, UnsafePointer(scratch.addresses), into: scratch.addresses, xorIntoTarget: false,
            scratch: scratch)
    }

    // MARK: The block function

    /// G: `target = P(x xor y) xor x xor y`, or that XORed onto `target` in every pass after the
    /// first. `target` may be `y`: both inputs are read before it's written.
    private static func compress(
        _ x: UnsafePointer<UInt64>, _ y: UnsafePointer<UInt64>, into target: UnsafeMutablePointer<UInt64>,
        xorIntoTarget: Bool, scratch: Scratch
    ) {
        let xored = scratch.xored
        let v = scratch.product
        var i = 0
        while i < blockWords {
            let word = x[i] ^ y[i]
            xored[i] = word
            v[i] = word
            i += 1
        }

        // The block is an 8x8 grid of 16-byte registers: permute each row, then each column.
        i = 0
        while i < 128 {
            permute(
                v, i, i + 1, i + 2, i + 3, i + 4, i + 5, i + 6, i + 7, i + 8, i + 9, i + 10, i + 11, i + 12, i + 13,
                i + 14, i + 15)
            i += 16
        }
        i = 0
        while i < 16 {
            permute(
                v, i, i + 1, i + 16, i + 17, i + 32, i + 33, i + 48, i + 49, i + 64, i + 65, i + 80, i + 81, i + 96,
                i + 97, i + 112, i + 113)
            i += 2
        }

        i = 0
        if xorIntoTarget {
            while i < blockWords {
                target[i] ^= v[i] ^ xored[i]
                i += 1
            }
        } else {
            while i < blockWords {
                target[i] = v[i] ^ xored[i]
                i += 1
            }
        }
    }

    @inline(__always)
    private static func permute(
        _ v: UnsafeMutablePointer<UInt64>, _ v0: Int, _ v1: Int, _ v2: Int, _ v3: Int, _ v4: Int, _ v5: Int,
        _ v6: Int, _ v7: Int, _ v8: Int, _ v9: Int, _ v10: Int, _ v11: Int, _ v12: Int, _ v13: Int, _ v14: Int,
        _ v15: Int
    ) {
        mix(v, v0, v4, v8, v12)
        mix(v, v1, v5, v9, v13)
        mix(v, v2, v6, v10, v14)
        mix(v, v3, v7, v11, v15)
        mix(v, v0, v5, v10, v15)
        mix(v, v1, v6, v11, v12)
        mix(v, v2, v7, v8, v13)
        mix(v, v3, v4, v9, v14)
    }

    /// BLAKE2b's mixing step with its addition swapped for one that also multiplies the low
    /// halves, which is what makes the block function expensive to build in hardware.
    @inline(__always)
    private static func mix(_ v: UnsafeMutablePointer<UInt64>, _ ia: Int, _ ib: Int, _ ic: Int, _ id: Int) {
        var a = v[ia]
        var b = v[ib]
        var c = v[ic]
        var d = v[id]
        a = a &+ b &+ 2 &* (a & 0xffff_ffff) &* (b & 0xffff_ffff)
        d = rotateRight(d ^ a, 32)
        c = c &+ d &+ 2 &* (c & 0xffff_ffff) &* (d & 0xffff_ffff)
        b = rotateRight(b ^ c, 24)
        a = a &+ b &+ 2 &* (a & 0xffff_ffff) &* (b & 0xffff_ffff)
        d = rotateRight(d ^ a, 16)
        c = c &+ d &+ 2 &* (c & 0xffff_ffff) &* (d & 0xffff_ffff)
        b = rotateRight(b ^ c, 63)
        v[ia] = a
        v[ib] = b
        v[ic] = c
        v[id] = d
    }

    @inline(__always)
    private static func rotateRight(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value &>> count) | (value &<< (64 &- count))
    }
}

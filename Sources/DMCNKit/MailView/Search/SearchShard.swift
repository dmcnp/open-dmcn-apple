import Foundation

// One shard of the inverted index and the bytes it's sealed in. Pure. Parity with the browser's
// lib/search/shardIndex.ts.
//
// A shard maps each token to the ascending list of document numbers holding it. Numbers are handed
// out in order, so a posting list is stored as deltas in LEB128 varints: a token found in most of a
// mailbox costs about a byte per message.
//
//     shard   = count(varint) entry*
//     entry   = tokenLen(varint) tokenUtf8 postings(varint) delta(varint)*

public typealias SearchShard = [String: [Int]]

public struct SearchShardError: Error, Equatable, Sendable {
    public init() {}
}

extension MailSearch {
    /// Records that `doc` holds `token`. Docs normally arrive ascending, so this appends.
    static func addPosting(_ shard: inout SearchShard, token: String, doc: Int) {
        guard var list = shard[token], let last = list.last else {
            shard[token] = [doc]
            return
        }
        if doc == last { return }
        if doc > last {
            shard[token]?.append(doc)
            return
        }
        let at = list.firstIndex { $0 >= doc } ?? list.count
        if at == list.count || list[at] != doc {
            list.insert(doc, at: at)
            shard[token] = list
        }
    }

    /// Removes every posting whose doc is dead and tokens left with none. Returns how many went.
    @discardableResult
    static func dropDocs(_ shard: inout SearchShard, dead: (Int) -> Bool) -> Int {
        var removed = 0
        for (token, list) in shard {
            let kept = list.filter { !dead($0) }
            removed += list.count - kept.count
            if kept.isEmpty {
                shard[token] = nil
            } else if kept.count != list.count {
                shard[token] = kept
            }
        }
        return removed
    }

    /// Every doc holding a token that starts with `term`.
    static func prefixDocs(_ shard: SearchShard, term: String) -> Set<Int> {
        var out = Set<Int>()
        for (token, list) in shard where JSText.startsWith(token, term) { out.formUnion(list) }
        return out
    }

    /// A doc's tokens grouped by the shard each belongs in.
    static func byShard(_ tokens: [String]) -> [String: [String]] {
        Dictionary(grouping: tokens, by: shardOf)
    }

    private static func appendVarint(_ value: Int, to out: inout Data) {
        var v = UInt64(value)
        while v >= 0x80 {
            out.append(UInt8(v & 0x7f) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    /// Tokens in byte order: a dictionary has no order of its own, and equal shards should be equal
    /// bytes.
    static func encodeShard(_ shard: SearchShard) -> Data {
        var out = Data()
        appendVarint(shard.count, to: &out)
        for token in shard.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let list = shard[token] ?? []
            let bytes = Data(token.utf8)
            appendVarint(bytes.count, to: &out)
            out.append(bytes)
            appendVarint(list.count, to: &out)
            var previous = 0
            for doc in list {
                appendVarint(doc - previous, to: &out)
                previous = doc
            }
        }
        return out
    }

    /// Throws on a truncated or impossible shard rather than returning half of one. Traps nothing:
    /// the input opened under the index key, but a crash isn't how a damaged file should show.
    static func decodeShard(_ data: Data) throws -> SearchShard {
        let bytes = [UInt8](data)
        var i = 0
        func varint() throws -> Int {
            var value = 0
            var shift = 0
            while true {
                guard i < bytes.count, shift < 63 else { throw SearchShardError() }
                let byte = bytes[i]
                i += 1
                value |= Int(byte & 0x7f) << shift
                guard value >= 0 else { throw SearchShardError() }
                if byte < 0x80 { return value }
                shift += 7
            }
        }
        var shard: SearchShard = [:]
        for _ in 0..<(try varint()) {
            let length = try varint()
            guard length <= bytes.count - i else { throw SearchShardError() }
            let token = String(decoding: bytes[i..<(i + length)], as: UTF8.self)
            i += length
            var list: [Int] = []
            var previous = 0
            for _ in 0..<(try varint()) {
                let (next, overflow) = previous.addingReportingOverflow(try varint())
                guard !overflow else { throw SearchShardError() }
                list.append(next)
                previous = next
            }
            shard[token] = list
        }
        return shard
    }
}

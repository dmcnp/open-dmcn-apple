import Foundation

// The search box: what a query means, and whether one message matches it. Pure. Parity with the
// browser's lib/search/query.ts.
//
// Operators read the header every row already holds plus the owner's flags, labels and folders, so
// they apply the moment they're typed. Only bare words, also looked for in message text, and
// filename: need the index. Those arrive as `SearchHits`, a little later; until then a row matches on
// its header alone.
//
//   from:x  to:x  subject:x  has:attachment  filename:x  is:unread|read|starred  label:x
//   in:inbox|archive|sent|deleted|<folder name>
//   before:YYYY-MM-DD  after:YYYY-MM-DD  word  "quoted words"  -anything (negates it)
//
// Clauses all have to hold. Anything that isn't a known operator with a usable value is an ordinary
// word, so a colon in a search ("re:", a time, a URL) never turns into an error or into nothing.

/// A filename pattern with a wildcard, matched against a whole name: `*` is any run, `?` exactly one.
/// One of what the browser counts: a UTF-16 unit, so `?` is half an emoji there and here.
public struct FilenameGlob: Sendable, Equatable {
    private let pattern: [UInt16]

    /// Nil without a wildcard: the value then matches anywhere in a name.
    public init?(_ pattern: String) {
        guard pattern.unicodeScalars.contains(where: { $0 == "*" || $0 == "?" }) else { return nil }
        self.pattern = Array(pattern.utf16)
    }

    public func matches(_ name: String) -> Bool {
        let text = Array(name.utf16)
        let (star, one) = (UInt16(UInt8(ascii: "*")), UInt16(UInt8(ascii: "?")))
        var (t, p) = (0, 0)
        var resume: (pattern: Int, text: Int)?
        while t < text.count {
            if p < pattern.count, pattern[p] == star {
                resume = (p + 1, t)
                p += 1
            } else if p < pattern.count, pattern[p] == one || pattern[p] == text[t] {
                t += 1
                p += 1
            } else if let last = resume {
                resume = (last.pattern, last.text + 1)
                (p, t) = (last.pattern, last.text + 1)
            } else {
                return false
            }
        }
        return pattern[p...].allSatisfy { $0 == star }
    }
}

public struct SearchClause: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case from(String)
        case to(String)
        case subject(String)
        case label(String)
        case place(String)
        case word(String)
        case filename(String, FilenameGlob?)
        case hasAttachment
        case isUnread
        case isRead
        case isStarred
        /// Unix seconds.
        case before(Int64)
        case after(Int64)
    }

    public var negated: Bool
    public var kind: Kind

    public init(negated: Bool = false, _ kind: Kind) {
        self.negated = negated
        self.kind = kind
    }
}

public struct ParsedQuery: Sendable, Equatable {
    public var clauses: [SearchClause]
    /// Word values to look up in message text and attachment names.
    public var words: [String]
    /// filename: values to look up in attachment names.
    public var filenames: [String]

    public init(clauses: [SearchClause] = [], words: [String] = [], filenames: [String] = []) {
        self.clauses = clauses
        self.words = words
        self.filenames = filenames
    }
}

/// Which messages the index found for each word and each filename: value, by message hash.
public struct SearchHits: Sendable, Equatable {
    public var words: [String: Set<String>]
    public var files: [String: Set<String>]

    public init(words: [String: Set<String>] = [:], files: [String: Set<String>] = [:]) {
        self.words = words
        self.files = files
    }
}

/// What a match reads about the owner's own state.
public struct MatchContext {
    /// The owner's name for an address, or the address itself.
    public var nameFor: (String) -> String
    public var isRead: (String) -> Bool
    public var isStarred: (String) -> Bool
    /// Names of the labels on a message.
    public var labelNames: (String) -> [String]
    /// Names of the views a message is listed in: inbox, archive, sent, deleted, or a folder's name.
    public var placeNames: (String) -> [String]

    public init(
        nameFor: @escaping (String) -> String, isRead: @escaping (String) -> Bool,
        isStarred: @escaping (String) -> Bool, labelNames: @escaping (String) -> [String],
        placeNames: @escaping (String) -> [String]
    ) {
        self.nameFor = nameFor
        self.isRead = isRead
        self.isStarred = isStarred
        self.labelNames = labelNames
        self.placeNames = placeNames
    }
}

extension MailSearch {
    private static let fieldOperators: Set<String> = [
        "from", "to", "subject", "label", "in", "filename", "has", "is", "before", "after",
    ]

    /// Midnight at the start of a YYYY-MM-DD day in `timeZone`, in unix seconds; nil if not a date.
    private static func dayStart(_ value: String, timeZone: TimeZone) -> Int64? {
        let parts = value.utf8.split(omittingEmptySubsequences: false) {
            $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "/")
        }
        guard parts.count == 3, parts[0].count == 4, (1...2).contains(parts[1].count), (1...2).contains(parts[2].count),
            parts.allSatisfy({ $0.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) } })
        else { return nil }
        let numbers = parts.map { Int(String(decoding: $0, as: UTF8.self)) ?? 0 }
        let (year, month, day) = (numbers[0], numbers[1], numbers[2])
        // The browser's Date reads years below 100 as 19xx, and then refuses them for not round-tripping.
        guard year >= 100, (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        return Int64(date.timeIntervalSince1970.rounded(.down))
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// One clause from an operator and its unquoted value, or nil when the pair isn't usable, and
    /// the raw text is then a word.
    private static func clause(
        _ op: String, _ raw: String, negated: Bool, timeZone: TimeZone
    ) -> SearchClause? {
        let value = fold(JSText.trim(raw))
        if value.isEmpty { return nil }
        let kind: SearchClause.Kind? =
            switch op {
            case "from": .from(value)
            case "to": .to(value)
            case "subject": .subject(value)
            case "label": .label(value)
            // What other mail clients call Deleted, so a habit typed here still finds it.
            case "in": .place(value == "trash" || value == "bin" ? "deleted" : value)
            case "filename": .filename(value, FilenameGlob(value))
            case "has": value == "attachment" || value == "attachments" ? .hasAttachment : nil
            case "is":
                switch value {
                case "unread": .isUnread
                case "read": .isRead
                case "starred": .isStarred
                default: nil
                }
            case "before": dayStart(value, timeZone: timeZone).map(SearchClause.Kind.before)
            case "after": dayStart(value, timeZone: timeZone).map(SearchClause.Kind.after)
            default: nil
            }
        return kind.map { SearchClause(negated: negated, $0) }
    }

    public static func parseQuery(_ input: String, timeZone: TimeZone = .current) -> ParsedQuery {
        let s = Array(JSText.trim(input).unicodeScalars)
        var i = 0
        var clauses: [SearchClause] = []
        func isSpace(_ at: Int) -> Bool { at >= s.count || JSText.isWhitespace(s[at]) }
        func string(_ range: Range<Int>) -> String {
            var out = String.UnicodeScalarView()
            out.append(contentsOf: s[range])
            return String(out)
        }
        // A value runs to the next space, or, opened with a quote, to the closing quote (or the end,
        // while it's still being typed).
        func readValue() -> String {
            if i < s.count, s[i] == "\"" {
                let end = s[(i + 1)...].firstIndex(of: "\"")
                let value = string((i + 1)..<(end ?? s.count))
                i = end.map { $0 + 1 } ?? s.count
                return value
            }
            let start = i
            while !isSpace(i) { i += 1 }
            return string(start..<i)
        }
        func operatorName(at start: Int) -> String? {
            var j = start
            while j < s.count, s[j].isASCII, s[j].properties.isAlphabetic { j += 1 }
            return j > start && j < s.count && s[j] == ":" ? string(start..<j) : nil
        }

        while i < s.count {
            while i < s.count, isSpace(i) { i += 1 }
            if i >= s.count { break }
            let start = i
            let negated = s[i] == "-" && !isSpace(i + 1)
            if negated { i += 1 }
            var found: SearchClause?
            if let op = operatorName(at: i), fieldOperators.contains(op.lowercased()), !isSpace(i + op.count + 1) {
                i += op.count + 1
                found = clause(op.lowercased(), readValue(), negated: negated, timeZone: timeZone)
                if found == nil {
                    // Not a usable operator after all: the whole thing, as typed, is a word.
                    let raw = string((negated ? start + 1 : start)..<i)
                    let value = fold(raw.replacingOccurrences(of: "\"", with: ""))
                    if !value.isEmpty { found = SearchClause(negated: negated, .word(value)) }
                }
            } else {
                let value = fold(readValue())
                if !value.isEmpty { found = SearchClause(negated: negated, .word(value)) }
            }
            if let found { clauses.append(found) }
        }

        var words: [String] = []
        var filenames: [String] = []
        for clause in clauses {
            if case .word(let value) = clause.kind, !words.contains(value) { words.append(value) }
            if case .filename(let value, _) = clause.kind, !filenames.contains(value) { filenames.append(value) }
        }
        return ParsedQuery(clauses: clauses, words: words, filenames: filenames)
    }

    /// Whether a filename matches a filename: value, folded on both sides.
    public static func filenameMatches(_ name: String, value: String, glob: FilenameGlob?) -> Bool {
        let folded = fold(name)
        return glob?.matches(folded) ?? JSText.includes(folded, value)
    }

    private static func anyIncludes(_ fields: [String], _ value: String) -> Bool {
        fields.contains { JSText.includes(fold($0), value) }
    }

    /// Only what the checks let count as the sender. A forged header naming a contact isn't mail
    /// from them, so `from:` doesn't find it.
    private static func senderFields(_ m: MailPreview, _ ctx: MatchContext) -> [String] {
        let address = m.attributedAddress
        return [address, m.senderDisplay, ctx.nameFor(address)]
    }

    private static func recipientFields(_ m: MailPreview, _ ctx: MatchContext) -> [String] {
        let addresses = ([m.recipientAddress, m.deliveredTo ?? ""] + m.to + m.cc + m.bcc).filter { !$0.isEmpty }
        return addresses + addresses.map(ctx.nameFor)
    }

    private static func holds(
        _ m: MailPreview, _ clause: SearchClause, _ ctx: MatchContext, _ hits: SearchHits?
    ) -> Bool {
        switch clause.kind {
        case .from(let value): anyIncludes(senderFields(m, ctx), value)
        case .to(let value): anyIncludes(recipientFields(m, ctx), value)
        case .subject(let value): JSText.includes(fold(m.subject), value)
        case .label(let value): ctx.labelNames(m.hash).contains { JSText.same(fold($0), value) }
        case .place(let value): ctx.placeNames(m.hash).contains { JSText.same(fold($0), value) }
        case .hasAttachment: m.attachmentCount > 0
        case .isStarred: ctx.isStarred(m.hash)
        case .isRead: ctx.isRead(m.hash)
        case .isUnread: !ctx.isRead(m.hash)
        case .before(let at): m.sentAt < at
        case .after(let at): m.sentAt >= at
        case .filename(let value, _): hits?.files[value]?.contains(m.hash) ?? false
        case .word(let value):
            anyIncludes(senderFields(m, ctx) + recipientFields(m, ctx) + [m.subject, m.snippet], value)
                || hits?.words[value]?.contains(m.hash) ?? false
        }
    }

    /// Whether a message matches every clause. An empty query matches everything.
    public static func matches(
        _ m: MailPreview, _ query: ParsedQuery, context: MatchContext, hits: SearchHits?
    ) -> Bool {
        query.clauses.allSatisfy { holds(m, $0, context, hits) != $0.negated }
    }
}

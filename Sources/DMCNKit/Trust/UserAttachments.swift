import Foundation

// The attachments a person sent, as opposed to the ones the protocol carries alongside them. Parity
// with the browser's lib/userAttachments.ts, and sanitizeFilename in components/MessageReader.tsx.

/// One decrypted attachment, as a reader holds it.
public struct MessageAttachment: Sendable, Equatable {
    public let filename: String
    public let contentType: String
    public let content: Data
    /// The bare MIME Content-ID an inline part is referenced by as `cid:`. Empty otherwise.
    public let contentID: String
    /// "inline", "attachment" or "".
    public let disposition: String

    public init(filename: String, contentType: String, content: Data, contentID: String = "", disposition: String = "")
    {
        self.filename = filename
        self.contentType = contentType
        self.content = content
        self.contentID = contentID
        self.disposition = disposition
    }

    init(_ record: Dmcn_Message_AttachmentRecord) {
        self.init(
            filename: record.filename, contentType: record.contentType, content: record.content,
            contentID: record.contentID, disposition: record.disposition)
    }

    /// Whether it renders inside the HTML body rather than being offered as a download.
    public var isInline: Bool { disposition == "inline" }

    /// The name to save it under. A hostile filename can't climb out of a directory or masquerade.
    public var safeFilename: String { Self.safeFilename(filename) }

    static func safeFilename(_ name: String) -> String {
        var clean = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", "\\": clean.append("_")
            case "\u{00}"..."\u{1F}", "\u{7F}": break
            default: clean.append(scalar)
            }
        }
        while clean.first == "." { clean.removeFirst() }
        let safe = JSText.prefixUTF16(JSText.trim(String(clean)), 200)
        return safe.isEmpty ? "attachment" : safe
    }
}

public enum UserAttachments {
    /// What the reader lists. The bridge's raw source is hidden by its slot, not its type, as an email
    /// forwarded as an attachment is message/rfc822 too and is the reader's to see. It's offered
    /// through "View source" instead. `internalTypes` are what this build carries for its own purposes.
    public static func filter(_ all: [MessageAttachment], internalTypes: [String] = []) -> [MessageAttachment] {
        let hidden = Set(internalTypes + [BridgeRecord.classificationContentType, BridgeRecord.receiptContentType])
        let original = BridgeRecord.originalIndex(
            contentTypes: all.map(\.contentType), filenames: all.map(\.filename))
        return all.enumerated()
            .filter { $0.offset != original && !hidden.contains($0.element.contentType) }
            .map(\.element)
    }
}

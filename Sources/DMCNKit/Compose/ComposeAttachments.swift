import Crypto
import Foundation

// What can ride with a message. Attachments travel inside the sealed body, under the same key as
// the text, so everything is read fully into memory. Parity with the attachment half of the
// browser's components/ComposeDialog.tsx.

public enum ComposeAttachments {
    /// The total per message, inline images included: about 25 MB, which suits the size-class
    /// padding (whole megabytes above 1 MB) and stays reasonable in memory.
    public static let maxTotalBytes = 25 * 1024 * 1024

    public static let capMessage = "Attachments can’t exceed \(maxTotalBytes / (1024 * 1024)) MB in total."

    /// A file a person picked.
    public struct File: Sendable, Equatable {
        public var name: String
        /// Empty when the type isn't known.
        public var contentType: String
        public var content: Data

        public init(name: String, contentType: String = "", content: Data) {
            self.name = name
            self.contentType = contentType
            self.content = content
        }
    }

    /// 16 random bytes with the RFC 4122 version 4 bits set: an attachment id or a message id.
    public static func newUUID() -> Data {
        var id = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        id[6] = (id[6] & 0x0f) | 0x40
        id[8] = (id[8] & 0x3f) | 0x80
        return id
    }

    public static func totalBytes(_ attachments: [DraftAttachment]) -> Int {
        attachments.reduce(0) { $0 + $1.sizeBytes }
    }

    /// `existing` with `files` added. A batch that would pass the cap adds nothing at all, so the
    /// composer never holds a set it can't send.
    public static func adding(_ files: [File], to existing: [DraftAttachment]) throws -> [DraftAttachment] {
        var running = totalBytes(existing)
        var additions: [DraftAttachment] = []
        for file in files {
            running += file.content.count
            guard running <= maxTotalBytes else { throw ComposeError.attachmentsTooLarge }
            additions.append(
                DraftAttachment(
                    attachmentID: newUUID(), filename: file.name, contentType: typeOrDefault(file.contentType),
                    sizeBytes: file.content.count, contentHash: Data(SHA256.hash(data: file.content)),
                    content: file.content))
        }
        return existing + additions
    }

    /// `existing` with an image the body refers to by `cid:`, and that reference's id. It counts
    /// towards the cap like any attachment, but isn't listed for download.
    public static func addingInlineImage(
        _ file: File, to existing: [DraftAttachment]
    ) throws -> (attachments: [DraftAttachment], contentID: String) {
        guard totalBytes(existing) + file.content.count <= maxTotalBytes else {
            throw ComposeError.attachmentsTooLarge
        }
        let contentID = newUUID().hex + "@dmcn"
        let image = DraftAttachment(
            attachmentID: newUUID(), filename: file.name.isEmpty ? "image" : file.name,
            contentType: typeOrDefault(file.contentType), sizeBytes: file.content.count,
            contentHash: Data(SHA256.hash(data: file.content)), content: file.content, contentID: contentID,
            disposition: "inline")
        return (existing + [image], contentID)
    }

    /// What goes out with `html`: every ordinary attachment, and only the inline images it still
    /// refers to. An image inserted and deleted again stays on the list, and must not ride along.
    /// Plain text refers to none.
    public static func forSending(_ attachments: [DraftAttachment], html: String?) -> [DraftAttachment] {
        let referenced = Set(cidReferences(in: html ?? ""))
        return attachments.filter { $0.disposition != "inline" || referenced.contains($0.contentID ?? "") }
    }

    /// The ids in each `src="cid:…"`, written exactly so by the sanitizer the HTML came through.
    static func cidReferences(in html: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(html)
        let opening = "src=\"cid:"
        while let start = rest.range(of: opening) {
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            ids.append(String(rest[..<end]))
            rest = rest[rest.index(after: end)...]
        }
        return ids
    }

    private static func typeOrDefault(_ contentType: String) -> String {
        contentType.isEmpty ? "application/octet-stream" : contentType
    }
}

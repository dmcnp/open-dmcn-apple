import Foundation

/// Where a mailbox's contents and directory answers come from.
///
/// `Inbox` works against this, so it doesn't care how the mail arrives. `WebHostClient` is the
/// real implementation today, and `SampleMailbox` serves an in-memory one for previews and
/// tests.
public protocol MailboxService: Sendable {
    /// One page of the mailbox, newest first.
    func list(_ keys: some AccountKeys, limit: Int, cursor: String?) async throws -> MailboxPage
    /// The sealed body of one message, by the hash its listing named.
    func body(hash: String, keys: some AccountKeys) async throws -> Dmcn_Relay_MailboxBody
    /// The directory's answer for an address. Throws when the address doesn't resolve.
    func lookup(_ address: String) async throws -> IdentityLookup
    func signOut() async
}

extension WebHostClient: MailboxService {}

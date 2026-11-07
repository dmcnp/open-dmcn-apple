import DMCNKitSamples
import Foundation
import Testing
@testable import DMCNKit

/// What the inbox shows for each way a sender can turn out, run through the real seal, open and
/// reader-check code against the sample mailbox.
@Suite struct WhatTheInboxShows {
    /// A service that remembers whether a body was fetched.
    actor Watching: MailboxService {
        let inner: SampleMailbox
        var bodiesFetched = 0
        init(_ inner: SampleMailbox) { self.inner = inner }

        func list(_ keys: some AccountKeys, limit: Int, cursor: String?) async throws -> MailboxPage {
            try await inner.list(keys, limit: limit, cursor: cursor)
        }
        func body(hash: String, keys: some AccountKeys) async throws -> Dmcn_Relay_MailboxBody {
            bodiesFetched += 1
            return try await inner.body(hash: hash, keys: keys)
        }
        func lookup(_ address: String) async throws -> IdentityLookup { try await inner.lookup(address) }
        func signOut() async {}
    }

    func messages() async throws -> (inbox: Inbox, service: Watching, bySubject: [String: MessageSummary]) {
        let sample = try SampleMailbox()
        let service = Watching(sample)
        let inbox = Inbox(service: service, keys: sample.keys)
        let (summaries, next) = try await inbox.summaries()
        #expect(next == nil)
        #expect(summaries.count == 6)
        return (inbox, service, Dictionary(uniqueKeysWithValues: summaries.map { ($0.subject, $0) }))
    }

    @Test func aVerifiedSenderOpens() async throws {
        let (inbox, _, messages) = try await messages()
        let message = try #require(messages["A verified sender"])
        #expect(message.sender == .verified("ada@sample.example"))
        #expect(!message.snippet.isEmpty)
        #expect(!message.misaddressed)
        guard case .plainText(let text) = try await inbox.open(message) else {
            Issue.record("expected the body")
            return
        }
        #expect(text.hasPrefix("The directory lists"))
    }

    @Test func anUnresolvedSenderOpensUnconfirmed() async throws {
        let (inbox, _, messages) = try await messages()
        let message = try #require(messages["An unverified sender"])
        #expect(message.sender == .unverified("someone@elsewhere.example"))
        #expect(!message.contentsWithheld)
        #expect(try await inbox.open(message) != .withheld)
    }

    @Test func aForgedSenderIsWithheldAndItsBodyNeverFetched() async throws {
        let (inbox, service, messages) = try await messages()
        let message = try #require(messages["A forged sender"])
        #expect(message.contentsWithheld && message.attributionWithheld)
        #expect(message.snippet.isEmpty)
        #expect(try await inbox.open(message) == .withheld)
        #expect(await service.bodiesFetched == 0)
    }

    @Test func aDisownedSenderCanBeReadButIsntAttributed() async throws {
        let (inbox, service, messages) = try await messages()
        let message = try #require(messages["A sender the domain no longer vouches for"])
        #expect(!message.contentsWithheld && message.attributionWithheld)
        #expect(message.snippet.isEmpty)
        #expect(message.senderDisplay == nil)
        #expect(try await inbox.open(message) != .withheld)
        #expect(await service.bodiesFetched == 1)
    }

    @Test func theTwoDistrustedCasesStayDistinct() async throws {
        let (_, _, messages) = try await messages()
        #expect(messages["A forged sender"]?.sender == .mismatch(claimed: "ada@sample.example"))
        #expect(
            messages["A sender the domain no longer vouches for"]?.sender == .disowned(claimed: "former@sample.example")
        )
    }

    @Test func aRowThatWontOpenIsKeptAndWithheld() async throws {
        let (inbox, service, messages) = try await messages()
        let message = try #require(messages[""])
        #expect(message.sender == .unreadable)
        #expect(try await inbox.open(message) == .withheld)
        #expect(await service.bodiesFetched == 0)
    }

    @Test func aCopyWrittenToSomeoneElseIsFlaggedButOpens() async throws {
        let (inbox, _, messages) = try await messages()
        let message = try #require(messages["A message written to someone else"])
        #expect(message.misaddressed)
        #expect(message.sender == .verified("ada@sample.example"))
        #expect(try await inbox.open(message) != .withheld)
    }
}

import Crypto
import Foundation
import Testing
@testable import DMCNKit

/// What the browser scenarios can't show: where this client goes its own way on purpose, the words,
/// and the flow around a send. `BrowserSendScenarios` holds the send itself to the browser.
private struct Rig {
    let alice = SoftwareAccountKeys(address: "alice@parity.example")
    let bob = SoftwareAccountKeys(address: "bob@parity.example")
    let cy = SoftwareAccountKeys(address: "cy@parity.example")
    let host: ComposeHost
    let client: WebHostClient
    let contacts: ContactStore
    let storage = InMemoryPersonalStorage()

    init() async throws {
        host = ComposeHost(sender: alice.ed25519Public)
        client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)
        try await client.signIn(alice)
        contacts = ContactStore(
            storage: InMemoryPersonalStorage(), pins: InMemoryPersonalStorage(), owner: alice.address,
            deviceID: fill(16, 1))
        await host.setDirectory(bob.address, Self.answer(bob))
        await host.setDirectory(cy.address, Self.answer(cy))
    }

    static func answer(_ keys: SoftwareAccountKeys, _ extra: [String: JSONValue] = [:]) -> ComposeHost.Answer {
        var body: [String: JSONValue] = [
            "address": .string(keys.address), "ed25519_pub": .string(keys.ed25519Public.base64EncodedString()),
            "x25519_pub": .string(keys.x25519Public.base64EncodedString()), "fingerprint": .string("fp"),
        ]
        body.merge(extra) { $1 }
        return .init(status: 200, body: body)
    }

    func composer(
        identities: [any AccountKeys] = [], legacyRoute: (any LegacyMailRoute)? = nil, extraFields: SendFields? = nil
    ) -> Composer {
        Composer(
            host: client, account: alice, deviceID: fill(16, 1), contacts: contacts,
            sent: SentStore(storage: storage, keys: alice), identities: identities, legacyRoute: legacyRoute,
            extraFields: extraFields, now: { 1_770_000_000_123 })
    }

    func message(to: [String]) -> DraftContent {
        DraftContent(from: "", to: to, subject: "Hello", text: "Hi.")
    }

    func keptCopies() async throws -> Int {
        try await storage.list(prefix: "sent/", as: StoredSentHeader.self).count
    }
}

@Suite struct ComposerSending {
    @Test func noCopyGoesWhenALaterRecipientCantBeResolved() async throws {
        let rig = try await Rig()
        await #expect(throws: ComposeError.notReachable("nobody@else.example")) {
            try await rig.composer().send(rig.message(to: [rig.bob.address, "nobody@else.example"]))
        }
        #expect(await rig.host.posts.isEmpty)
        #expect(try await rig.keptCopies() == 0)
    }

    @Test func anOutageIsNotAMissingIdentity() async throws {
        let rig = try await Rig()
        await rig.host.setDirectory(rig.bob.address, .init(status: 502, body: ["error": .string("down")]))
        // The route must not be taken: a bridge would read mail meant to be end-to-end encrypted.
        let route = FakeLegacyRoute(bridge: rig.cy.x25519Public)
        await #expect(throws: ComposeError.lookupFailed(rig.bob.address)) {
            try await rig.composer(legacyRoute: route).send(rig.message(to: [rig.bob.address]))
        }
        #expect(await route.deliveries.isEmpty)
    }

    @Test func aRefusalPartWaySaysWhoHasItAndWhoDoesnt() async throws {
        let rig = try await Rig()
        await rig.host.refuse(rig.cy.address, status: 507)
        let report = try await rig.composer().send(rig.message(to: [rig.bob.address, rig.cy.address]))
        #expect(report.delivered == [rig.bob.address])
        #expect(report.undelivered.map(\.address) == [rig.cy.address])
        #expect(report.retry == .init(to: [rig.cy.address], cc: [], bcc: []))
        #expect(
            PartialSend.message(delivered: report.delivered, undelivered: report.undelivered)
                == "This message reached bob@parity.example. cy@parity.example's mailbox is full, so your message was not delivered to them. Press Send to try again. It will go only to cy@parity.example."
        )
    }

    @Test func oneFailureDoesntStopTheRecipientsAfterIt() async throws {
        let rig = try await Rig()
        await rig.host.refuse(rig.bob.address, status: 507)
        let report = try await rig.composer().send(rig.message(to: [rig.bob.address, rig.cy.address]))
        #expect(report.delivered == [rig.cy.address])
        #expect(report.undelivered.map(\.address) == [rig.bob.address])
    }

    @Test func whenNobodyGotItTheSendFails() async throws {
        let rig = try await Rig()
        await rig.host.refuse(rig.bob.address, status: 507)
        await rig.host.refuse(rig.cy.address, status: 507)
        await #expect(throws: ComposeError.mailboxFull(rig.bob.address)) {
            try await rig.composer().send(rig.message(to: [rig.bob.address, rig.cy.address]))
        }
    }

    @Test func theRetryOnlyGoesToWhoMissedItAndJoinsTheThread() async throws {
        let rig = try await Rig()
        await rig.host.refuse(rig.cy.address, status: 507)
        let first = try await rig.composer().send(rig.message(to: [rig.bob.address, rig.cy.address]))
        await rig.host.accept(rig.cy.address)
        var again = rig.message(to: first.retry.to)
        again.replyTo = ComposeReplyTo(to: [], subject: "", threadId: first.threadID)
        let second = try await rig.composer().send(again)
        #expect(second.delivered == [rig.cy.address])
        #expect(second.undelivered.isEmpty)
        #expect(second.threadID == first.threadID)
        #expect(second.messageID != first.messageID)
    }

    @Test func aFailedBccIsNeverMovedIntoTo() {
        let all = PartialSend.Audience(to: ["a@x"], cc: ["c@x"], bcc: ["d@x"])
        let failed = [PartialSend.Undelivered(address: "D@X", reason: "")]
        #expect(PartialSend.retry(all, undelivered: failed) == .init(to: [], cc: [], bcc: ["d@x"]))
        #expect(PartialSend.reached(all, undelivered: failed) == .init(to: ["a@x"], cc: ["c@x"], bcc: []))
    }

    @Test func aFailedCcMovesUpWhenToWouldBeEmpty() {
        let all = PartialSend.Audience(to: ["a@x"], cc: ["c@x"], bcc: [])
        let failed = [PartialSend.Undelivered(address: "c@x", reason: "")]
        #expect(PartialSend.retry(all, undelivered: failed) == .init(to: ["c@x"], cc: [], bcc: []))
    }

    @Test func aForwardThatWentCountsAsReached() async throws {
        let rig = try await Rig()
        await rig.host.setDirectory(rig.bob.address, Rig.answer(rig.bob, ["forward_to": .string("dee@parity.example")]))
        await rig.host.setDirectory("dee@parity.example", Rig.answer(rig.cy))
        await rig.host.refuse(rig.cy.address, status: 507)
        let report = try await rig.composer().send(rig.message(to: [rig.bob.address, rig.cy.address]))
        #expect(report.delivered == [rig.bob.address, "dee@parity.example"])
        #expect(report.undelivered.map(\.address) == [rig.cy.address])
    }

    @Test func aSizeInAStoredDraftCantCrashASend() async throws {
        let rig = try await Rig()
        var content = rig.message(to: [rig.bob.address])
        content.attachments = [
            DraftAttachment(
                attachmentID: fill(16, 1), filename: "a", contentType: "x", sizeBytes: -1, contentHash: fill(32, 2),
                content: Data([1]))
        ]
        try await rig.composer().send(content)
        #expect(await rig.host.posts.count == 1)
    }

    @Test func thePrivateRouteIsNeverDroppedForADirectOne() async throws {
        let rig = try await Rig()
        await rig.host.setDirectory(rig.bob.address, Rig.answer(rig.bob, ["require_onion": .bool(true)]))
        await rig.host.refuse(rig.bob.address, status: 502)
        await #expect(throws: ComposeError.privateRouteFailed(rig.bob.address)) {
            try await rig.composer().send(rig.message(to: [rig.bob.address]))
        }
        #expect(await rig.host.posts.isEmpty)
        #expect(await rig.host.attempts == 1)
    }

    /// The browser reads a half-typed recipient's policy too late for this send. Here it counts.
    @Test func aHalfTypedRecipientsPolicyCounts() async throws {
        let rig = try await Rig()
        await rig.host.setDirectory(rig.cy.address, Rig.answer(rig.cy, ["require_onion": .bool(true)]))
        var content = rig.message(to: [rig.bob.address])
        content.pending.cc = rig.cy.address
        try await rig.composer().send(content)
        #expect(await rig.host.posts.map(\.onion) == [true, true])
    }

    @Test func aKeyThatChangedIsSealedToAndSent() async throws {
        let rig = try await Rig()
        try await rig.contacts.allowlist(
            ContactRecord(
                address: rig.bob.address, name: "Bob", fingerprint: "", provenance: .inPerson,
                ed25519Pub: fill(32, 1).base64EncodedString(), x25519Pub: fill(32, 2).base64EncodedString()))
        let report = try await rig.composer().send(rig.message(to: [rig.bob.address]))
        #expect(report.items.isEmpty)
        #expect(await rig.host.posts.count == 1)
    }

    @Test func aSessionThatLapsedIsRenewedOnce() async throws {
        let rig = try await Rig()
        await rig.host.expireSessionOnce()
        try await rig.composer().send(rig.message(to: [rig.bob.address]))
        #expect(await rig.host.posts.count == 1)
    }

    @Test func aBuildCanAddItsOwnFieldsOverTheEnvelopeHash() async throws {
        let rig = try await Rig()
        try await rig.composer(extraFields: { hash in ["extension_field": hash.hex] })
            .send(rig.message(to: [rig.bob.address]))
        let post = try #require(await rig.host.posts.first)
        let hash = Data(SHA256.hash(data: try Canonical.marshal(post.envelope)))
        #expect(post.fields.string("extension_field") == hash.hex)
    }

    @Test func theTimestampIsWholeSeconds() async throws {
        let rig = try await Rig()
        try await rig.composer().send(rig.message(to: [rig.bob.address]))
        let post = try #require(await rig.host.posts.first)
        #expect(post.envelope.createdAt == 1_770_000_000)
        let opened = try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: post.envelope), keys: rig.bob)
        #expect(opened.header.sentAt == 1_770_000_000)
    }

    @Test func goesOutAsTheChosenIdentity() async throws {
        let rig = try await Rig()
        let alias = SoftwareAccountKeys(address: "alias@parity.example")
        var content = rig.message(to: [rig.bob.address])
        content.from = alias.address
        // ComposeHost holds the account's key, and refuses another's, so it stands in for a host that
        // takes the alias's key here.
        await rig.host.expectSender(alias.ed25519Public)
        try await rig.composer(identities: [alias]).send(content)
        let post = try #require(await rig.host.posts.first)
        #expect(post.fields.string("sender_address") == alias.address)
        let opened = try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: post.envelope), keys: rig.bob)
        #expect(opened.header.senderAddress == alias.address)
        #expect(opened.header.senderPublicKey == alias.ed25519Public)

        // Sent is one list, read with the account's key, and says which address it went out as.
        let kept = try await rig.storage.list(prefix: "sent/", as: StoredSentHeader.self)
        let copy = try #require(kept.first).value
        #expect(try copy.open(with: rig.alice).header.senderAddress == alias.address)
    }

    @Test func htmlIsSentOnlyWhenHandedInAsSanitized() async throws {
        let rig = try await Rig()
        var content = rig.message(to: [rig.bob.address])
        content.rich = true
        content.html = "<p onclick=\"x()\">Hi.</p>"
        try await rig.composer().send(content)
        var post = try #require(await rig.host.posts.last)
        var opened = try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: post.envelope), keys: rig.bob)
        var body = try SplitMessage.openBody(Dmcn_Relay_MailboxBody(filing: post.envelope), of: opened)
        #expect(body.alternatives.isEmpty)

        try await rig.composer().send(content, sanitizedHTML: "<p>Hi.</p>")
        post = try #require(await rig.host.posts.last)
        opened = try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: post.envelope), keys: rig.bob)
        body = try SplitMessage.openBody(Dmcn_Relay_MailboxBody(filing: post.envelope), of: opened)
        #expect(body.alternatives.map(\.contentType) == ["text/html"])
    }

    @Test func aHollowRichBodyIsAnEmptyMessage() async throws {
        let rig = try await Rig()
        var content = rig.message(to: [rig.bob.address])
        content.text = " \n"
        try await rig.composer().send(content, sanitizedHTML: "<p><br></p>")
        var post = try #require(await rig.host.posts.last)
        var opened = try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: post.envelope), keys: rig.bob)
        var body = try SplitMessage.openBody(Dmcn_Relay_MailboxBody(filing: post.envelope), of: opened)
        #expect(body.alternatives.isEmpty)
        #expect(body.body.content.isEmpty)

        // An image with no text is a message.
        try await rig.composer().send(content, sanitizedHTML: "<IMG\nsrc=\"cid:a\">")
        post = try #require(await rig.host.posts.last)
        opened = try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: post.envelope), keys: rig.bob)
        body = try SplitMessage.openBody(Dmcn_Relay_MailboxBody(filing: post.envelope), of: opened)
        #expect(body.alternatives.count == 1)
    }

    @Test func tooMuchAttachedIsRefusedBeforeAnythingGoes() async throws {
        let rig = try await Rig()
        var content = rig.message(to: [rig.bob.address])
        let content25 = Data(count: ComposeAttachments.maxTotalBytes + 1)
        content.attachments = [
            DraftAttachment(
                attachmentID: fill(16, 1), filename: "a", contentType: "x", sizeBytes: content25.count,
                contentHash: fill(32, 2), content: content25)
        ]
        await #expect(throws: ComposeError.attachmentsTooLarge) {
            try await rig.composer().send(content)
        }
        #expect(await rig.host.lookups.isEmpty)
    }

    @Test func removesTheDraftOnceSent() async throws {
        let rig = try await Rig()
        let drafts = DraftStore(storage: rig.storage, address: rig.alice.address)
        let timers = ManualTimers()
        let autosave = DraftAutosave(store: drafts, opening: rig.message(to: []), timers: timers)
        await autosave.edited(rig.message(to: [rig.bob.address]))
        await timers.advance(3000)
        #expect(try await drafts.list().count == 1)
        try await rig.composer().send(rig.message(to: [rig.bob.address]), autosave: autosave)
        #expect(try await drafts.list().isEmpty)
    }

    @Test func errorsAreInPlainWords() {
        let words = [
            ComposeError.noRecipients, .attachmentsTooLarge, .notReachable("a@x"), .lookupFailed("a@x"),
            .accountClosed("a@x"), .mailboxFull("a@x"), .privateRouteFailed("a@x"), .notDelivered("a@x"),
        ].compactMap(\.errorDescription)
        #expect(words.count == 8)
        for text in words {
            #expect(!text.contains("—"))
            for jargon in ["onion", "relay", "envelope", "STORE", "x25519", "404", "502"] {
                #expect(!text.lowercased().contains(jargon.lowercased()), "\(text)")
            }
        }
    }
}

@Suite struct ComposerLookup {
    @Test func aBridgeAnswerHasNoSigningKeyAndStillDecodes() async throws {
        let rig = try await Rig()
        let bridge = SoftwareAccountKeys(address: "bridge@parity.example")
        await rig.host.setDirectory(
            "ext@mail.example",
            .init(
                status: 200,
                body: [
                    "address": .string("ext@mail.example"), "legacy": .bool(true),
                    "x25519_pub": .string(bridge.x25519Public.base64EncodedString()),
                    "relay_hints": .array([.string("/dns4/bridge.example/tcp/7400")]), "verified_tier": .int(0),
                ]))
        let found = try await rig.client.lookupRecipient("ext@mail.example", keys: rig.alice)
        #expect(found.legacy)
        #expect(found.ed25519Pub.isEmpty)
        #expect(found.sealingKey == bridge.x25519Public)
        #expect(ComposePin.facts(from: found) == .absentIdentity)
    }

    @Test func aPlusIsNotASpace() async throws {
        let rig = try await Rig()
        await rig.host.setDirectory("a+b@parity.example", Rig.answer(rig.bob))
        _ = try await rig.client.lookupRecipient("a+b@parity.example", keys: rig.alice)
        #expect(await rig.host.lookups == ["a+b@parity.example"])
    }

    @Test func anAnswerWithNoUsableKeyIsUnreachable() async throws {
        let rig = try await Rig()
        await rig.host.setDirectory(rig.bob.address, .init(status: 200, body: ["x25519_pub": .string("AAAA")]))
        await #expect(throws: ComposeError.notReachable(rig.bob.address)) {
            try await rig.composer().send(rig.message(to: [rig.bob.address]))
        }
    }
}

@Suite struct ComposerRecipients {
    @Test func onlyAnExactRepeatIsARepeat() {
        #expect(
            Composer.uniqueRecipients(to: ["a@x", "A@x"], cc: ["a@x", "b@x"], bcc: ["b@x", "c@x"])
                == ["a@x", "A@x", "b@x", "c@x"])
        // Two spellings of one accent are one string to Swift's ==, and two to JavaScript's.
        #expect(Composer.uniqueRecipients(to: ["\u{e9}@x", "e\u{301}@x"], cc: [], bcc: []).count == 2)
    }
}

@Suite struct ComposerReview {
    private func pin(_ rig: Rig, _ address: String, ed: Data, x: Data, custody: Bool = false) async throws {
        try await rig.contacts.allowlist(
            ContactRecord(
                address: address, name: "Them", fingerprint: "fp0", provenance: .inPerson,
                ed25519Pub: ed.base64EncodedString(), x25519Pub: x.base64EncodedString(), adminKeyCustody: custody))
    }

    @Test func nothingToSayAboutAStranger() async throws {
        let rig = try await Rig()
        let review = await rig.composer().review(rig.message(to: [rig.bob.address]))
        #expect(review.recipients.map(\.kind) == [.identity])
        #expect(review.recipients.map(\.pin) == [.unpinned])
        #expect(review.changedKeyWarnings.isEmpty)
        #expect(review.hasEncryptedRecipient)
        #expect(!review.hasLegacy)
    }

    @Test func aContactIsTrustedAndPinnedOnFirstSighting() async throws {
        let rig = try await Rig()
        try await rig.contacts.put(ContactRecord(address: rig.bob.address, name: "Bob", fingerprint: ""))
        let review = await rig.composer().review(rig.message(to: [rig.bob.address]))
        #expect(review.recipients.map(\.kind) == [.trusted])
        #expect(review.recipients.map(\.pin) == [.match])
        let pinned = await rig.contacts.contact(for: rig.bob.address)?.ed25519Pub
        #expect(pinned == rig.bob.ed25519Public.base64EncodedString())
    }

    @Test func anOutageSaysNothingAboutAnIdentity() async throws {
        let rig = try await Rig()
        try await pin(rig, rig.bob.address, ed: rig.bob.ed25519Public, x: rig.bob.x25519Public)
        await rig.host.setDirectory(rig.bob.address, .init(status: 502, body: ["error": .string("down")]))
        let review = await rig.composer().review(rig.message(to: [rig.bob.address]))
        #expect(review.recipients.map(\.kind) == [.unchecked])
        #expect(review.recipients.map(\.pin) == [.unpinned])
        #expect(review.changedKeyWarnings.isEmpty)
    }

    @Test func aChangedKeyWarnsAndCanBeConfirmed() async throws {
        let rig = try await Rig()
        try await pin(rig, rig.bob.address, ed: fill(32, 1), x: fill(32, 2))
        let composer = rig.composer()
        let content = rig.message(to: [rig.bob.address])
        let review = await composer.review(content)
        #expect(review.changedKeyRecipients == [rig.bob.address])
        #expect(review.changedKeyWarnings == [ComposePin.keyWarning(rig.bob.address)])
        #expect(review.recipients.map(\.kind) == [.trusted])

        try await composer.confirmChange(rig.bob.address, observed: try #require(review.recipients[0].observed))
        let after = await composer.review(content)
        #expect(after.changedKeyRecipients.isEmpty)
        // Confirming a rotation doesn't forget how they were first verified.
        #expect(await rig.contacts.contact(for: rig.bob.address)?.provenance == .inPerson)
        #expect(await rig.contacts.contact(for: rig.bob.address)?.name == "Them")
    }

    @Test func aChangeIsExplainedByWhatTheCallerCanProve() async throws {
        let rig = try await Rig()
        let pinned = fill(32, 1).base64EncodedString()
        try await pin(rig, rig.bob.address, ed: fill(32, 1), x: fill(32, 2))
        let review = await rig.composer().review(
            rig.message(to: [rig.bob.address]),
            explainKeyChange: { address, key in
                address == "bob@parity.example" && key == pinned ? .replaced(at: 1_788_430_860) : .unexplained
            }, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        #expect(
            review.changedKeyWarnings.first?.hasPrefix("The key for bob@parity.example changed on Sep 3, 2026.") == true
        )
    }

    @Test func anIdentityThatWentAwayIsItsOwnWarningAndAConfirmedAbsenceStaysPinned() async throws {
        let rig = try await Rig()
        try await pin(rig, rig.bob.address, ed: rig.bob.ed25519Public, x: rig.bob.x25519Public)
        await rig.host.setDirectory(rig.bob.address, .init(status: 404, body: ["error": .string("identity not found")]))
        let composer = rig.composer()
        let content = rig.message(to: [rig.bob.address])
        let review = await composer.review(content)
        #expect(review.changedKeyWarnings == [ComposePin.identityGoneWarning(rig.bob.address)])
        #expect(review.recipients.map(\.kind) == [.legacy])

        try await composer.confirmChange(rig.bob.address, observed: .absentIdentity)
        #expect(await composer.review(content).changedKeyWarnings.isEmpty)

        // A key appearing later is a change against something, not a first sighting.
        await rig.host.setDirectory(rig.bob.address, Rig.answer(rig.bob))
        await rig.contacts.refresh()
        #expect(await composer.review(content).changedKeyRecipients == [rig.bob.address])
    }

    @Test func swapsComeBeforeDisappearances() async throws {
        let rig = try await Rig()
        try await pin(rig, rig.bob.address, ed: rig.bob.ed25519Public, x: rig.bob.x25519Public)
        try await pin(rig, rig.cy.address, ed: fill(32, 3), x: fill(32, 4))
        await rig.host.setDirectory(rig.bob.address, .init(status: 404, body: ["error": .string("no")]))
        let review = await rig.composer().review(rig.message(to: [rig.bob.address, rig.cy.address]))
        #expect(
            review.changedKeyWarnings
                == [ComposePin.keyWarning(rig.cy.address), ComposePin.identityGoneWarning(rig.bob.address)])
    }

    @Test func aRecordChangeIsTheQuieterWarning() async throws {
        let rig = try await Rig()
        try await pin(rig, rig.bob.address, ed: rig.bob.ed25519Public, x: rig.bob.x25519Public)
        await rig.host.setDirectory(rig.bob.address, Rig.answer(rig.bob, ["admin_key_custody": .bool(true)]))
        let review = await rig.composer().review(rig.message(to: [rig.bob.address]))
        #expect(review.changedKeyRecipients.isEmpty)
        #expect(
            review.changedRecordWarning
                == "The key custody by their provider for bob@parity.example changed since you verified them. Their keys are unchanged, so this message is still sealed to the same person, but the change was not something they signed."
        )
    }

    @Test func forwardsAreNamedBeforeSend() async throws {
        let rig = try await Rig()
        await rig.host.setDirectory(rig.bob.address, Rig.answer(rig.bob, ["forward_to": .string(rig.cy.address)]))
        var review = await rig.composer().review(rig.message(to: [rig.bob.address]))
        #expect(
            review.forwards.map(\.notice)
                == [ComposeForwarding.notice(rig.bob.address, target: rig.cy.address, kind: .identity)])
        #expect(!review.forwardLeavesEncryption)

        await rig.host.setDirectory(rig.bob.address, Rig.answer(rig.bob, ["forward_to": .string("old@mail.example")]))
        review = await rig.composer().review(rig.message(to: [rig.bob.address]))
        #expect(
            review.forwards.map(\.notice)
                == [ComposeForwarding.unsendableNotice(rig.bob.address, target: "old@mail.example")])
        #expect(review.forwardLeavesEncryption)

        let route = FakeLegacyRoute(bridge: rig.cy.x25519Public)
        review = await rig.composer(legacyRoute: route).review(rig.message(to: [rig.bob.address]))
        #expect(
            review.forwards.map(\.notice)
                == [ComposeForwarding.notice(rig.bob.address, target: "old@mail.example", kind: .email)])

        // A directory that can't be asked claims nothing about the copy.
        await rig.host.setDirectory("old@mail.example", .init(status: 502, body: ["error": .string("down")]))
        review = await rig.composer().review(rig.message(to: [rig.bob.address]))
        #expect(
            review.forwards.map(\.notice)
                == [ComposeForwarding.notice(rig.bob.address, target: "old@mail.example", kind: .unknown)])
    }

    @Test func aReportsOfferBecomesAContact() async throws {
        let rig = try await Rig()
        await rig.host.setDirectory(rig.bob.address, Rig.answer(rig.bob, ["forward_to": .string(rig.cy.address)]))
        await rig.host.refuse(rig.bob.address, status: 410)
        try await rig.contacts.put(ContactRecord(address: rig.bob.address, name: "Bob", fingerprint: ""))
        let composer = rig.composer()
        let report = try await composer.send(rig.message(to: [rig.bob.address]))
        let offer = try #require(report.items.first?.saveContact)
        #expect(offer.buttonTitle == "Add cy@parity.example to contacts")
        #expect(offer.name == "Bob")
        try await composer.saveContact(offer)
        let saved = try #require(await rig.contacts.contact(for: rig.cy.address))
        #expect(saved.provenance == .userApproved)
        #expect(saved.ed25519Pub == rig.cy.ed25519Public.base64EncodedString())
        #expect(saved.fingerprint == "fp")
    }
}

@Suite struct ComposeAttachmentRules {
    private func file(_ size: Int, _ name: String = "a.bin", type: String = "") -> ComposeAttachments.File {
        .init(name: name, contentType: type, content: Data(count: size))
    }

    @Test func aFileIsHashedAndTyped() throws {
        let content = Data("hello".utf8)
        let list = try ComposeAttachments.adding([.init(name: "a.txt", content: content)], to: [])
        let a = try #require(list.first)
        #expect(a.contentType == "application/octet-stream")
        #expect(a.contentHash == Data(SHA256.hash(data: content)))
        #expect(a.sizeBytes == 5)
        #expect(a.attachmentID[6] & 0xf0 == 0x40)
        #expect(a.attachmentID[8] & 0xc0 == 0x80)
        #expect(a.disposition == nil)
    }

    @Test func exactlyTheCapFits() throws {
        let list = try ComposeAttachments.adding([file(ComposeAttachments.maxTotalBytes)], to: [])
        #expect(ComposeAttachments.totalBytes(list) == 26_214_400)
        #expect(throws: ComposeError.attachmentsTooLarge) { try ComposeAttachments.adding([file(1)], to: list) }
    }

    @Test func aBatchPastTheCapAddsNothing() throws {
        let one = try ComposeAttachments.adding([file(10)], to: [])
        #expect(throws: ComposeError.attachmentsTooLarge) {
            try ComposeAttachments.adding([file(10), file(ComposeAttachments.maxTotalBytes)], to: one)
        }
        #expect(ComposeError.attachmentsTooLarge.errorDescription == "Attachments can’t exceed 25 MB in total.")
    }

    @Test func anInlineImageCountsAndNamesItself() throws {
        let (list, id) = try ComposeAttachments.addingInlineImage(file(3, "", type: "image/png"), to: [])
        let a = try #require(list.first)
        #expect(a.filename == "image")
        #expect(a.disposition == "inline")
        #expect(a.contentID == id)
        #expect(id.hasSuffix("@dmcn"))
        #expect(id.count == 37)
        let full = try ComposeAttachments.adding([file(ComposeAttachments.maxTotalBytes - 3)], to: list)
        #expect(throws: ComposeError.attachmentsTooLarge) {
            try ComposeAttachments.addingInlineImage(file(1), to: full)
        }
    }

    @Test func onlyTheInlineImagesTheBodyRefersToGoOut() throws {
        let (one, keep) = try ComposeAttachments.addingInlineImage(file(1), to: [])
        let (two, _) = try ComposeAttachments.addingInlineImage(file(1), to: one)
        let all = try ComposeAttachments.adding([file(1, "doc.pdf")], to: two)
        let html = "<p><img alt=\"x\" src=\"cid:\(keep)\"><img src=\"https://x/y\"></p>"
        #expect(ComposeAttachments.forSending(all, html: html).map(\.contentID) == [keep, nil])
        #expect(ComposeAttachments.forSending(all, html: nil).map(\.filename) == ["doc.pdf"])
    }
}

@Suite struct ComposeReplyRules {
    private let enUS = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!
    private let me = "alice@parity.example"

    private func original(to: [String]? = nil, cc: [String] = [], subject: String = "Lunch", body: String? = "Hi")
        -> ReplyOriginal
    {
        ReplyOriginal(
            senderAddress: "zed@other.example", to: to ?? [me], cc: cc, subject: subject,
            messageID: String(repeating: "51", count: 16), threadID: String(repeating: "61", count: 16),
            sentAt: 1_788_430_860, bodyText: body)
    }

    @Test func aReplyOpensWithSignatureAboveTheQuote() {
        let reply = ComposeReplies.reply(to: original(), all: false, me: me, locale: enUS, timeZone: utc)
        let content = ComposeReplies.opening(reply, from: me, signature: "Ada")
        #expect(content.to == ["zed@other.example"])
        #expect(content.subject == "Re: Lunch")
        #expect(content.text == "\n\nAda\n\nOn Thu, Sep 3, 2026 at 10:21 AM, zed@other.example wrote:\n> Hi")
        #expect(content.from == me)
        #expect(!content.showCcBcc)
        #expect(!content.rich)
        // The quote is in the body; a draft keeps only what threading and From need.
        #expect(content.replyTo?.quote == nil)
        #expect(content.replyTo?.replyToId == reply.replyToId)
    }

    @Test func replyAllOpensCcBcc() {
        let source = original(to: [me, "bob@parity.example"])
        #expect(ComposeReplies.offersReplyAll(source, me: me))
        #expect(!ComposeReplies.offersReplyAll(original(), me: me))
        let content = ComposeReplies.opening(ComposeReplies.reply(to: source, all: true, me: me), from: me)
        #expect(content.cc == ["bob@parity.example"])
        #expect(content.showCcBcc)
    }

    @Test func aReplyGoesOutAsTheAddressTheyWroteTo() {
        let source = original(to: ["Alias@parity.example", "bob@parity.example"], cc: [me])
        let reply = ComposeReplies.reply(to: source, all: true, me: me)
        let content = ComposeReplies.opening(reply, from: me, ours: ["alias@parity.example"])
        #expect(content.from == "alias@parity.example")
        #expect(content.to == ["zed@other.example"])
        #expect(content.cc == ["bob@parity.example"])
    }

    @Test func aReplyToOtherMailKeepsTheAccountAddress() {
        let reply = ComposeReplies.reply(to: original(), all: false, me: me)
        #expect(ComposeReplies.opening(reply, from: me, ours: ["alias@parity.example"]).from == me)
    }

    @Test func aRichDraftCarriesOnAsPlainText() async throws {
        let store = DraftStore(storage: InMemoryPersonalStorage(), address: me)
        let id = DraftStore.newID()
        let rich = DraftContent(from: me, subject: "S", rich: true, text: "Hello", html: "<p>Hello</p>")
        try await store.save(id, content: rich, base: .new, updatedAt: 1)
        let content = ComposeReplies.resuming(try #require(try await store.load(id)))
        #expect(!content.rich)
        #expect(content.html.isEmpty)
        #expect(content.text == "Hello")
    }

    @Test func aHeaderIsAnOriginal() throws {
        var h = Dmcn_Message_MessageHeader()
        h.senderAddress = "zed@other.example"
        h.to = [me]
        h.cc = ["bob@parity.example"]
        h.subject = "Lunch"
        h.messageID = fill(16, 0x51)
        h.threadID = fill(16, 0x61)
        h.sentAt = 1_788_430_860
        #expect(ReplyOriginal(header: h, bodyText: "Hi") == original(cc: ["bob@parity.example"]))
    }

    @Test func aForwardIsANewMessage() throws {
        var file = Dmcn_Message_AttachmentRecord()
        file.filename = "notes.txt"
        file.contentType = "text/plain"
        file.content = Data("hello".utf8)
        file.sizeBytes = 999  // A size the sender claimed isn't carried forward.
        var inline = Dmcn_Message_AttachmentRecord()
        inline.filename = "dot.png"
        inline.disposition = "inline"
        var receipt = Dmcn_Message_AttachmentRecord()
        receipt.contentType = "application/x-dmcn-bridge-delivery-receipt"

        let content = ComposeReplies.forward(
            original(cc: ["bob@parity.example"], subject: "Fwd: Lunch", body: "Hi\nthere"),
            attachments: [file, inline, receipt], from: me, senderName: "Zed", signature: "Ada", locale: enUS,
            timeZone: utc)
        #expect(content.to.isEmpty)
        #expect(content.cc.isEmpty)
        #expect(content.replyTo == nil)
        #expect(content.subject == "Fwd: Lunch")
        #expect(
            content.text == """


                Ada

                ---------- Forwarded message ---------
                From: Zed <zed@other.example>
                Date: Thu, Sep 3, 2026 at 10:21 AM
                Subject: Fwd: Lunch
                To: alice@parity.example
                Cc: bob@parity.example

                Hi
                there
                """)
        #expect(content.attachments.map(\.filename) == ["notes.txt"])
        let a = try #require(content.attachments.first)
        #expect(a.sizeBytes == 5)
        #expect(a.contentHash == Data(SHA256.hash(data: file.content)))
    }

    @Test(arguments: [
        ("", ""), ("Lunch", "Fwd: Lunch"), ("Fwd: Lunch", "Fwd: Lunch"), ("fwd:Lunch", "Fwd: Lunch"),
        ("FWD:   Lunch", "Fwd: Lunch"), ("Re: Lunch", "Fwd: Re: Lunch"), ("Fwd: Fwd: Lunch", "Fwd: Fwd: Lunch"),
    ])
    func forwardSubjects(subject: String, expected: String) {
        #expect(ComposeReplies.forwardSubject(subject) == expected)
    }
}

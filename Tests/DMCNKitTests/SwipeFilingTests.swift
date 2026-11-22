// Swipe to file: which folders the swipe offers, what filing one message takes along, and what the
// rules file on their own.

import Foundation
import Testing
@testable import DMCNKit

private let me = "me@example.com"
private let ada = "ada@example.com"

private func message(
    _ hash: String, from sender: String = ada, verified: Bool = true, sentAt: Int64 = 100
) -> MailPreview {
    MailPreview(
        hash: hash, senderAddress: sender, recipientAddress: me, to: [me], subject: "Hello", sentAt: sentAt,
        sender: verified ? .verified(sender) : .unverified(sender))
}

private func context(_ flags: [String: FlagRecord] = [:], folders: Set<String> = ["f1", "f2"]) -> PlaceContext {
    PlaceContext(address: me, flags: flags, filter: FilterList(), knownFolderIDs: folders)
}

private func folders(_ ids: String...) -> [FolderDef] {
    ids.map { FolderDef(id: $0, name: $0.uppercased()) }
}

@Suite struct FilingSettings {
    @Test func askingIsOnAndFullSwipeDeletesUntilChanged() {
        let filing = SwipeFiling()
        #expect(filing.asksAboutSender)
        #expect(!filing.fullSwipeArchives)
    }

    @Test func itRoundTripsThroughTheSettingsAndLeavesOtherFieldsAlone() {
        var settings = AppSettings(fields: ["signature": .string("Cheers")])
        var filing = settings.swipeFiling
        filing.asksAboutSender = false
        filing.fullSwipeArchives = true
        filing.setRule(sender: "Ada@Example.com ", folderID: "f1", now: Date(timeIntervalSince1970: 50))
        settings.swipeFiling = filing
        #expect(settings.signature == "Cheers")
        #expect(!settings.swipeFiling.asksAboutSender)
        #expect(settings.swipeFiling.fullSwipeArchives)
        #expect(settings.swipeFiling.rule(for: ada)?.folderID == "f1")
        #expect(settings.swipeFiling.rule(for: ada)?.since == 50)
    }

    @Test func rulesSortUnderTheirFoldersAndAGoneFolderComesLast() {
        var filing = SwipeFiling()
        filing.setRule(sender: "zed@example.com", folderID: "f1", now: Date())
        filing.setRule(sender: "bob@example.com", folderID: "f2", now: Date())
        filing.setRule(sender: "amy@example.com", folderID: "f1", now: Date())
        filing.setRule(sender: "old@example.com", folderID: "gone", now: Date())
        let groups = filing.rulesByFolder(folders("f1", "f2", "f3"))
        #expect(groups.map { $0.folder?.id } == ["f1", "f2", nil])
        #expect(groups[0].rules.map(\.sender) == ["amy@example.com", "zed@example.com"])
        #expect(groups[2].rules.map(\.sender) == ["old@example.com"])
    }
}

@Suite struct FilingPlacement {
    @Test func backToTheInboxFromAFolderClearsAnArchivedMark() {
        let m = message("m")
        let ctx = context(["m": FlagRecord(archived: true, folderId: "f1")])
        #expect(MailView.placeOf(m, ctx) == .folder("f1"))
        let delta = MailView.filingDelta(to: nil)
        let after = FlagRecord(
            archived: delta.archived.applied(to: true), folderId: delta.folderId.applied(to: "f1"))
        #expect(MailView.placeOf(m, context(["m": after])) == .inbox)
    }

    @Test func intoAFolderLeavesTheArchivedMarkAlone() {
        #expect(MailView.filingDelta(to: "f1") == FlagDelta(folderId: .set("f1")))
    }

    @Test func theInboxCountLeavesOutFiledMail() {
        let mail = [message("inbox"), message("filed"), message("goneFolder")]
        let flags = ["filed": FlagRecord(folderId: "f1"), "goneFolder": FlagRecord(folderId: "gone")]
        let all = MailView.countUnread(mail, address: me, flags: flags, filter: nil)
        let inbox = MailView.countUnread(mail, address: me, flags: flags, filter: nil, filedIn: ["f1"])
        #expect(all == 3)
        #expect(inbox == 2)
    }
}

@Suite struct SenderRules {
    @Test func oneRulePerSenderAndTheNewChoiceWins() {
        var swipe = SwipeFiling()
        swipe.setRule(sender: ada, folderID: "f1", now: Date(timeIntervalSince1970: 1))
        swipe.setRule(sender: "ADA@example.com", folderID: "f2", now: Date(timeIntervalSince1970: 2))
        #expect(swipe.rules.count == 1)
        #expect(swipe.rule(for: ada)?.folderID == "f2")
        swipe.removeRule(sender: ada)
        #expect(swipe.rules.isEmpty)
    }
}

@Suite struct MoveSameSender {
    @Test func fromTheInboxOnlyTheInboxComesAlong() {
        let swiped = message("m")
        let mail = [
            swiped, message("inbox"), message("archived"), message("trashed"), message("filed"),
            message("bob", from: "bob@example.com"),
        ]
        let ctx = context([
            "archived": FlagRecord(archived: true), "trashed": FlagRecord(trashedAt: 1),
            "filed": FlagRecord(folderId: "f2"),
        ])
        #expect(MailView.sameSenderMail(as: swiped, into: "f1", among: mail, ctx) == ["inbox"])
    }

    @Test func fromAFolderThatFolderAndTheInboxComeAlong() {
        let swiped = message("m")
        let mail = [swiped, message("inbox"), message("sameFolder"), message("otherFolder"), message("archived")]
        let ctx = context([
            "m": FlagRecord(folderId: "f1"), "sameFolder": FlagRecord(folderId: "f1"),
            "otherFolder": FlagRecord(folderId: "f2"), "archived": FlagRecord(archived: true),
        ])
        #expect(MailView.sameSenderMail(as: swiped, into: "f2", among: mail, ctx) == ["inbox", "sameFolder"])
    }

    @Test func ordinaryEmailIsFiledByItsAddress() {
        let swiped = message("m", verified: false)
        let bob = message("bob", from: "bob@example.com", verified: false)
        let mail = [swiped, message("inbox", verified: false), bob]
        #expect(MailView.sameSenderMail(as: swiped, into: "f1", among: mail, context()) == ["inbox"])
    }

    @Test func forgedAndDisownedCopiesClaimingTheSenderAreLeftBehind() {
        let swiped = message("m")
        let forged = MailPreview(
            hash: "forged", senderAddress: ada, recipientAddress: me, to: [me], sender: .mismatch(claimed: ada))
        let disowned = MailPreview(
            hash: "disowned", senderAddress: ada, recipientAddress: me, to: [me], sender: .disowned(claimed: ada))
        let mail = [swiped, forged, disowned]
        #expect(MailView.sameSenderMail(as: swiped, into: "f1", among: mail, context()).isEmpty)
        #expect(MailView.filingSender(forged) == nil)
        #expect(MailView.filingSender(disowned) == nil)
    }

    @Test func backToTheInboxTakesOnlyThatFoldersMail() {
        let swiped = message("m")
        let mail = [swiped, message("inbox"), message("sameFolder"), message("otherFolder")]
        let ctx = context([
            "m": FlagRecord(folderId: "f1"), "sameFolder": FlagRecord(folderId: "f1"),
            "otherFolder": FlagRecord(folderId: "f2"),
        ])
        #expect(MailView.sameSenderMail(as: swiped, into: nil, among: mail, ctx) == ["sameFolder"])
    }

    @Test func fromArchiveNothingComesAlong() {
        let swiped = message("m")
        let ctx = context(["m": FlagRecord(archived: true)])
        #expect(MailView.sameSenderMail(as: swiped, into: "f1", among: [swiped, message("inbox")], ctx).isEmpty)
    }
}

@Suite struct RulesFileNewMail {
    private let rules = [FilingRule(sender: ada, folderID: "f1", since: 100)]

    @Test func untouchedNewInboxMailFromTheSenderIsFiled() {
        let filed = MailView.autoFiling([message("new", sentAt: 150)], rules: rules, context())
        #expect(filed == [AutoFiling(hash: "new", folderID: "f1")])
    }

    @Test func mailFromBeforeTheRuleIsLeftAlone() {
        #expect(MailView.autoFiling([message("old", sentAt: 99)], rules: rules, context()).isEmpty)
    }

    @Test func mailTheOwnerHasTouchedIsLeftAlone() {
        let ctx = context(["read": FlagRecord(read: true), "movedBack": FlagRecord(updatedAt: 5)])
        let mail = [message("read", sentAt: 150), message("movedBack", sentAt: 150)]
        #expect(MailView.autoFiling(mail, rules: rules, ctx).isEmpty)
    }

    @Test func otherSendersAndGoneFoldersAreLeftAlone() {
        let bob = message("bob", from: "bob@example.com", sentAt: 150)
        #expect(MailView.autoFiling([bob], rules: rules, context()).isEmpty)
        #expect(MailView.autoFiling([message("new", sentAt: 150)], rules: rules, context(folders: ["f2"])).isEmpty)
    }

    @Test func ordinaryEmailFromTheSenderIsFiledButAForgedCopyIsNot() {
        let forged = MailPreview(
            hash: "forged", senderAddress: ada, recipientAddress: me, to: [me], sentAt: 150,
            sender: .mismatch(claimed: ada))
        let mail = [message("ordinary", verified: false, sentAt: 150), forged]
        #expect(MailView.autoFiling(mail, rules: rules, context()) == [AutoFiling(hash: "ordinary", folderID: "f1")])
    }

    @Test func noRulesFileNothing() {
        #expect(MailView.autoFiling([message("new", sentAt: 150)], rules: [], context()).isEmpty)
    }
}

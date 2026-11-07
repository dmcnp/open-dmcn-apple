import Foundation
import Testing
@testable import DMCNKit

// Every record here was signed by Go's internal/bridge, then verified by Go and by the browser's
// real verifyClassificationLocal and verifyReceiptLocal: the vectors are the three sides agreeing.

private struct Vectors: Decodable {
    struct Vector: Decodable {
        let name: String
        let kind: String
        let record: String
        let message_sender: String
        let go_verified: Bool
        let browser: Browser
    }
    /// Either shape of verdict.
    struct Browser: Decodable {
        let verified: Bool
        let reason: String?
        let trustTier: Int?
        let smtpFrom: String?
        let spf: String?
        let dkim: String?
        let dmarc: String?
        let delivered: Bool?
        let recipientEmail: String?
        let errorDetail: String?
    }
    let domain_root_pub: String
    let other_root_pub: String
    let now: Int64
    let vectors: [Vector]
}

private let vectors: Result<Vectors, any Error> = Result { try fixture("bridge-attestations") }

private func verifier(_ v: Vectors, root: String? = nil) -> RootKeyBridgeVerifier {
    let now = v.now
    return RootKeyBridgeVerifier(domainRootKey: root ?? v.domain_root_pub, now: { now })
}

private func vector(_ name: String) throws -> Vectors.Vector {
    try #require(try vectors.get().vectors.first { $0.name == name })
}

private func record(_ contentType: String, _ content: Data, filename: String = "x.bin") -> Dmcn_Message_AttachmentRecord
{
    var r = Dmcn_Message_AttachmentRecord()
    r.contentType = contentType
    r.content = content
    r.filename = filename
    return r
}

@Suite struct BridgeAttestationVectors {
    @Test func classificationsAndReceiptsAgreeWithTheBrowserAndGo() throws {
        let v = try vectors.get()
        #expect(v.vectors.count == 21)
        for c in v.vectors {
            let data = try #require(Data(base64Encoded: c.record))
            let sender = try #require(Data(base64Encoded: c.message_sender))
            if c.kind == "classification" {
                let got = verifier(v).verifyClassification(data, messageSender: sender)
                #expect(got.verified == c.browser.verified, "\(c.name)")
                #expect(got.reason == c.browser.reason, "\(c.name)")
                #expect(got.smtpFrom == (c.browser.smtpFrom ?? ""), "\(c.name)")
                #expect(got.trustTier.rawValue == (c.browser.trustTier ?? 0), "\(c.name)")
                #expect(got.spf == c.browser.spf, "\(c.name)")
                #expect(got.dkim == c.browser.dkim, "\(c.name)")
                #expect(got.dmarc == c.browser.dmarc, "\(c.name)")
            } else {
                let got = verifier(v).verifyReceipt(data, messageSender: sender)
                #expect(got.verified == c.browser.verified, "\(c.name)")
                #expect(got.reason == c.browser.reason, "\(c.name)")
                #expect(got.delivered == (c.browser.delivered ?? false), "\(c.name)")
                #expect(got.recipientEmail == (c.browser.recipientEmail ?? ""), "\(c.name)")
                #expect(got.errorDetail == c.browser.errorDetail, "\(c.name)")
            }
            // Go doesn't bind to the message: that's the client's job, and the one place they differ.
            let bound = c.name != "signer_is_not_message_author" && c.name != "receipt_not_from_message_author"
            if bound { #expect(c.browser.verified == c.go_verified, "\(c.name)") }
        }
    }

    @Test func aSignatureCoversFieldsOneToTenAndNothingElse() throws {
        // The fixture's signed field after the signature: Go parsed past it, and so must this.
        let v = try vectors.get()
        let c = try vector("unknown_field_after_signature")
        let got = verifier(v).verifyClassification(
            try #require(Data(base64Encoded: c.record)), messageSender: Data(base64Encoded: c.message_sender))
        #expect(got.verified)
    }

    @Test func theAnchorIsWhatDecides() throws {
        let v = try vectors.get()
        let c = try vector("genuine")
        let data = try #require(Data(base64Encoded: c.record))
        let sender = Data(base64Encoded: c.message_sender)
        #expect(
            verifier(v, root: v.other_root_pub).verifyClassification(data, messageSender: sender).reason
                == "bridge credential was not issued by this domain")
        for missing in [nil, ""] as [String?] {
            let got = RootKeyBridgeVerifier(domainRootKey: missing).verifyClassification(data, messageSender: sender)
            #expect(!got.verified)
            #expect(got.reason == "no domain root key configured to verify the bridge against")
        }
        #expect(
            RootKeyBridgeVerifier(domainRootKey: "###").verifyClassification(data, messageSender: sender).reason
                == "malformed domain root key")
    }

    @Test func aClassificationWithNoMessageKeyIsntBoundButAReceiptRefuses() throws {
        let v = try vectors.get()
        let c = try vector("genuine")
        #expect(
            verifier(v).verifyClassification(try #require(Data(base64Encoded: c.record)), messageSender: nil).verified)
        let r = try vector("receipt_failed")
        let got = verifier(v).verifyReceipt(try #require(Data(base64Encoded: r.record)), messageSender: nil)
        #expect(!got.verified)
        #expect(got.reason == "no sender key to bind the receipt to")
    }

    @Test func theCredentialWindowIsReadAtTheTimeGiven() throws {
        let v = try vectors.get()
        let c = try vector("credential_expired")
        let data = try #require(Data(base64Encoded: c.record))
        let sender = Data(base64Encoded: c.message_sender)
        let early = RootKeyBridgeVerifier(domainRootKey: v.domain_root_pub, now: { 1_764_000_000 })
        #expect(early.verifyClassification(data, messageSender: sender).verified)
    }
}

@Suite struct BridgeAttachmentRules {
    struct Failing: BridgeVerifier {
        func verifyClassification(_ record: Data, messageSender: Data?) async throws -> BridgeAttestation {
            throw FixtureError.missing("verifier")
        }
        func verifyReceipt(_ record: Data, messageSender: Data?) async throws -> DeliveryReceiptView {
            throw FixtureError.missing("verifier")
        }
    }

    @Test func noRecordMeansNotBridged() async throws {
        let v = try vectors.get()
        let plain = [record("application/pdf", Data())]
        #expect(await verifier(v).attestation(of: plain, messageSender: nil) == nil)
        #expect(await verifier(v).receipt(of: plain, messageSender: nil) == nil)
    }

    @Test func aCheckThatCouldntRunIsNotOneThatPassed() async {
        let a = await Failing().attestation(
            of: [record(BridgeRecord.classificationContentType, Data())], messageSender: nil)
        #expect(
            a
                == BridgeAttestation(
                    verified: false, trustTier: .unspecified, smtpFrom: "", reason: "verification unavailable"))
        let r = await Failing().receipt(of: [record(BridgeRecord.receiptContentType, Data())], messageSender: nil)
        #expect(
            r
                == DeliveryReceiptView(
                    verified: false, delivered: false, recipientEmail: "", reason: "verification unavailable"))
    }

    @Test func aGenuineReceiptStapledToBridgedMailIsntRead() async throws {
        // A real failure receipt, in the mail of someone who got one for a message of their own. The
        // header is signed by the same bridge, so it would verify, and a verified receipt opens the
        // gate. Go's parseInboundMIME keeps the attachment's content type, so it does arrive like this.
        let v = try vectors.get()
        let genuine = try vector("receipt_failed")
        let content = try #require(Data(base64Encoded: genuine.record))
        let sender = Data(base64Encoded: genuine.message_sender)
        let alone = await verifier(v).receipt(
            of: [record(BridgeRecord.receiptContentType, content)], messageSender: sender)
        #expect(alone?.verified == true)

        let classification = try #require(Data(base64Encoded: try vector("genuine").record))
        let stapled = [
            record(BridgeRecord.classificationContentType, classification, filename: "classification.bin"),
            record("message/rfc822", Data(), filename: "original.eml"),
            record(BridgeRecord.receiptContentType, content),
        ]
        #expect(await verifier(v).receipt(of: stapled, messageSender: sender) == nil)
        #expect(await verifier(v).attestation(of: stapled, messageSender: sender)?.verified == true)
    }

    @Test func theFirstClassificationIsTheBridges() async throws {
        // The bridge writes its own first. One the sender attached comes later and isn't read.
        let v = try vectors.get()
        let good = try vector("all_pass_verified_tier")
        let forged = try vector("signature_by_another_key")
        let list = [
            record(BridgeRecord.classificationContentType, try #require(Data(base64Encoded: good.record))),
            record(BridgeRecord.classificationContentType, try #require(Data(base64Encoded: forged.record))),
        ]
        #expect(
            await verifier(v).attestation(of: list, messageSender: Data(base64Encoded: good.message_sender))?.verified
                == true)
    }
}

@Suite struct DomainRootKeyFromTheHost {
    /// A line from a running dmcnd. html/template writes `+` as `\\u002b` in a JavaScript string, so a
    /// key holding one read back wrong, and every bridged message failed as unverifiable.
    @Test func aKeyIsReadTheWayTheBrowserReadsIt() throws {
        let page = #"        DOMAIN_ROOT_PUB: 'ewKhDsRAovYT0iwlk6I\u002bu95qtuzCYbzZXvPL4V4cw7I=',"#
        let key = try #require(WebHostClient.domainRootKey(inPage: page))
        #expect(key == "ewKhDsRAovYT0iwlk6I+u95qtuzCYbzZXvPL4V4cw7I=")
        #expect(JSText.atob(key)?.count == 32)
    }

    @Test func everyEscapeTheTemplateWritesIsRead() {
        #expect(WebHostClient.domainRootKey(inPage: #"DOMAIN_ROOT_PUB: 'a\/b\x2bc\u003d'"#) == "a/b+c=")
        #expect(WebHostClient.domainRootKey(inPage: #"DOMAIN_ROOT_PUB: 'a\'b'"#) == "a'b")
    }

    @Test func aKeyHalfUnderstoodIsNoKey() {
        #expect(WebHostClient.domainRootKey(inPage: #"DOMAIN_ROOT_PUB: 'a\u00"#) == nil)
        #expect(WebHostClient.domainRootKey(inPage: #"DOMAIN_ROOT_PUB: 'a\q'"#) == nil)
        #expect(WebHostClient.domainRootKey(inPage: "DOMAIN_ROOT_PUB: 'never closed") == nil)
    }

    @Test func readsWhatTheBrowserIsHanded() {
        let page = "<script>const env = {\n VERSION: 'x',\n DOMAIN_ROOT_PUB: 'AQID',\n NONCE: 'n' };</script>"
        #expect(WebHostClient.domainRootKey(inPage: page) == "AQID")
        #expect(WebHostClient.domainRootKey(inPage: "env={DOMAIN_ROOT_PUB:\"AQID\"}") == "AQID")
    }

    @Test func aHostWithoutOneHasNone() {
        #expect(WebHostClient.domainRootKey(inPage: "<html></html>") == nil)
        #expect(WebHostClient.domainRootKey(inPage: "DOMAIN_ROOT_PUB: ''") == nil)
        #expect(WebHostClient.domainRootKey(inPage: "DOMAIN_ROOT_PUB: '{{ .DomainRootPub }}'") == nil)
    }
}

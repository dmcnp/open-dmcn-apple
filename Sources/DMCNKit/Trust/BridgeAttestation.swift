import Foundation
import SwiftProtobuf

// A bridge's signed account of the mail it carries (SPEC_EXT_BRIDGE §1). Inbound, it runs
// SPF/DKIM/DMARC and signs its verdict into a classification record. Outbound, it returns a delivery
// receipt. A bridge has no address and no directory entry, so everything needed to believe one is in
// the record plus a trust anchor.
//
// WHICH anchor is the deployment's: `BridgeVerifier` is the seam, as verifyClassification and
// verifyReceipt are in the browser's lib/deployment.ts. `RootKeyBridgeVerifier` is the reference
// build's check, which needs the domain's root key. Parity with lib/crypto/bridgeAttest.ts,
// receiptAttest.ts, and the reference build's app/lib/crypto/localBridgeVerify.ts and bridgeProtobuf.ts.

public enum BridgeRecord {
    public static let classificationContentType = "application/x-dmcn-bridge-classification"
    public static let receiptContentType = "application/x-dmcn-bridge-delivery-receipt"

    /// Where the bridge's own copy of a legacy email's raw source sits, or nil. It's sealed straight
    /// after the classification record and found by that position, never by type alone: an email
    /// forwarded as an attachment is message/rfc822 too, and that one is the reader's to see.
    public static func originalIndex(contentTypes: [String], filenames: [String]) -> Int? {
        guard contentTypes.count >= 2, filenames.count >= 2, contentTypes[0] == classificationContentType,
            contentTypes[1] == "message/rfc822", filenames[1] == "original.eml"
        else { return nil }
        return 1
    }
}

public struct BridgeAttestation: Sendable, Equatable {
    /// The signature is valid, and the signer is a trusted bridge that authored this message.
    public var verified: Bool
    /// The tier the bridge asserts. Means something only when `verified`.
    public var trustTier: Dmcn_Bridge_BridgeTrustTier
    /// The original legacy sender, for display.
    public var smtpFrom: String
    /// The verdicts behind the tier, so a reader can say which check did not pass. A message that
    /// authenticates through aligned SPF still falls short of the tier, and that's worth telling
    /// apart from a spoof.
    public var spf: String?
    public var dkim: String?
    public var dmarc: String?
    /// Why verification failed.
    public var reason: String?

    public init(
        verified: Bool, trustTier: Dmcn_Bridge_BridgeTrustTier, smtpFrom: String, spf: String? = nil,
        dkim: String? = nil,
        dmarc: String? = nil, reason: String? = nil
    ) {
        self.verified = verified
        self.trustTier = trustTier
        self.smtpFrom = smtpFrom
        self.spf = spf
        self.dkim = dkim
        self.dmarc = dmarc
        self.reason = reason
    }
}

public struct DeliveryReceiptView: Sendable, Equatable {
    /// Signed by a trusted bridge.
    public var verified: Bool
    /// Delivered or failed, as the bridge says. Means something only when `verified`.
    public var delivered: Bool
    /// The legacy address delivered to, or tried.
    public var recipientEmail: String
    public var errorDetail: String?
    /// Why verification failed.
    public var reason: String?

    public init(
        verified: Bool, delivered: Bool, recipientEmail: String, errorDetail: String? = nil, reason: String? = nil
    ) {
        self.verified = verified
        self.delivered = delivered
        self.recipientEmail = recipientEmail
        self.errorDetail = errorDetail
        self.reason = reason
    }
}

/// Who decides whether a bridge's records can be believed. `messageSender` is the wrapped message's
/// already-verified signing key: a bridged message is authored by the bridge, so a record has to be
/// bound to it or a genuine verdict could be lifted off one message and stapled onto another.
public protocol BridgeVerifier: Sendable {
    func verifyClassification(_ record: Data, messageSender: Data?) async throws -> BridgeAttestation
    func verifyReceipt(_ record: Data, messageSender: Data?) async throws -> DeliveryReceiptView
}

extension BridgeVerifier {
    /// The verdict on a message's classification record. nil when the message isn't bridged mail.
    /// Never throws: a check that couldn't run isn't a check that passed.
    public func attestation(of attachments: [Dmcn_Message_AttachmentRecord], messageSender: Data?) async
        -> BridgeAttestation?
    {
        guard let record = attachments.first(where: { $0.contentType == BridgeRecord.classificationContentType }) else {
            return nil
        }
        do {
            return try await verifyClassification(record.content, messageSender: messageSender.flatMap(nonEmpty))
        } catch {
            return BridgeAttestation(
                verified: false, trustTier: .unspecified, smtpFrom: "", reason: "verification unavailable")
        }
    }

    /// The verdict on a message's delivery receipt. nil when it doesn't carry one.
    ///
    /// Bridged mail never counts, whatever it carries. Every attachment after the first two of a
    /// bridged message came from the legacy sender, and the header is signed by the bridge either
    /// way, so a genuine receipt an outsider obtained for mail of their own would verify here if it
    /// were read, and a verified receipt opens everything.
    public func receipt(of attachments: [Dmcn_Message_AttachmentRecord], messageSender: Data?) async
        -> DeliveryReceiptView?
    {
        guard !attachments.contains(where: { $0.contentType == BridgeRecord.classificationContentType }),
            let record = attachments.first(where: { $0.contentType == BridgeRecord.receiptContentType })
        else { return nil }
        do {
            return try await verifyReceipt(record.content, messageSender: messageSender.flatMap(nonEmpty))
        } catch {
            return DeliveryReceiptView(
                verified: false, delivered: false, recipientEmail: "", reason: "verification unavailable")
        }
    }
}

private func nonEmpty(_ key: Data) -> Data? { key.isEmpty ? nil : key }

/// The reference build's check: a bridge is whoever holds a credential from this domain's root.
public struct RootKeyBridgeVerifier: BridgeVerifier {
    /// Standard base64, as the browser is given it. Empty or nil: nothing can verify.
    private let domainRootKey: String?
    private let now: @Sendable () -> Int64

    /// `domainRootKey` is public by construction, being what the domain's `_dmcn` fingerprint commits
    /// to. See `WebHostClient.domainRootKey()` for where it comes from. `now` is Unix seconds.
    public init(
        domainRootKey: String?, now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    ) {
        self.domainRootKey = domainRootKey
        self.now = now
    }

    public func verifyClassification(_ record: Data, messageSender: Data?) -> BridgeAttestation {
        guard let parsed = try? Dmcn_Bridge_BridgeClassificationRecord(serializedBytes: record) else {
            return BridgeAttestation(
                verified: false, trustTier: .unspecified, smtpFrom: "", reason: "malformed classification record")
        }
        var attestation = BridgeAttestation(
            verified: false, trustTier: parsed.trustTier, smtpFrom: parsed.smtpFrom, spf: spf(parsed.spfResult),
            dkim: dkim(parsed.dkimResult), dmarc: dmarc(parsed.dmarcResult))

        // 1. The record must be signed by the key it carries.
        guard let signable = try? parsed.signableBytes(),
            verifyEd25519(publicKey: parsed.bridgePublicKey, message: signable, signature: parsed.bridgeSignature)
        else {
            attestation.reason = "invalid bridge signature"
            return attestation
        }
        // 2. That signer must be the author of the message carrying it.
        if let messageSender, !constantTimeEqual(parsed.bridgePublicKey, messageSender) {
            attestation.reason = "classification signer is not the message author"
            return attestation
        }
        // 3. And it must hold a bridge credential from this domain's root.
        let credential = parsed.hasBridgeCredential ? parsed.bridgeCredential : nil
        if let problem = problem(with: credential, signer: parsed.bridgePublicKey) {
            attestation.reason = problem
            return attestation
        }
        attestation.verified = true
        return attestation
    }

    public func verifyReceipt(_ record: Data, messageSender: Data?) -> DeliveryReceiptView {
        guard let parsed = try? Dmcn_Bridge_BridgeDeliveryReceipt(serializedBytes: record) else {
            return DeliveryReceiptView(
                verified: false, delivered: false, recipientEmail: "", reason: "malformed delivery receipt")
        }
        var view = DeliveryReceiptView(
            verified: false, delivered: parsed.success, recipientEmail: parsed.recipientEmail,
            errorDetail: parsed.errorDetail.isEmpty ? nil : parsed.errorDetail)
        // A receipt carries no key of its own: the message that delivered it was signed by the
        // bridge, and that already-verified key is what it must be signed by.
        guard let messageSender else {
            view.reason = "no sender key to bind the receipt to"
            return view
        }
        guard let signable = try? parsed.signableBytes(),
            verifyEd25519(publicKey: messageSender, message: signable, signature: parsed.bridgeSignature)
        else {
            view.reason = "invalid bridge signature"
            return view
        }
        let credential = parsed.hasBridgeCredential ? parsed.bridgeCredential : nil
        if let problem = problem(with: credential, signer: messageSender) {
            view.reason = problem
            return view
        }
        view.verified = true
        return view
    }

    /// Why a credential doesn't make `signer` a bridge for this domain, or nil when it does. A
    /// credential is public, as it travels in every message a bridge signs, so without the subject
    /// check anyone could staple a real one to their own record.
    private func problem(with credential: Dmcn_Identity_Credential?, signer: Data) -> String? {
        guard let domainRootKey, !domainRootKey.isEmpty else {
            return "no domain root key configured to verify the bridge against"
        }
        guard let credential else { return "no bridge credential" }
        guard let root = JSText.atob(domainRootKey) else { return "malformed domain root key" }
        guard constantTimeEqual(credential.issuerPub, root) else {
            return "bridge credential was not issued by this domain"
        }
        guard let signable = try? credential.signableBytes(),
            verifyEd25519(
                publicKey: root, message: SignatureContext.credential.signable(signable),
                signature: credential.signature)
        else {
            return "bridge credential signature invalid"
        }
        guard credential.roles.contains("bridge") else { return "credential does not carry the bridge role" }
        guard constantTimeEqual(credential.subject, signer) else { return "bridge credential is for a different key" }
        let now = now()
        if credential.notAfter != 0, now > credential.notAfter { return "bridge credential has expired" }
        if credential.effectiveFrom != 0, now < credential.effectiveFrom { return "bridge credential is not yet valid" }
        return nil
    }

    // Go's String() for each result, which follow RFC 7208, so a reader can compare what's shown with
    // a Received-SPF header. An absent field is 0, which is "none" in all three.

    private func spf(_ result: Dmcn_Bridge_SPFResult) -> String {
        switch result {
        case .pass: "pass"
        case .fail: "fail"
        case .softfail: "softfail"
        case .neutral: "neutral"
        default: "none"
        }
    }

    private func dkim(_ result: Dmcn_Bridge_DKIMResult) -> String {
        switch result {
        case .pass: "pass"
        case .fail: "fail"
        default: "none"
        }
    }

    private func dmarc(_ result: Dmcn_Bridge_DMARCResult) -> String {
        switch result {
        case .pass: "pass"
        case .fail: "fail"
        default: "none"
        }
    }
}

extension Dmcn_Bridge_BridgeClassificationRecord {
    /// What `bridge_signature` covers: fields 1 to 10. An allowlist, as Go's signableBytes builds a
    /// fresh message. Neither the signature nor the credential is in it, so a credential can be
    /// re-issued without invalidating every attestation it ever made, and nothing unknown can ride in.
    func signableBytes() throws -> Data {
        var pb = Self()
        pb.bridgeAddress = bridgeAddress
        pb.bridgePublicKey = bridgePublicKey
        pb.smtpFrom = smtpFrom
        pb.smtpSenderIp = smtpSenderIp
        pb.spfResult = spfResult
        pb.dkimResult = dkimResult
        pb.dmarcResult = dmarcResult
        pb.reputationScore = reputationScore
        pb.trustTier = trustTier
        pb.classifiedAt = classifiedAt
        return try Canonical.marshal(pb)
    }
}

extension Dmcn_Bridge_BridgeDeliveryReceipt {
    /// What `bridge_signature` covers: fields 1 to 6.
    func signableBytes() throws -> Data {
        var pb = Self()
        pb.originalMessageID = originalMessageID
        pb.recipientEmail = recipientEmail
        pb.bridgeAddress = bridgeAddress
        pb.deliveredAt = deliveredAt
        pb.success = success
        pb.errorDetail = errorDetail
        return try Canonical.marshal(pb)
    }
}

extension Dmcn_Identity_Credential {
    /// What the issuer signed: fields 1 to 11, 13 and 14, as Go rebuilds a credential from the fields
    /// it knows. Built fresh for the same reason as the records above.
    func signableBytes() throws -> Data {
        var pb = Self()
        pb.version = version
        pb.subject = subject
        pb.domain = domain
        pb.address = address
        pb.roles = roles
        pb.grants = grants
        pb.attributes = attributes
        pb.issuedAt = issuedAt
        pb.notAfter = notAfter
        pb.scope = scope
        pb.issuerPub = issuerPub
        pb.relayHints = relayHints
        pb.effectiveFrom = effectiveFrom
        return try Canonical.marshal(pb)
    }
}

extension WebHostClient {
    /// The domain's root Ed25519 key, base64, as the host renders it for its own browser client, or
    /// nil when it publishes none. A host verifying bridges for its clients some other way won't.
    ///
    /// This is the same place the browser gets it from, and it asks the host to tell the truth, as
    /// `lookup` already does: the directory answers reaching this client are the host's. A build with
    /// a better source, a key shipped with the app or one checked against the `_dmcn` fingerprint,
    /// hands that to `RootKeyBridgeVerifier` instead.
    public func domainRootKey() async throws -> String? {
        let page = try await callRaw("GET", "/", body: nil, bearer: nil)
        return Self.domainRootKey(inPage: String(decoding: page, as: UTF8.self))
    }

    /// Reads `DOMAIN_ROOT_PUB: '…'` out of the rendered page. An unrendered `{{ }}` placeholder counts
    /// as none, as it does in the browser's envVal.
    ///
    /// The value is a JavaScript string, not plain text: Go's html/template writes a base64 `+` as
    /// `\u002b` and `/` as `\/`. A browser reads those back without being asked, so this has to too,
    /// or a key that happens to hold either character can't verify any bridge at all.
    static func domainRootKey(inPage page: String) -> String? {
        guard let name = page.range(of: "DOMAIN_ROOT_PUB") else { return nil }
        let rest = page[name.upperBound...].drop { $0 == ":" || $0 == " " }
        guard let quote = rest.first, quote == "'" || quote == "\"" else { return nil }
        guard let value = javaScriptString(rest.dropFirst(), closedBy: quote) else { return nil }
        return value.isEmpty || value.first == "{" ? nil : value
    }

    /// The string a JavaScript literal means, read up to its closing quote. nil if it never closes or
    /// holds an escape this can't read: a key half understood is no key.
    private static func javaScriptString(_ source: Substring, closedBy quote: Character) -> String? {
        var out = ""
        var rest = source
        while let next = rest.popFirst() {
            if next == quote { return out }
            guard next == "\\" else {
                out.append(next)
                continue
            }
            guard let escape = rest.popFirst() else { return nil }
            switch escape {
            case "u", "x":
                let digits = rest.prefix(escape == "u" ? 4 : 2)
                guard digits.count == (escape == "u" ? 4 : 2), let code = UInt32(digits, radix: 16),
                    let scalar = Unicode.Scalar(code)
                else { return nil }
                out.unicodeScalars.append(scalar)
                rest = rest.dropFirst(digits.count)
            case "\\", "/", "'", "\"":
                out.append(escape)
            default:
                return nil
            }
        }
        return nil
    }
}

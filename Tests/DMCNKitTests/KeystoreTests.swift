// The keystore against the browser: every constant and fixture came out of the browser's own
// functions (src/lib/crypto/keys.ts, keystore.ts, exportFile.ts) running under node. The fixtures
// are real exports, randomness and all; `pinned` runs encryptKeys with its two random draws fixed
// so its output can be held to the byte.

import Crypto
import Foundation
import Testing
@testable import DMCNKit

/// Keys of 32x0x21 (Ed25519 seed) and 32x0x42 (X25519), as keyPairToPayloadJSON wrote them.
private let fixedPayload = Data(
    """
    {"ed25519_public":"iEuIV/TqoWE8YVBNs01L6vNGUXoOMd483dTZtCAdnQs=","ed25519_private":"ISEhISEhISEh\
    ISEhISEhISEhISEhISEhISEhISEhISGIS4hX9OqhYTxhUE2zTUvq80ZReg4x3jzd1Nm0IB2dCw==","x25519_public":"E\
    yxEK+AQ+9V+cmAzKKp25x/MwVA6riGTJ9FNnJmT9HI=","x25519_private":"QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQ\
    kJCQkJCQkI=","device_id":"oKGio6SlRqeoqaqrrK2urw==","created_at":1700000000}
    """.utf8)
private let fixedEd25519Public = "884b8857f4eaa1613c61504db34d4beaf346517a0e31de3cddd4d9b4201d9d0b"
private let fixedX25519Public = "132c442be010fbd57e72603328aa76e71fccc1503aae219327d14d9c9993f472"
private let fixedDeviceId = "a0a1a2a3a4a546a7a8a9aaabacadaeaf"

/// encryptKeys(fixedPayload, pinnedPassphrase) with the salt and nonce it drew.
private let pinnedPassphrase = "correct horse battery staple"
private let pinnedSalt = pattern(32, from: 0x10)
private let pinnedNonce = pattern(12, from: 0x80)
private let pinnedBundle = EncryptedBundle(
    salt: "EBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8=",
    nonce: "gIGCg4SFhoeIiYqL",
    ciphertext:
        """
        r0vYINbSLAOKNxg9eHi8AoyuMw+uiQrseCrq1Fou2eDLKUa84DDGEkmBmkRLGnKDnRSVc4FuZDb0snFVFZ6/U54FSja83eD/\
        gf+7LHdMdO41R7wjaceeRFkyo7udO0Hkgpw01SEJoNtW8ScpWLaJof1UA+RAm77GtNusil9ajcMkYOg1Y7kVtGH3g1G+Xrhk\
        +C6G2bgJ5wASAM4WGg1mhVVit2ddaHFqei1Tl7Ui6LJh9Ixaza7/AIrV1ZSKWWsnj21YfA0EPjTI/ydddb/2MaLBI2555rY6\
        TYHuNI0GbAEaODW35yWYWjN29dBwSaagsUHMm3/Zrst6uS0lwojrEiLUFcRtoHTFyjuMNgh2SER9SswtbFZwgIqsc7PmaXLn\
        aGDiNruiICXzPzrNm/cwSXyl9SQhUpvd/l0i208oGRskOklKrlV6ulIXvD6oH/eJzO4LBKBtMSNp2dSmtNz6ddJPQQoFOBkr\
        GWKRVA==
        """,
    tag: "qJyTlZZRsqN46wi/LGpYEQ==",
    kdf: "argon2id",
    kdfParams: .standard)

/// Fixtures/browser-backup.json opens with this passphrase, to this payload.
private let fixturePassphrase = "fixture passphrase ünï ✓"
private let fixturePayload = Data(
    """
    {"ed25519_public":"x5ki1Hlhp1TvC6ZlQ9PmApit7+vNFUzd2FSCyY4D2Jw=","ed25519_private":"zHNnw/MG84RK\
    T2BYVRQu8N1LTxcpNMKwoCxANZWhg8HHmSLUeWGnVO8LpmVD0+YCmK3v680VTN3YVILJjgPYnA==","x25519_public":"I\
    WiWnZMUJGxHePYYPq4DnlIzhfOPFmN2edl3qUqqRxw=","x25519_private":"iEcJ7/kNFmNWABikAoI3oUy2VDSEKYYol\
    Mb1pgK2zFI=","device_id":"vhdCxjltRE6bZbPjm6xrgg==","created_at":1793840360}
    """.utf8)

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

/// A JSON object with one change made to it.
private func edited(_ data: Data, _ change: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    change(&object)
    return try JSONSerialization.data(withJSONObject: object)
}

private func expectThrows(_ expected: KeystoreError, _ body: () async throws -> some Any) async {
    do {
        _ = try await body()
        Issue.record("expected \(expected), got no error")
    } catch let error as KeystoreError {
        #expect(error == expected)
    } catch {
        Issue.record("expected \(expected), got \(error)")
    }
}

@Suite struct EncryptedBundleTests {
    @Test func opensWhatTheBrowserSealed() async throws {
        #expect(try await pinnedBundle.decrypt(passphrase: pinnedPassphrase) == fixedPayload)
    }

    @Test func sealsWhatTheBrowserSeals() async throws {
        let sealed = try await EncryptedBundle.encrypt(
            fixedPayload, passphrase: pinnedPassphrase, salt: pinnedSalt, nonce: pinnedNonce)
        #expect(sealed == pinnedBundle)
    }

    @Test func aFreshBundleHasTheBrowsersShape() async throws {
        let bundle = try await EncryptedBundle.encrypt(Data("hello".utf8), passphrase: "pass phrase")
        #expect(Data(base64Encoded: bundle.salt)?.count == 32)
        #expect(Data(base64Encoded: bundle.nonce)?.count == 12)
        #expect(Data(base64Encoded: bundle.tag)?.count == 16)
        #expect(bundle.kdf == "argon2id")
        #expect(bundle.kdfParams == EncryptedBundle.KDFParams(m: 19456, t: 2, p: 1))
        #expect(try await bundle.decrypt(passphrase: "pass phrase") == Data("hello".utf8))

        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(bundle)) as? [String: Any])
        #expect(Set(json.keys) == ["salt", "nonce", "ciphertext", "tag", "kdf", "kdfParams"])
        #expect(json["kdfParams"] as? [String: Int] == ["m": 19456, "t": 2, "p": 1])
    }

    /// keystore.ts falls back to ARGON2_PARAMS, and never looks at `kdf` at all.
    @Test func aBundleNamingNoParametersUsesTheBrowsersDefault() async throws {
        let bare = EncryptedBundle(
            salt: pinnedBundle.salt, nonce: pinnedBundle.nonce, ciphertext: pinnedBundle.ciphertext,
            tag: pinnedBundle.tag, kdf: nil, kdfParams: nil)
        #expect(try await bare.decrypt(passphrase: pinnedPassphrase) == fixedPayload)
    }

    @Test func aWrongPassphraseOrAnyChangedByteIsRefusedTheSameWay() async throws {
        await expectThrows(.wrongPassphrase) { try await pinnedBundle.decrypt(passphrase: "not it") }

        var ciphertext = try #require(Data(base64Encoded: pinnedBundle.ciphertext))
        ciphertext[0] ^= 1
        let flipped = EncryptedBundle(
            salt: pinnedBundle.salt, nonce: pinnedBundle.nonce, ciphertext: ciphertext.base64EncodedString(),
            tag: pinnedBundle.tag, kdf: "argon2id", kdfParams: .standard)
        await expectThrows(.wrongPassphrase) { try await flipped.decrypt(passphrase: pinnedPassphrase) }
    }

    @Test func noPassphraseIsNotAnAttempt() async {
        await expectThrows(.passphraseRequired) { try await pinnedBundle.decrypt(passphrase: "") }
        await expectThrows(.passphraseRequired) { try await EncryptedBundle.encrypt(Data(), passphrase: "") }
    }

    /// Both are refused before any memory is taken: this test would not finish otherwise.
    @Test(arguments: [
        EncryptedBundle.KDFParams(m: 4_000_000_000, t: 2, p: 1),
        EncryptedBundle.KDFParams(m: 19456, t: 4_000_000_000, p: 1),
        EncryptedBundle.KDFParams(m: 262_144, t: 17, p: 1),
    ])
    func aFileCannotAskForTheWholePhone(params: EncryptedBundle.KDFParams) async {
        let greedy = EncryptedBundle(
            salt: pinnedBundle.salt, nonce: pinnedBundle.nonce, ciphertext: pinnedBundle.ciphertext,
            tag: pinnedBundle.tag, kdf: "argon2id", kdfParams: params)
        await expectThrows(.tooDemanding) { try await greedy.decrypt(passphrase: pinnedPassphrase) }
    }

    @Test func malformedFieldsAreDamageNotAWrongPassphrase() async {
        func bundle(
            salt: String? = nil, nonce: String? = nil, tag: String? = nil,
            params: EncryptedBundle.KDFParams? = .standard
        )
            -> EncryptedBundle
        {
            EncryptedBundle(
                salt: salt ?? pinnedBundle.salt, nonce: nonce ?? pinnedBundle.nonce,
                ciphertext: pinnedBundle.ciphertext, tag: tag ?? pinnedBundle.tag, kdf: "argon2id", kdfParams: params)
        }
        await expectThrows(.damagedBackup) { try await bundle(salt: "not base64!").decrypt(passphrase: "x") }
        await expectThrows(.damagedBackup) { try await bundle(nonce: "AAAA").decrypt(passphrase: "x") }
        await expectThrows(.damagedBackup) { try await bundle(tag: "AAAA").decrypt(passphrase: "x") }
        // Too short a salt, and too little memory, are parameters no Argon2 run accepts.
        await expectThrows(.damagedBackup) { try await bundle(salt: "AAAA").decrypt(passphrase: "x") }
        await expectThrows(.damagedBackup) {
            try await bundle(params: .init(m: 1, t: 1, p: 1)).decrypt(passphrase: "x")
        }
    }

    @Test func aKDFThisBuildDoesNotKnowIsNotGuessedAt() async {
        let other = EncryptedBundle(
            salt: pinnedBundle.salt, nonce: pinnedBundle.nonce, ciphertext: pinnedBundle.ciphertext,
            tag: pinnedBundle.tag, kdf: "scrypt", kdfParams: .standard)
        await expectThrows(.unsupportedBackup) { try await other.decrypt(passphrase: pinnedPassphrase) }
    }
}

@Suite struct KeyPayloadTests {
    private func payload(_ change: (inout [String: Any]) -> Void) throws -> Data {
        try edited(fixedPayload, change)
    }

    @Test func readsTheBrowsersPayloadAndWritesItBackByteForByte() throws {
        let keys = try KeyPayload(serialized: fixedPayload)
        #expect(keys.ed25519Public.hex == fixedEd25519Public)
        #expect(keys.x25519Public.hex == fixedX25519Public)
        #expect(keys.deviceId.hex == fixedDeviceId)
        #expect(keys.createdAt == 1_700_000_000)
        #expect(keys.serialized() == fixedPayload)
    }

    @Test func actsAsTheAccountItOpens() throws {
        let keys = try KeyPayload(serialized: fixedPayload)
        let account = keys.accountKeys(address: "vector@parity.example")
        #expect(account.address == "vector@parity.example")
        #expect(account.ed25519Public == keys.ed25519Public)
        #expect(account.x25519Public == keys.x25519Public)
        let signature = try account.sign(Data("hello".utf8))
        #expect(verifyEd25519(publicKey: keys.ed25519Public, message: Data("hello".utf8), signature: signature))

        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ours = try account.sharedSecret(withEphemeral: ephemeral.publicKey.rawRepresentation)
        let theirs = try ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: keys.x25519Public))
        #expect(ours == theirs)
    }

    @Test func refusesKeysThatDoNotProduceTheirPublicHalves() async throws {
        let other = Data(repeating: 0x55, count: 32)
        let edPublic = unhex(fixedEd25519Public)
        let cases: [(inout [String: Any]) -> Void] = [
            // The wrong seed, with the public half it claims.
            { $0["ed25519_private"] = (other + edPublic).base64EncodedString() },
            // The right seed, with something else in the private key's public half.
            { $0["ed25519_private"] = (Data(repeating: 0x21, count: 32) + other).base64EncodedString() },
            { $0["ed25519_public"] = other.base64EncodedString() },
            { $0["x25519_private"] = other.base64EncodedString() },
            { $0["x25519_public"] = other.base64EncodedString() },
        ]
        for change in cases {
            let bad = try payload(change)
            await expectThrows(.keysDoNotMatch) { try KeyPayload(serialized: bad) }
        }
    }

    @Test func refusesTheWrongShape() async throws {
        let short = Data(repeating: 1, count: 16).base64EncodedString()
        let cases: [(inout [String: Any]) -> Void] = [
            { $0["ed25519_private"] = Data(repeating: 0x21, count: 32).base64EncodedString() },
            { $0["ed25519_public"] = short },
            { $0["x25519_private"] = short },
            { $0["x25519_public"] = short },
            { $0["device_id"] = Data(repeating: 1, count: 8).base64EncodedString() },
            { $0["device_id"] = "not base64!" },
            { $0["created_at"] = "yesterday" },
            { $0.removeValue(forKey: "created_at") },
            { $0.removeValue(forKey: "x25519_private") },
        ]
        for change in cases {
            let bad = try payload(change)
            await expectThrows(.damagedBackup) { try KeyPayload(serialized: bad) }
        }
        await expectThrows(.damagedBackup) { try KeyPayload(serialized: Data("not json".utf8)) }
    }

    @Test func generatedKeysAreWhatTheBrowserWouldHaveMade() throws {
        let before = Int64(Date().timeIntervalSince1970)
        let keys = KeyPayload.generate()
        #expect(keys.deviceId.count == 16)
        #expect(keys.deviceId[6] & 0xf0 == 0x40)
        #expect(keys.deviceId[8] & 0xc0 == 0x80)
        #expect(keys.createdAt >= before && keys.createdAt <= before + 5)
        #expect(KeyPayload.generate().ed25519Public != keys.ed25519Public)

        // What it writes, it reads, through the same checks a backup goes through.
        let again = try KeyPayload(serialized: keys.serialized())
        #expect(again.serialized() == keys.serialized())
        #expect(again.ed25519Public == keys.ed25519Public)
    }

    @Test func printingOneShowsNoKeys() throws {
        let keys = try KeyPayload(serialized: fixedPayload)
        var dumped = ""
        dump(keys, to: &dumped)
        let shown = [String(describing: keys), String(reflecting: keys), "\(keys)", dumped].joined(separator: "\n")
        // The public halves are held back too: a printed value has no reason to name an account.
        for secret in ["ISEh", "QkJC", "2121", "4242", fixedEd25519Public, fixedDeviceId, "bytes"] {
            #expect(!shown.contains(secret))
        }
        #expect(shown.contains("KeyPayload"))
    }
}

@Suite struct BackupFileTests {
    @Test func opensARealBrowserBackup() async throws {
        let opened = try await BackupFile.read(data: fixture("browser-backup"), passphrase: fixturePassphrase)
        #expect(opened.address == "fixture@parity.example")
        #expect(opened.keys.serialized() == fixturePayload)
    }

    @Test func writesTheFileTheBrowserWrites() throws {
        // triggerDownload's JSON.stringify(exp, null, 2), byte for byte, from the same contents.
        let data = try fixture("browser-backup")
        let file = try BackupFile(parsing: data)
        let keys = try KeyPayload(serialized: fixturePayload)
        #expect(
            BackupFile.render(address: file.address, ed25519Public: keys.ed25519Public, bundle: file.bundle) == data)
    }

    @Test func whatItWritesItOpens() async throws {
        let keys = KeyPayload.generate()
        let data = try await BackupFile.make(address: "new@parity.example", keys: keys, passphrase: "a passphrase")

        let outside = try BackupFile(parsing: data)
        #expect(outside.address == "new@parity.example")
        #expect(outside.protection == .passphrase)

        let opened = try await BackupFile.read(data: data, passphrase: "a passphrase")
        #expect(opened.address == "new@parity.example")
        #expect(opened.keys.serialized() == keys.serialized())
    }

    @Test func anAddressIsEscapedNotPasted() async throws {
        let keys = KeyPayload.generate()
        let odd = "a\"b\\c/d@parity.example"
        let data = try await BackupFile.make(address: odd, keys: keys, passphrase: "a passphrase")
        #expect(try BackupFile(parsing: data).address == odd)
    }

    @Test func aBackupNeedsAPassphrase() async throws {
        await expectThrows(.passphraseRequired) {
            try await BackupFile.make(address: "a@b", keys: KeyPayload.generate(), passphrase: "")
        }
        let data = try fixture("browser-backup")
        await expectThrows(.passphraseRequired) { try await BackupFile.read(data: data, passphrase: "") }
    }

    @Test func aPasskeyBackupIsSpottedAndExplained() async throws {
        let data = try fixture("browser-backup-passkey")
        #expect(try BackupFile(parsing: data).protection == .passkey)
        await expectThrows(.passkeyBackup) { try await BackupFile.read(data: data, passphrase: "anything") }

        let message = try #require(KeystoreError.passkeyBackup.errorDescription)
        #expect(message.contains("passphrase"))
        #expect(message.contains("web client"))
    }

    /// A passkey bundle with the label removed still isn't something a passphrase can open.
    @Test func aPasskeyBundleWithoutItsLabelIsStillAPasskeyBundle() async throws {
        let data = try edited(fixture("browser-backup-passkey")) { $0["authMethod"] = "password" }
        await expectThrows(.passkeyBackup) { try await BackupFile.read(data: data, passphrase: "anything") }
    }

    @Test func aWrongPassphrase() async throws {
        let data = try fixture("browser-backup")
        await expectThrows(.wrongPassphrase) { try await BackupFile.read(data: data, passphrase: "not it") }
    }

    @Test func somethingElseEntirely() async throws {
        for data in [
            Data("not json".utf8), Data("[]".utf8), Data("{}".utf8), Data(#"{"format":"something-else"}"#.utf8),
            Data(#"{"format":1}"#.utf8),
        ] {
            await expectThrows(.notABackup) { try await BackupFile.read(data: data, passphrase: "x") }
        }
    }

    @Test func damagedOrNewerFiles() async throws {
        let good = try fixture("browser-backup")
        let noBundle = try edited(good) { $0.removeValue(forKey: "bundle") }
        let noAddress = try edited(good) { $0.removeValue(forKey: "address") }
        let newer = try edited(good) { $0["version"] = 2 }
        await expectThrows(.damagedBackup) { try await BackupFile.read(data: noBundle, passphrase: "x") }
        await expectThrows(.damagedBackup) { try await BackupFile.read(data: noAddress, passphrase: "x") }
        await expectThrows(.unsupportedBackup) { try await BackupFile.read(data: newer, passphrase: "x") }
    }

    /// exportFile.ts only reads `format` and `authMethod`, so neither does this: a file without
    /// the browser's other labels still opens.
    @Test func aFileWithoutItsLabelsStillOpens() async throws {
        let data = try edited(fixture("browser-backup")) {
            $0.removeValue(forKey: "version")
            $0.removeValue(forKey: "ed25519Public")
            $0.removeValue(forKey: "authMethod")
        }
        let opened = try await BackupFile.read(data: data, passphrase: fixturePassphrase)
        #expect(opened.keys.serialized() == fixturePayload)
    }

    @Test func aLabelThatDisagreesWithTheKeysIsAnEditedFile() async throws {
        let data = try edited(fixture("browser-backup")) {
            $0["ed25519Public"] = Data(repeating: 9, count: 32).base64EncodedString()
        }
        await expectThrows(.keysDoNotMatch) { try await BackupFile.read(data: data, passphrase: fixturePassphrase) }
    }

    @Test func noMessageSaysMoreThanItShould() {
        let all: [KeystoreError] = [
            .passphraseRequired, .wrongPassphrase, .notABackup, .unsupportedBackup, .passkeyBackup, .damagedBackup,
            .tooDemanding, .keysDoNotMatch,
        ]
        for error in all {
            let message = error.localizedDescription
            #expect(!message.isEmpty)
            #expect(!message.contains("\u{2014}"))
            for jargon in ["Argon", "AES", "GCM", "PRF", "WebAuthn", "bundle", "payload", "JSON"] {
                #expect(!message.contains(jargon))
            }
        }
    }
}

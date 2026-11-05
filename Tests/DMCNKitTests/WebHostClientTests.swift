import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing
@testable import DMCNKit

/// A web host in miniature, holding one mailbox. It checks what open-dmcn's internal/web/api
/// checks: the login signature against the directory key, and each mailbox op's signature over
/// the nonce it issued for that op.
actor FakeHost: HTTPTransport {
    var directoryKey: Data
    var mailbox: [(hash: String, entry: Dmcn_Relay_MailboxEntry, body: Dmcn_Relay_MailboxBody)] = []
    var loginNonce: Data?
    var sessions: Set<String> = []
    var pending: [String: (op: [String: Any], nonce: Data)] = [:]
    /// What a hostile host hands out in place of a random nonce.
    var forcedNonce: Data?
    var lookupQueries: [String] = []

    init(directoryKey: Data) {
        self.directoryKey = directoryKey
    }

    func file(_ envelope: Dmcn_Message_EncryptedEnvelope, hash: String) {
        mailbox.insert(
            (hash, Dmcn_Relay_MailboxEntry(filing: envelope), Dmcn_Relay_MailboxBody(filing: envelope)), at: 0)
    }

    func expireSessions() { sessions.removeAll() }
    func rekey(to key: Data) { directoryKey = key }
    func forceNonce(_ nonce: Data) { forcedNonce = nonce }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let bearer = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "")

        switch path {
        case "/api/v1/login":
            let nonce = forcedNonce ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            loginNonce = nonce
            return reply(
                200,
                ["ed25519_pub": directoryKey.base64EncodedString(), "challenge_nonce": nonce.base64EncodedString()])
        case "/api/v1/login/verify":
            guard let nonce = loginNonce, let sig = Data(base64Encoded: body["challenge_signature"] as? String ?? ""),
                verifyEd25519(publicKey: directoryKey, message: nonce, signature: sig)
            else {
                return reply(401, ["error": "signature verification failed"])
            }
            loginNonce = nil
            let token = UUID().uuidString
            sessions.insert(token)
            return reply(200, ["session_token": token])
        default:
            break
        }

        guard let bearer, sessions.contains(bearer) else { return reply(401, ["error": "not authenticated"]) }
        switch path {
        case "/api/v1/identity/lookup":
            lookupQueries.append(request.url!.query ?? "")
            return reply(404, ["error": "not found"])
        case "/api/v1/mailbox/challenge":
            let nonce = forcedNonce ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let id = UUID().uuidString
            pending[id] = (body, nonce)
            return reply(200, ["correlation_id": id, "nonce": nonce.base64EncodedString()])
        case "/api/v1/mailbox/complete":
            guard let id = body["correlation_id"] as? String, let p = pending.removeValue(forKey: id),
                let sig = Data(base64Encoded: body["signature"] as? String ?? ""),
                verifyEd25519(publicKey: directoryKey, message: p.nonce, signature: sig)
            else {
                return reply(502, ["error": "mailbox op failed: auth failed"])
            }
            switch p.op["op"] as? String {
            case "list":
                return reply(
                    200,
                    [
                        "entries": try mailbox.map {
                            ["hash": $0.hash, "entry": try $0.entry.serializedData().base64EncodedString()]
                        },
                        "next_cursor": "",
                    ])
            case "body":
                guard let m = mailbox.first(where: { $0.hash == p.op["hash"] as? String }) else {
                    return reply(404, ["error": "not found"])
                }
                return reply(200, ["hash": m.hash, "body": try m.body.serializedData().base64EncodedString()])
            default:
                return reply(400, ["error": "unknown mailbox op"])
            }
        default:
            return reply(404, ["error": "no route"])
        }
    }

    private func reply(_ status: Int, _ json: [String: Any]) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return (
            data,
            HTTPURLResponse(
                url: URL(string: "https://host.example")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

@Suite struct WebHostClientAgainstAFakeHost {
    let alice = SoftwareAccountKeys(address: "alice@parity.example")
    let bob = SoftwareAccountKeys(address: "bob@parity.example")

    func host() -> FakeHost { FakeHost(directoryKey: bob.ed25519Public) }

    func letter(_ text: String) throws -> Dmcn_Message_EncryptedEnvelope {
        try SplitMessage.seal(
            .init(
                messageID: pattern(16, from: 1), threadID: pattern(16, from: 17), recipientAddress: bob.address,
                to: [bob.address], subject: "Hi", bodyText: text, sentAt: 1_700_000_000),
            from: alice, to: [.init(x25519Public: bob.x25519Public)])
    }

    @Test func signsInListsAndOpensAMessage() async throws {
        let host = host()
        await host.file(try letter("first"), hash: String(repeating: "a", count: 64))
        await host.file(try letter("second"), hash: String(repeating: "b", count: 64))
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)

        try await client.signIn(bob)
        let inbox = Inbox(service: client, keys: bob)
        let (rows, next) = try await inbox.page()
        #expect(next == nil)
        #expect(rows.map(\.id) == [String(repeating: "b", count: 64), String(repeating: "a", count: 64)])
        #expect(try rows[0].opened.get().header.snippet == "second")

        let content = try await inbox.content(of: rows[1])
        #expect(String(decoding: content.body.content, as: UTF8.self) == "first")
    }

    @Test func aRowThatDoesNotOpenIsKeptWithItsReason() async throws {
        let host = host()
        var broken = try letter("tampered")
        broken.encryptedHeader[broken.encryptedHeader.startIndex] ^= 0xff
        await host.file(broken, hash: String(repeating: "c", count: 64))
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)
        try await client.signIn(bob)

        let (rows, _) = try await Inbox(service: client, keys: bob).page()
        #expect(rows.count == 1)
        #expect(throws: InboxRowError.self) { try rows[0].opened.get() }
    }

    @Test func aLapsedSessionSignsInAgainOnce() async throws {
        let host = host()
        await host.file(try letter("still here"), hash: String(repeating: "d", count: 64))
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)
        try await client.signIn(bob)
        await host.expireSessions()

        let page = try await client.list(bob)
        #expect(page.items.count == 1)
    }

    @Test func aRekeyedAccountSaysSoInsteadOfFailingToSignIn() async throws {
        let host = host()
        await host.rekey(to: alice.ed25519Public)
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)
        await #expect(throws: AccountRekeyedError(address: bob.address)) { try await client.signIn(bob) }
    }

    @Test func callsWithoutASessionAreRefusedLocally() async throws {
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host())
        await #expect(throws: APIError(status: 401, message: "not signed in")) { try await client.list(bob) }
    }

    @Test func aPlusInAnAddressIsNotReadAsASpace() async throws {
        let host = host()
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)
        try await client.signIn(bob)
        _ = try? await client.lookup("alice+news@parity.example")
        #expect(await host.lookupQueries == ["address=alice%2Bnews@parity.example"])
    }

    // Anything longer than a nonce could be a context-tagged header or record, and a signature
    // over one of those is the account's word on it.
    @Test func aLoginChallengeThatIsNotANonceIsNotSigned() async throws {
        let host = host()
        await host.forceNonce(SignatureContext.messageHeader.signable(fill(64, 0x01)))
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)
        await #expect(throws: APIError.self) { try await client.signIn(bob) }
        #expect(await !client.isSignedIn)
    }

    @Test func aMailboxChallengeThatIsNotANonceIsNotSigned() async throws {
        let host = host()
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)
        try await client.signIn(bob)
        await host.forceNonce(SignatureContext.messageHeader.signable(fill(64, 0x01)))
        await #expect(throws: APIError.self) { try await client.list(bob) }
    }

    @Test func aLate401DoesNotSignBackInAfterSignOut() async throws {
        // The session is revoked while a call is in flight, so the host answers it 401.
        actor SignsOutMidCall: HTTPTransport {
            let host: FakeHost
            var client: WebHostClient?
            var logins = 0
            init(host: FakeHost) { self.host = host }
            func arm(_ client: WebHostClient) { self.client = client; logins = 0 }

            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if request.url!.path == "/api/v1/login" { logins += 1 }
                if request.url!.path == "/api/v1/mailbox/challenge", let client {
                    self.client = nil
                    await client.signOut()
                    await host.expireSessions()
                }
                return try await host.send(request)
            }
        }
        let transport = SignsOutMidCall(host: host())
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: transport)
        try await client.signIn(bob)
        await transport.arm(client)

        await #expect(throws: APIError.self) { try await client.list(bob) }
        #expect(await transport.logins == 0)
        #expect(await !client.isSignedIn)
    }

    @Test func aRefusalReadsAsTheHostsOwnWords() {
        let refusal: any Error = APIError(status: 403, message: "this account is suspended")
        #expect(refusal.localizedDescription == "this account is suspended")
    }
}

import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing
@testable import DMCNKit

/// A reference daemon in miniature. It holds what open-dmcn's internal/web/api holds and checks
/// what it checks: the directory's key for import, the self-signature and address on a record,
/// and the petition proof and agreed keys. Unknown /api paths answer as Go's mux does there: a
/// plain-text 404, because a route that isn't served isn't there at all.
private actor Daemon: HTTPTransport {
    enum Mode { case registration, petitions }

    var mode: Mode
    var directory: [String: (ed25519: Data, x25519: Data)] = [:]
    var issuedNonce: [String: Data] = [:]
    var sessions: Set<String> = []
    var petitions: [String: (ed25519: Data, x25519: Data, address: String?)] = [:]
    /// What `GET /api/v1/signup` says. nil is a daemon from before that route.
    var signup: String?
    var capabilitiesReply: (Int, String)? = nil
    var hintsAvailable = true
    var records: [Dmcn_Identity_IdentityRecord] = []
    var requests: [String] = []
    var bodies: [String: [String: String]] = [:]
    var forcedNonce: Data?
    var authorizationHeaders: [String: String?] = [:]

    init(mode: Mode = .registration) { self.mode = mode }

    func add(_ address: String, ed25519: Data, x25519: Data) { directory[address] = (ed25519, x25519) }
    func answerCapabilities(_ status: Int, _ body: String) { capabilitiesReply = (status, body) }
    func dropHints() { hintsAvailable = false }
    func forceNonce(_ nonce: Data) { forcedNonce = nonce }
    func assign(_ code: String, to address: String) { petitions[code]?.address = address }
    func answerSignup(_ mode: String) { signup = mode }
    func expireSessions() { sessions.removeAll() }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let key = "\(request.httpMethod ?? "?") \(url.path)"
        requests.append(url.query.map { "\(key)?\($0)" } ?? key)
        authorizationHeaders[key] = request.value(forHTTPHeaderField: "Authorization")
        let body = (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        bodies[key] = body.compactMapValues { $0 as? String }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems ?? []

        switch key {
        case "POST /api/v1/import/challenge", "POST /api/v1/login":
            guard let address = body["address"] as? String, let entry = directory[address] else {
                return json(404, ["error": "address is not registered in the directory"])
            }
            let nonce = forcedNonce ?? Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            issuedNonce[address] = nonce
            return json(
                200,
                [
                    "ed25519_pub": entry.ed25519.base64EncodedString(),
                    "x25519_pub": entry.x25519.base64EncodedString(),
                    "challenge_nonce": nonce.base64EncodedString(),
                ])
        case "POST /api/v1/import", "POST /api/v1/login/verify":
            guard let address = body["address"] as? String, let nonce = issuedNonce[address] else {
                return json(400, ["error": "no pending import challenge for address"])
            }
            guard let entry = directory[address],
                let signature = Data(base64Encoded: body["challenge_signature"] as? String ?? ""),
                verifyEd25519(publicKey: entry.ed25519, message: nonce, signature: signature)
            else { return json(401, ["error": "challenge signature does not match the registered identity"]) }
            issuedNonce[address] = nil
            let token = UUID().uuidString
            sessions.insert(token)
            return json(200, ["session_token": token])
        case "GET /api/v1/capabilities":
            guard let bearer = request.value(forHTTPHeaderField: "Authorization")?.dropFirst(7),
                sessions.contains(String(bearer))
            else { return json(401, ["error": "not authenticated"]) }
            guard let (status, text) = capabilitiesReply else { return notFound() }
            return raw(status, Data(text.utf8))
        case "GET /api/v1/relay-hints":
            guard hintsAvailable else { return json(503, ["error": "no mailbox relay available"]) }
            return json(200, ["relay_hints": ["/dns4/relay.parity.example/tcp/7400"]])
        case "POST /api/v1/register":
            guard mode == .registration else { return notFound() }
            guard let wire = Data(base64Encoded: body["identity_record"] as? String ?? ""),
                let record = try? Dmcn_Identity_IdentityRecord(serializedBytes: wire), record.ownerSignatureIsValid()
            else { return json(400, ["error": "identity record signature invalid"]) }
            guard body["address"] as? String == record.address else {
                return json(400, ["error": "address does not match identity record"])
            }
            guard directory[record.address] == nil else {
                return json(409, ["error": "address is already registered", "code": "already_registered"])
            }
            records.append(record)
            directory[record.address] = (record.ed25519PublicKey, record.x25519PublicKey)
            return json(200, ["status": "active"])
        case "POST /api/v1/petition":
            guard mode == .petitions else { return notFound() }
            guard let edPublic = Data(base64Encoded: body["ed25519_pub"] as? String ?? ""),
                let xPublic = Data(base64Encoded: body["x25519_pub"] as? String ?? ""),
                let proof = Data(base64Encoded: body["proof"] as? String ?? ""),
                verifyEd25519(
                    publicKey: edPublic, message: Data("dmcn-petition-v1\0".utf8) + edPublic + xPublic, signature: proof
                )
            else {
                return json(
                    400, ["error": "the signature does not prove possession of this key", "code": "bad_proof"])
            }
            petitions["0428-9173-5560"] = (edPublic, xPublic, nil)
            return json(200, ["code": "0428-9173-5560", "expires_at": "2026-11-12T08:30:00Z"])
        case "GET /api/v1/signup":
            guard let signup else { return notFound() }
            return json(200, ["mode": signup])
        case "GET /api/v1/petition/status":
            guard mode == .petitions else { return notFound() }
            let code = query.first { $0.name == "code" }?.value ?? ""
            guard !code.isEmpty else { return json(400, ["error": "code is required"]) }
            guard let petition = petitions[code] else {
                return json(404, ["error": "no pending petition for that code", "code": "unknown_code"])
            }
            if let address = petition.address { return json(200, ["status": "assigned", "address": address]) }
            return json(200, ["status": "pending", "expires_at": "2026-11-12T08:30:00Z"])
        case "POST /api/v1/petition/complete":
            guard mode == .petitions else { return notFound() }
            guard let code = body["code"] as? String, let petition = petitions[code] else {
                return json(404, ["error": "no pending petition for that code", "code": "unknown_code"])
            }
            guard let address = petition.address else {
                return json(
                    409, ["error": "this petition has not been assigned an address yet", "code": "not_assigned"])
            }
            guard let wire = Data(base64Encoded: body["identity_record"] as? String ?? ""),
                let record = try? Dmcn_Identity_IdentityRecord(serializedBytes: wire), record.ownerSignatureIsValid()
            else { return json(400, ["error": "identity record signature invalid"]) }
            guard record.address == address else {
                return json(400, ["error": "the record is not for the assigned address", "code": "address_mismatch"])
            }
            guard record.ed25519PublicKey == petition.ed25519, record.x25519PublicKey == petition.x25519 else {
                return json(
                    403, ["error": "the record does not carry the keys this petition proved", "code": "key_mismatch"])
            }
            records.append(record)
            directory[address] = (record.ed25519PublicKey, record.x25519PublicKey)
            petitions[code] = nil
            return json(200, ["status": "active", "address": address])
        default:
            return notFound()
        }
    }

    private func notFound() -> (Data, HTTPURLResponse) { raw(404, Data("404 page not found\n".utf8)) }

    private func json(_ status: Int, _ object: Any) -> (Data, HTTPURLResponse) {
        raw(status, try! JSONSerialization.data(withJSONObject: object))
    }

    private func raw(_ status: Int, _ data: Data) -> (Data, HTTPURLResponse) {
        (
            data,
            HTTPURLResponse(
                url: URL(string: "https://mail.test/")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

private func client(_ daemon: Daemon) -> WebHostClient {
    WebHostClient(baseURL: URL(string: "https://mail.test")!, transport: daemon)
}

private let address = "alice@parity.example"

private func expectAPIError(
    status: Int, code: String? = nil, message: String? = nil, _ body: () async throws -> some Any
) async {
    do {
        _ = try await body()
        Issue.record("expected an APIError with status \(status)")
    } catch let error as APIError {
        #expect(error.status == status)
        #expect(error.code == code)
        if let message { #expect(error.message == message) }
    } catch {
        Issue.record("expected an APIError with status \(status), got \(error)")
    }
}

@Suite struct ImportIdentity {
    @Test func provesPossessionAndStartsASession() async throws {
        let keys = KeyPayload.generate().accountKeys(address: address)
        let daemon = Daemon()
        await daemon.add(address, ed25519: keys.ed25519Public, x25519: keys.x25519Public)
        let host = client(daemon)

        try await host.importIdentity(keys)

        #expect(await host.isSignedIn)
        #expect(await daemon.requests == ["POST /api/v1/import/challenge", "POST /api/v1/import"])
        // The signature is all that goes back: the host holds the nonce, as ImportRequest says.
        #expect(await Set(daemon.bodies["POST /api/v1/import"]!.keys) == ["address", "challenge_signature"])
        #expect(await daemon.authorizationHeaders["POST /api/v1/import"]! == nil)
    }

    @Test func aBackupForAnotherKeyIsRefusedBeforeAnythingIsSigned() async throws {
        let keys = KeyPayload.generate().accountKeys(address: address)
        let directoryKeys = KeyPayload.generate()
        let daemon = Daemon()
        await daemon.add(address, ed25519: directoryKeys.ed25519Public, x25519: directoryKeys.x25519Public)
        let host = client(daemon)

        await #expect(throws: IdentityMismatchError(address: address)) { try await host.importIdentity(keys) }
        #expect(await !host.isSignedIn)
        #expect(await daemon.requests == ["POST /api/v1/import/challenge"])
    }

    /// `signIn` lets a missing key fall through; here the key is the whole check.
    @Test func aChallengeNamingNoKeyIsRefused() async throws {
        let keys = KeyPayload.generate().accountKeys(address: address)
        let daemon = Daemon()
        await daemon.add(address, ed25519: Data(), x25519: keys.x25519Public)

        await #expect(throws: IdentityMismatchError.self) { try await client(daemon).importIdentity(keys) }
    }

    @Test func anUnknownAddressIsTheHostsRefusal() async {
        let keys = KeyPayload.generate().accountKeys(address: address)
        await expectAPIError(status: 404, message: "address is not registered in the directory") {
            try await client(Daemon()).importIdentity(keys)
        }
    }

    /// The account key signs this with no context tag, so the 32-byte rule that keeps a host from
    /// passing off a header as a nonce has to hold here too.
    @Test func aChallengeThatIsNotANonceIsNotSigned() async throws {
        let keys = KeyPayload.generate().accountKeys(address: address)
        let daemon = Daemon()
        await daemon.add(address, ed25519: keys.ed25519Public, x25519: keys.x25519Public)
        await daemon.forceNonce(Data(repeating: 7, count: 48))

        await expectAPIError(status: 0) { try await client(daemon).importIdentity(keys) }
        #expect(await daemon.requests == ["POST /api/v1/import/challenge"])
    }

    @Test func theMismatchMessageIsForPeople() {
        let message = IdentityMismatchError(address: address).localizedDescription
        #expect(message.contains(address))
        #expect(!message.contains("\u{2014}"))
    }
}

@Suite struct CapabilitiesCalls {
    private func signedIn(_ daemon: Daemon) async throws -> (WebHostClient, SoftwareAccountKeys) {
        let keys = KeyPayload.generate().accountKeys(address: address)
        await daemon.add(address, ed25519: keys.ed25519Public, x25519: keys.x25519Public)
        let host = client(daemon)
        try await host.signIn(keys)
        return (host, keys)
    }

    @Test func readsTheFullAnswer() async throws {
        let daemon = Daemon()
        let (host, _) = try await signedIn(daemon)
        await daemon.answerCapabilities(
            200,
            """
            {"address":"alice@parity.example",
             "rotation":{"fleet_ready":true,"domain_allows":true,"min_device_age_days":7},
             "forward":{"fleet_ready":true,"eligible":false,"forward_to":"a@b.example"}}
            """)

        let answer = await host.capabilities()
        #expect(answer.address == address)
        #expect(answer.rotation.fleetReady && answer.rotation.domainAllows)
        #expect(answer.rotation.minDeviceAgeDays == 7)
        #expect(answer.forward?.fleetReady == true)
        #expect(answer.forward?.eligible == false)
        #expect(answer.forward?.forwardTo == "a@b.example")
    }

    @Test func forwardIsOptional() async throws {
        let daemon = Daemon()
        let (host, _) = try await signedIn(daemon)
        await daemon.answerCapabilities(
            200, #"{"address":"a@b","rotation":{"fleet_ready":false,"domain_allows":true,"min_device_age_days":0}}"#)
        let answer = await host.capabilities()
        #expect(answer.forward == nil)
        #expect(answer.rotation.domainAllows)
    }

    /// NO_CAPABILITIES, as the browser's own test asserts it.
    @Test func deniedDeniesEverything() {
        #expect(!Capabilities.denied.rotation.fleetReady)
        #expect(!Capabilities.denied.rotation.domainAllows)
        #expect(Capabilities.denied.rotation.minDeviceAgeDays == 0)
        #expect(Capabilities.denied.forward == nil)
    }

    /// open-dmcn's own daemon doesn't route this, so this is the everyday answer there.
    @Test func aHostWithoutTheEndpointMeansNo() async throws {
        let (host, _) = try await signedIn(Daemon())
        #expect(await host.capabilities() == .denied)
    }

    @Test(arguments: [
        (500, #"{"error":"boom"}"#),
        (200, "<html>not json</html>"),
        (200, #"{"address":"a@b"}"#),
        (200, #"{"address":"a@b","rotation":{"fleet_ready":true}}"#),
    ])
    func anyFailureMeansNo(status: Int, body: String) async throws {
        let daemon = Daemon()
        let (host, _) = try await signedIn(daemon)
        await daemon.answerCapabilities(status, body)
        #expect(await host.capabilities() == .denied)
    }

    @Test func notSignedInMeansNo() async {
        #expect(await client(Daemon()).capabilities() == .denied)
    }

    @Test func aLapsedSessionIsRenewedOnlyWhenTheKeysAreOffered() async throws {
        let daemon = Daemon()
        let (host, keys) = try await signedIn(daemon)
        await daemon.answerCapabilities(
            200, #"{"address":"a@b","rotation":{"fleet_ready":true,"domain_allows":true,"min_device_age_days":1}}"#)
        await daemon.expireSessions()

        #expect(await host.capabilities() == .denied)
        #expect(await host.capabilities(renewingWith: keys).rotation.fleetReady)
    }
}

@Suite struct Registering {
    @Test func publishesASelfSignedRecordAndStartsNoSession() async throws {
        let keys = KeyPayload.generate()
        let daemon = Daemon()
        let host = client(daemon)

        let result = try await host.register(keys, address: address)

        #expect(result.status == "active")
        #expect(await !host.isSignedIn)
        #expect(
            await daemon.requests == [
                "GET /api/v1/relay-hints?address=alice@parity.example", "POST /api/v1/register",
            ])
        let body = await daemon.bodies["POST /api/v1/register"]!
        #expect(Set(body.keys) == ["address", "ed25519_pub", "x25519_pub", "identity_record", "self_signature"])
        #expect(body["ed25519_pub"] == keys.ed25519Public.base64EncodedString())
        #expect(body["x25519_pub"] == keys.x25519Public.base64EncodedString())

        let record = try #require(await daemon.records.first)
        #expect(body["self_signature"] == record.selfSignature.base64EncodedString())
        #expect(record.address == address)
        #expect(record.createdAt == keys.createdAt)
        #expect(record.revision == 1)
        #expect(record.relayHints == ["/dns4/relay.parity.example/tcp/7400"])

        // The ordinary sign-in follows, with the same keys.
        try await host.signIn(keys.accountKeys(address: address))
        #expect(await host.isSignedIn)
    }

    @Test func aTakenAddressSaysSo() async throws {
        let daemon = Daemon()
        let other = KeyPayload.generate()
        await daemon.add(address, ed25519: other.ed25519Public, x25519: other.x25519Public)
        await expectAPIError(
            status: 409, code: "already_registered",
            message: "That address is already taken. Choose another, or sign in."
        ) {
            try await client(daemon).register(KeyPayload.generate(), address: address)
        }
    }

    @Test func aBadChoiceNeverReachesTheHost() async throws {
        let daemon = Daemon()
        await expectAPIError(status: 0) { try await client(daemon).register(KeyPayload.generate(), address: "Nope@x") }
        #expect(await daemon.requests.isEmpty)
    }

    @Test func noRelayMeansNoAccount() async throws {
        let daemon = Daemon()
        await daemon.dropHints()
        await expectAPIError(status: 503, message: "no mailbox relay available") {
            try await client(daemon).register(KeyPayload.generate(), address: address)
        }
        #expect(await daemon.requests.count == 1)
    }

    /// A petition daemon has no such route at all, and its 404 isn't JSON.
    @Test func aDomainThatDoesNotSelfServeSaysWhatToDo() async throws {
        await expectAPIError(
            status: 404, message: "This server doesn't create accounts itself. Ask its admin for a mailbox."
        ) {
            try await client(Daemon(mode: .petitions)).register(KeyPayload.generate(), address: address)
        }
    }

    @Test func anAddressWithAPlusSurvivesTheQueryString() async throws {
        let daemon = Daemon()
        _ = try await client(daemon).relayHints(for: "a+b@parity.example")
        #expect(await daemon.requests == ["GET /api/v1/relay-hints?address=a%2Bb@parity.example"])
    }
}

@Suite struct Petitions {
    @Test func theWholeWay() async throws {
        let keys = KeyPayload.generate()
        let daemon = Daemon(mode: .petitions)
        let host = client(daemon)

        let ticket = try await host.createPetition(keys)
        #expect(ticket.code == "0428-9173-5560")
        #expect(ticket.expiresAt == Date(timeIntervalSince1970: 1_794_472_200))
        #expect(await Set(daemon.bodies["POST /api/v1/petition"]!.keys) == ["ed25519_pub", "x25519_pub", "proof"])

        #expect(try await host.petitionStatus(code: ticket.code) == .pending(expiresAt: ticket.expiresAt))
        await daemon.assign(ticket.code, to: address)
        #expect(try await host.petitionStatus(code: ticket.code) == .assigned(address: address))

        let result = try await host.completePetition(code: ticket.code, address: address, keys: keys)
        #expect(result == Registration(status: "active", address: address))
        #expect(await Set(daemon.bodies["POST /api/v1/petition/complete"]!.keys) == ["code", "identity_record"])
        let record = try #require(await daemon.records.first)
        #expect(record.createdAt == keys.createdAt)
        #expect(await !host.isSignedIn)

        try await host.signIn(keys.accountKeys(address: address))
        #expect(await host.isSignedIn)
    }

    @Test func theCodeIsSentAsTyped() async throws {
        let daemon = Daemon(mode: .petitions)
        _ = try? await client(daemon).petitionStatus(code: "0428-9173-5560")
        #expect(await daemon.requests == ["GET /api/v1/petition/status?code=0428-9173-5560"])
    }

    @Test func aSpentCodeIsExplained() async {
        await expectAPIError(
            status: 404, code: "unknown_code", message: "That request expired. You can ask for a new one."
        ) {
            try await client(Daemon(mode: .petitions)).petitionStatus(code: "1111-2222-3333")
        }
    }

    @Test func claimingBeforeTheAdminActsIsRefused() async throws {
        let keys = KeyPayload.generate()
        let daemon = Daemon(mode: .petitions)
        let host = client(daemon)
        let ticket = try await host.createPetition(keys)
        await expectAPIError(status: 409, code: "not_assigned") {
            try await host.completePetition(code: ticket.code, address: address, keys: keys)
        }
    }

    @Test func someoneElsesKeysCannotClaimTheCode() async throws {
        let daemon = Daemon(mode: .petitions)
        let host = client(daemon)
        let ticket = try await host.createPetition(KeyPayload.generate())
        await daemon.assign(ticket.code, to: address)
        await expectAPIError(status: 403, code: "key_mismatch") {
            try await host.completePetition(code: ticket.code, address: address, keys: KeyPayload.generate())
        }
    }

    @Test func aDomainWithoutPetitionsAnswersNotFound() async {
        await expectAPIError(status: 404) { try await client(Daemon()).createPetition(KeyPayload.generate()) }
    }
}

@Suite struct KnowingHowToSignUp {
    @Test(arguments: [("register", SignupMode.register), ("petition", .petition), ("closed", .closed)])
    func aServerThatSaysIsBelieved(said: String, mode: SignupMode) async throws {
        // The mode the daemon is in is deliberately the other one: the answer is what counts.
        let daemon = Daemon(mode: mode == .register ? .petitions : .registration)
        await daemon.answerSignup(said)
        #expect(try await client(daemon).signupMode() == mode)
    }

    @Test func aModeThisClientDoesntKnowOffersNothing() async throws {
        let daemon = Daemon(mode: .registration)
        await daemon.answerSignup("invitation")
        #expect(try await client(daemon).signupMode() == .closed)
    }

    @Test func anOlderDaemonIsReadFromItsRoutes() async throws {
        #expect(try await client(Daemon(mode: .petitions)).signupMode() == .petition)
        #expect(try await client(Daemon(mode: .registration)).signupMode() == .register)
    }
}

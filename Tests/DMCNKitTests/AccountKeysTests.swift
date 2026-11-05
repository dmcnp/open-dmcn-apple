import Crypto
import Foundation
import Testing

@testable import DMCNKit

private struct FixedKeys: AccountKeys {
    let address = "a@b.example"
    let ed25519Public = Data(repeating: 1, count: 32)
    let x25519Public = Data(repeating: 2, count: 32)
    func sign(_ message: Data) throws -> Data { Data() }
    func sharedSecret(withEphemeral ephemeralPublic: Data) throws -> SharedSecret {
        throw CryptoKitError.incorrectParameterSize
    }
}

@Suite struct AnAccountsFingerprint {
    /// Worked out separately: sha256(bytes([1]) * 32 + bytes([2]) * 32).digest()[:20], in Python.
    @Test func isTheWebClientsFormula() {
        #expect(FixedKeys().fingerprint == "F818AFD37A6DC3BC92FB44731011277006DB4EFA")
    }
}

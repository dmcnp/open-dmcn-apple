import Foundation
import SwiftProtobuf

/// Signature domain-separation tags (SPEC_CORE §2): `sig = Ed25519(priv, ctx ‖ canonical)`.
/// NUL-terminated, byte-identical to the constants in Go internal/core/identity/identity.go
/// and internal/core/message/split.go.
public enum SignatureContext: String, Sendable {
    case identitySelf = "dmcn-identity-self-v1"
    case darSelf = "dmcn-dar-self-v1"
    case addressRemoval = "dmcn-address-removal-v1"
    case credential = "dmcn-credential-v1"
    /// Named after the record it replaced; renaming it would invalidate every blocklist.
    case keyCompromise = "dmcn-key-compromise-v1"
    case messageHeader = "dmcn-msg-header-v1"

    public var tag: Data { Data(rawValue.utf8) + [0] }

    /// The bytes a signature of this kind covers.
    public func signable(_ canonical: Data) -> Data { tag + canonical }
}

/// The canonical form every signature covers: deterministic protobuf serialisation.
///
/// Go and the browser check a signature by re-marshaling what they parsed, so this must give
/// Go's `proto.MarshalOptions{Deterministic: true}` bytes exactly. Fields are written in
/// field-number order with proto3 defaults omitted, and map keys sorted. The golden vectors in
/// ParityVectorTests hold it to that.
public enum Canonical {
    public static func marshal(_ message: some SwiftProtobuf.Message) throws -> Data {
        var options = BinaryEncodingOptions()
        options.useDeterministicOrdering = true
        return try message.serializedData(options: options)
    }
}

import Foundation

/// What THIS build is, at run time: the Apple counterpart of the web client's deployment seam
/// (open-dmcn cmd/dmcnd/web/src/lib/deployment.ts). The reference app and a product app share
/// every other file; they differ only here and in Config/Deployment.xcconfig.
///
/// A difference belongs here only if both answers are correct. One that is merely older on one
/// side is drift, and belongs in neither.
struct Deployment: Sendable {
    /// The host the sign-in form starts with, from the build's xcconfig. Nil: the user types one.
    let defaultHost: String?
    /// The line under the sign-in form. A client with no provider behind it can only state what
    /// is true of the software itself; a hosted product may promise more.
    let signInNote: String

    static let current = Deployment(
        defaultHost: (Bundle.main.object(forInfoDictionaryKey: "DMCNDefaultHost") as? String)
            .flatMap { $0.isEmpty ? nil : $0 },
        signInNote: "Your keys stay on this device. Mail is decrypted here, never on the server."
    )
}

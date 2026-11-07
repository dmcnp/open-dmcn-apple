import Foundation

/// Why keys couldn't be opened. Each case says what a person can do next, because an app shows
/// these as they are. None of them carries a key, a passphrase or anything from inside a file.
public enum KeystoreError: Error, Equatable, Sendable {
    /// No passphrase was given.
    case passphraseRequired
    /// The passphrase didn't open it. AES-GCM can't tell this from a damaged file.
    case wrongPassphrase
    /// The file isn't a backup at all.
    case notABackup
    /// It's a backup in a form written by something newer than this app.
    case unsupportedBackup
    /// A backup locked with a passkey. Opening one takes WebAuthn's PRF extension, and the key
    /// that comes out of it never leaves the browser.
    case passkeyBackup
    /// It looks like a backup, but parts are missing or malformed.
    case damagedBackup
    /// It asks for more memory or time than this device should spend on a file from anywhere.
    case tooDemanding
    /// The private keys inside don't produce the public keys beside them.
    case keysDoNotMatch
}

extension KeystoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .passphraseRequired:
            return "Enter the passphrase for this backup."
        case .wrongPassphrase:
            return "That passphrase didn't work. Check it and try again."
        case .notABackup:
            return "This file isn't an account backup. Choose the backup file you saved."
        case .unsupportedBackup:
            return "This backup was made by a newer version. Update the app and try again."
        case .passkeyBackup:
            return
                "This backup is locked with a passkey, which only works in the web client. "
                + "Sign in there, make a new backup with a passphrase, and open that file here."
        case .damagedBackup:
            return "This backup file is damaged and can't be opened. Try another copy of it."
        case .tooDemanding:
            return "This backup needs more memory than this device can give it, so it wasn't opened."
        case .keysDoNotMatch:
            return "The keys in this backup don't belong together, so it wasn't used. Try another copy of it."
        }
    }
}

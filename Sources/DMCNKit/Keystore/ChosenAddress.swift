import Foundation

// The rules for an address someone picks for themselves, matching src/lib/address.ts, which
// mirrors open-dmcn's internal/core/identity/address_rules.go. The messages are this app's own:
// the rules have to agree with the browser, and the wording only has to make sense on a phone.

/// What's wrong with `address` as a choice, in words to show the person, or nil if it's fine.
/// `minLength` is for a server that holds short names back.
public func validateChosenAddress(_ address: String, minLength: Int = 1) -> String? {
    // By scalars, so an accent or an emoji can't hide an "@".
    let parts = address.unicodeScalars.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[1].isEmpty else {
        return "Enter an address like name@example.com."
    }
    return validateLocalPart(String(parts[0]), minLength: minLength)
}

/// The same check on just the part before the `@`.
public func validateLocalPart(_ local: String, minLength: Int = 1) -> String? {
    let maxLength = 64
    // UTF-16 units, as JavaScript counts them: this decides which message a non-ASCII name gets.
    let length = local.utf16.count
    guard length >= minLength, length <= maxLength else {
        return "The part before the @ must be \(minLength) to \(maxLength) characters."
    }
    guard isWellFormed(local) else {
        return
            "Use lowercase letters, numbers, dots, dashes and underscores. Start and end with a letter "
            + "or number, and don't put two dots, dashes or underscores together."
    }
    // A hex name this long could be mistaken for a public key (64) or a fingerprint (40).
    if length == 64 || length == 40, local.utf8.allSatisfy({ isDigit($0) || (0x61...0x66).contains($0) }) {
        return "That name looks like a security key, so it can't be used. Choose another."
    }
    return nil
}

/// `/^[a-z0-9]+([-._][a-z0-9]+)*$/`, spelled out: runs of letters and digits joined by single
/// separators. Swift's regex would need care to refuse a trailing newline as JavaScript's does.
private func isWellFormed(_ local: String) -> Bool {
    var afterSeparator = true
    for byte in local.utf8 {
        if isDigit(byte) || (0x61...0x7a).contains(byte) {
            afterSeparator = false
        } else if byte == 0x2d || byte == 0x2e || byte == 0x5f, !afterSeparator {
            afterSeparator = true
        } else {
            return false
        }
    }
    return !afterSeparator
}

private func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }

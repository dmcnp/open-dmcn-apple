import Foundation

// Rendering rules for a message's `sender_display` (SPEC_CORE §3). The name is signed, so no relay
// can rewrite it, but it is asserted rather than verified: for bridged mail it is whatever the From
// header said. So it is only ever shown next to the address, never in place of it, and nothing keys
// off it. Parity with the browser's lib/trust/displayName.ts.

public enum DisplayName {
    /// Matches the producer's cap, so a name that survived signing isn't trimmed again.
    private static let maxLength = 96

    /// A wire display name as one line of printable text, or "" when nothing usable is left. The
    /// producer cleans this before signing, but the producer is whoever signed the header, so a
    /// name carrying control or bidirectional characters is caught here, at the last chance.
    public static func sanitize(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var collapsed = String.UnicodeScalarView()
        var inRun = false
        for scalar in raw.unicodeScalars where !isBidi(scalar) {
            // Whitespace collapses before the control strip, so a CR/LF becomes a space rather than
            // gluing the words either side of it together.
            if JSText.isWhitespace(scalar) {
                if !inRun { collapsed.append(" ") }
                inRun = true
                continue
            }
            inRun = false
            if !isControl(scalar) { collapsed.append(scalar) }
        }
        return JSText.trim(JSText.prefixUTF16(JSText.trim(String(collapsed)), maxLength))
    }

    /// Invisible codepoints that reorder rendered text: the classic way to make a name read as
    /// something other than what it is.
    private static func isBidi(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: true
        default: false
        }
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x1F, 0x7F...0x9F: true
        default: false
        }
    }

    public struct Label: Sendable, Equatable {
        public let primary: String
        /// The address whenever `primary` is a name. Empty only when `primary` is the address, so
        /// a caller showing both never hides the identity behind a label.
        public let secondary: String
    }

    /// What to show for a counterparty: the name the owner gave them, then the name the message
    /// carried, then the address.
    public static func senderLabel(address: String, contactName: String, wireDisplay: String? = nil) -> Label {
        let normalized = JSText.normalizedAddress(address)
        if !contactName.isEmpty, !JSText.same(JSText.normalizedAddress(contactName), normalized) {
            return Label(primary: contactName, secondary: address)
        }
        let display = sanitize(wireDisplay)
        // A name that repeats the address adds nothing, and one carrying an address of its own
        // ("PayPal Security <security@paypal.com>" as the NAME) is a spoof attempt.
        if display.isEmpty || JSText.contains(display, "@") || JSText.same(display.lowercased(), normalized) {
            return Label(primary: address, secondary: "")
        }
        return Label(primary: display, secondary: address)
    }
}

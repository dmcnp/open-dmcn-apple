import Foundation

// The display formatters. Parity with the browser's lib/format.ts. Messages carry unix seconds, and
// the viewer's locale decides the rendering. Dates go through the same ICU skeletons Intl uses.

/// The formatters behind a list's date column, kept so a long list makes them once.
struct WhenFormatter {
    private let day: DateFormatter
    private let dayInOtherYear: DateFormatter
    private let time: DateFormatter
    private let calendar: Calendar

    init(locale: Locale, timeZone: TimeZone) {
        day = Self.formatter("MMMd", locale, timeZone)
        dayInOtherYear = Self.formatter("MMMdyy", locale, timeZone)
        time = Self.timeFormatter(locale, timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    static func formatter(_ template: String, _ locale: Locale, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// `hour: 'numeric'`: the browser writes 1:00 where the same skeleton here pads to 01:00.
    static func timeFormatter(_ locale: Locale, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = formatter("jmm", locale, timeZone)
        formatter.dateFormat = formatter.dateFormat.replacingOccurrences(of: "HH", with: "H")
        return formatter
    }

    /// ICU separates "9:41" from "AM" with a narrow no-break space; browsers turned that back into a
    /// plain one for pages that compare the text, so this does too.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func string(_ seconds: Int64, now: Date) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        if calendar.isDate(date, inSameDayAs: now) { return Self.plain(time.string(from: date)) }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return Self.plain((sameYear ? day : dayInOtherYear).string(from: date))
    }
}

extension MailView {
    /// An actual byte count, in binary units with binary labels. The storage meter reports against a
    /// ceiling provisioned in binary, so it must never say the marketed "GB", and attachments use
    /// the same function so the client has one notion of size.
    public static func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        let units = ["KiB", "MiB", "GiB", "TiB"]
        var divisor = 1024
        var unit = 0
        while Double(n) / Double(divisor) >= 1024, unit < units.count - 1 {
            divisor *= 1024
            unit += 1
        }
        let value = Double(n) / Double(divisor)
        if value >= 100 || n % divisor == 0 {
            return "\(Int((value + 0.5).rounded(.down))) \(units[unit])"
        }
        // toFixed rounds an exact half up, where printf rounds it to even: 1280 bytes is 1.3 KiB,
        // not 1.2. In integers, since 1.25 is exact in binary and a tie really does happen.
        let tenths = (n * 20 + divisor) / (2 * divisor)
        return "\(tenths / 10).\(tenths % 10) \(units[unit])"
    }

    /// The full date of a message ("Tue, Sep 3, 2026").
    public static func formatDate(_ seconds: Int64, locale: Locale = .current, timeZone: TimeZone = .current) -> String
    {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        return WhenFormatter.plain(WhenFormatter.formatter("EEEMMMdyyyy", locale, timeZone).string(from: date))
    }

    /// The wall-clock time of a message ("9:41 AM").
    public static func formatTime(_ seconds: Int64, locale: Locale = .current, timeZone: TimeZone = .current) -> String
    {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        return WhenFormatter.plain(WhenFormatter.timeFormatter(locale, timeZone).string(from: date))
    }

    /// The compact list-row stamp: the time today, "Sep 3" this year, "Sep 3, 25" before.
    public static func formatWhen(
        _ seconds: Int64, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        WhenFormatter(locale: locale, timeZone: timeZone).string(seconds, now: now)
    }
}

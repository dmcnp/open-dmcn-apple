import DMCNKit
import SwiftUI
import UniformTypeIdentifiers

/// Bytes on their way to the Files app: a backup, or an attachment.
struct FileDocumentData: FileDocument {
    static let readableContentTypes: [UTType] = [.data]
    let data: Data
    var filename = "file"

    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The label swatches the web offers. A label stores its colour as CSS, so one made anywhere
/// shows the same here.
enum LabelColor {
    static let choices = ["#ef4444", "#f59e0b", "#10b981", "#3b82f6", "#8b5cf6", "#ec4899", "#64748b"]

    static func color(_ css: String) -> Color {
        guard css.hasPrefix("#"), css.count == 7, let value = UInt32(css.dropFirst(), radix: 16) else {
            return .textMuted
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}

extension EmptyIcon {
    var designIcon: Icon {
        switch self {
        case .archive: .archive
        case .star: .star
        case .trash: .trash
        case .inbox: .inbox
        case .search: .search
        }
    }
}

extension ThemePreference {
    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

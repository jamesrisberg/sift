import Foundation
import UniformTypeIdentifiers

/// Coarse file kind used for filtering and icons.
public enum FileCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case image, video, audio, pdf, document, archive, app, code, folder, other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .pdf: "PDFs"
        case .document: "Documents"
        case .archive: "Archives"
        case .app: "Applications"
        case .code: "Code"
        case .folder: "Folders"
        case .other: "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .image: "photo"
        case .video: "film"
        case .audio: "music.note"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .archive: "archivebox"
        case .app: "app.gift"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .folder: "folder.fill"
        case .other: "doc"
        }
    }

    public static func from(utType: UTType?) -> FileCategory {
        guard let utType else { return .other }
        // Order matters: source code conforms to .text, and app bundles are directories.
        if utType.conforms(to: .applicationBundle) || utType.conforms(to: .application) { return .app }
        if utType.conforms(to: .image) { return .image }
        if utType.conforms(to: .movie) || utType.conforms(to: .video) { return .video }
        if utType.conforms(to: .audio) { return .audio }
        if utType.conforms(to: .pdf) { return .pdf }
        if utType.conforms(to: .sourceCode) || utType.conforms(to: .script) || utType.conforms(to: .json) { return .code }
        if utType.conforms(to: .presentation) || utType.conforms(to: .spreadsheet) || utType.conforms(to: .text)
            || utType.conforms(to: .rtf) || utType.identifier == "org.openxmlformats.wordprocessingml.document" { return .document }
        if utType.conforms(to: .archive) || utType.conforms(to: .gzip) || utType.conforms(to: .zip)
            || utType.conforms(to: .diskImage) { return .archive }
        if utType.conforms(to: .folder) || utType.conforms(to: .directory) { return .folder }
        return .other
    }

    public static func from(url: URL) -> FileCategory {
        from(utType: UTType(filenameExtension: url.pathExtension))
    }
}

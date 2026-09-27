import Foundation
import Observation
import CoreGraphics

/// One entry in a folder listing. A reference type so the browser can keep the same
/// object (and its thumbnail) across rescans; see `FileListMerger`.
@Observable
public final class FileItem: Identifiable {
    public let id: URL
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    /// Bundles such as .app or .rtfd: directories that behave like files.
    public let isPackage: Bool
    public let isHidden: Bool
    public private(set) var fileSize: Int64
    public private(set) var creationDate: Date?
    public private(set) var modificationDate: Date?
    public private(set) var contentType: String?
    public private(set) var category: FileCategory
    /// Finder tag names, in Finder's order.
    public private(set) var tagNames: [String]

    /// Quick Look thumbnail, filled in lazily by the UI. Cleared when the file changes.
    public var thumbnail: CGImage?

    /// Number of visible children for folders, computed lazily off the main thread by
    /// `loadFolderItemCount()`. nil until loaded, and reset when the folder changes.
    public private(set) var folderItemCount: Int?

    /// Folders the user can navigate into (packages open instead).
    public var isBrowsable: Bool { isDirectory && !isPackage }

    public static let resourceKeys: [URLResourceKey] = [
        .fileSizeKey, .totalFileAllocatedSizeKey, .creationDateKey, .contentModificationDateKey,
        .contentTypeKey, .isDirectoryKey, .isPackageKey, .isHiddenKey, .tagNamesKey,
    ]

    public init(url: URL) {
        let url = url.normalizedFileURL
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        self.id = url
        self.url = url
        self.name = url.lastPathComponent
        let isDir = values?.isDirectory ?? false
        let isPkg = values?.isPackage ?? false
        self.isDirectory = isDir
        self.isPackage = isPkg
        self.isHidden = values?.isHidden ?? url.lastPathComponent.hasPrefix(".")
        self.fileSize = Int64(values?.fileSize ?? 0)
        self.creationDate = values?.creationDate
        self.modificationDate = values?.contentModificationDate
        self.contentType = values?.contentType?.identifier
        self.tagNames = values?.tagNames ?? []
        if isDir && !isPkg {
            self.category = .folder
        } else {
            self.category = values?.contentType.map(FileCategory.from(utType:)) ?? FileCategory.from(url: url)
        }
    }

    // MARK: - Display

    /// "12 KB", "3 items", or "--" while a folder's count is still loading.
    /// Cheap: never touches the disk (DownloadDetox listed folder contents on every render).
    public var formattedSize: String {
        if isBrowsable {
            guard let count = folderItemCount else { return "--" }
            return count == 1 ? "1 item" : "\(count) items"
        }
        return Self.byteFormatter.string(fromByteCount: fileSize)
    }

    public var formattedDate: String {
        guard let date = modificationDate ?? creationDate else { return "Unknown" }
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // Shared formatters: creating one per call was a measurable cost when rendering grids.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    // MARK: - Lazy folder count

    /// Counts visible children on a background thread and caches the result.
    @MainActor
    public func loadFolderItemCount() async {
        guard isBrowsable, folderItemCount == nil else { return }
        let url = self.url
        let count = await Task.detached(priority: .utility) {
            (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ).count) ?? 0
        }.value
        folderItemCount = count
    }

    /// Forget the cached child count (e.g. when the watcher reports a change inside).
    public func invalidateFolderItemCount() { folderItemCount = nil }

    /// Copy metadata from a fresher scan of the same URL. Returns true if the file changed
    /// in a way that invalidates the thumbnail.
    @discardableResult
    public func update(from fresh: FileItem) -> Bool {
        // Tags live in an extended attribute and do not touch the modification date.
        if fresh.tagNames != tagNames { tagNames = fresh.tagNames }
        let changed = fresh.modificationDate != modificationDate || fresh.fileSize != fileSize
        if changed {
            fileSize = fresh.fileSize
            modificationDate = fresh.modificationDate
            creationDate = fresh.creationDate
            contentType = fresh.contentType
            category = fresh.category
            thumbnail = nil
            folderItemCount = nil
        }
        return changed
    }
}

extension FileItem: Hashable {
    public static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

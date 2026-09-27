import Foundation

/// Lists folder contents as `FileItem`s.
public struct FileScanner: Sendable {
    public struct Options: Sendable, Equatable {
        public var includeHidden: Bool
        /// 0 lists only the folder's direct children. n > 0 also descends n levels into
        /// subfolders (packages are never descended into).
        public var depth: Int

        public init(includeHidden: Bool = false, depth: Int = 0) {
            self.includeHidden = includeHidden
            self.depth = depth
        }

        public static let shallow = Options()
        public static func recursive(depth: Int, includeHidden: Bool = false) -> Options {
            Options(includeHidden: includeHidden, depth: depth)
        }
    }

    public init() {}

    public func scan(_ directory: URL, options: Options = .shallow) throws -> [FileItem] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: directory])
        }
        var enumOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.includeHidden { enumOptions.insert(.skipsHiddenFiles) }
        if options.depth == 0 { enumOptions.insert(.skipsSubdirectoryDescendants) }

        // Enumerators report canonical paths (/tmp -> /private/tmp). Map results back under
        // the directory the caller asked for so URLs compare equal to the caller's.
        let requested = directory.normalizedFileURL
        let canonical = directory.canonicalPath
        let prefix = canonical == "/" ? "/" : canonical + "/"

        // FileManager's enumerator swallows errors unless given a handler, so an unreadable
        // folder (permissions, privacy protection) used to look merely empty. Fail loudly
        // for the folder itself; skip unreadable subfolders in recursive scans.
        var rootError: Error?
        guard let enumerator = fm.enumerator(
            at: directory, includingPropertiesForKeys: FileItem.resourceKeys, options: enumOptions,
            errorHandler: { url, error in
                if url.canonicalPath == canonical { rootError = error; return false }
                return true
            }
        ) else { return [] }

        var items: [FileItem] = []
        for case let found as URL in enumerator {
            var url = found
            let path = found.normalizedFileURL.path(percentEncoded: false)
            if path.hasPrefix(prefix) {
                url = requested.appending(path: String(path.dropFirst(prefix.count)), directoryHint: .notDirectory)
            }
            // `level` is 1 for direct children.
            if options.depth > 0, enumerator.level > options.depth {
                enumerator.skipDescendants()
            }
            items.append(FileItem(url: url))
        }
        if let rootError { throw rootError }
        return items
    }

    public static var downloadsURL: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")
    }
}

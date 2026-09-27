import Foundation

/// Name search through a folder tree, breadth first (shallow matches come first), bounded
/// by depth and result count, cancellable. Packages are matched but never descended into.
public struct RecursiveSearch: Sendable {
    public struct Options: Sendable, Equatable {
        /// 1 searches only the folder's direct children.
        public var maxDepth: Int
        public var includeHidden: Bool
        /// Stop after this many matches.
        public var limit: Int

        public init(maxDepth: Int = 8, includeHidden: Bool = false, limit: Int = 2_000) {
            self.maxDepth = maxDepth
            self.includeHidden = includeHidden
            self.limit = limit
        }
    }

    public struct Result: Sendable {
        public var urls: [URL]
        /// True when the limit was hit or depth-bounded folders were left unsearched.
        public var truncated: Bool
    }

    public init() {}

    /// Every whitespace-separated term of `query` appears in `name` (case and diacritic insensitive).
    public static func matches(_ name: String, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard !terms.isEmpty else { return false }
        return terms.allSatisfy { name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Synchronous search; checks `Task.isCancelled` between folders.
    public func search(_ root: URL, query: String, options: Options = Options()) throws -> Result {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        var enumOptions: FileManager.DirectoryEnumerationOptions = []
        if !options.includeHidden { enumOptions.insert(.skipsHiddenFiles) }

        var found: [URL] = []
        var truncated = false
        var level = [root.normalizedFileURL]
        var depth = 1
        while !level.isEmpty {
            var next: [URL] = []
            for dir in level {
                try Task.checkCancellation()
                // Unreadable subfolders are skipped; only the root itself must be readable.
                let children: [URL]
                do {
                    children = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: enumOptions)
                } catch {
                    if dir == root.normalizedFileURL { throw error }
                    continue
                }
                for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                    let url = dir.appending(path: child.lastPathComponent, directoryHint: .notDirectory)
                    if Self.matches(child.lastPathComponent, query: query) {
                        found.append(url)
                        if found.count >= options.limit { return Result(urls: found, truncated: true) }
                    }
                    let v = try? child.resourceValues(forKeys: Set(keys))
                    if v?.isDirectory == true, v?.isPackage != true, v?.isSymbolicLink != true {
                        next.append(url)
                    }
                }
            }
            if depth >= options.maxDepth {
                truncated = !next.isEmpty
                break
            }
            depth += 1
            level = next
        }
        return Result(urls: found, truncated: truncated)
    }

    /// Runs `search` off the main thread and returns `FileItem`s.
    public func items(in root: URL, query: String, options: Options = Options()) async throws -> (items: [FileItem], truncated: Bool) {
        let result = try await Task.detached(priority: .userInitiated) { [self] in
            try search(root, query: query, options: options)
        }.value
        try Task.checkCancellation()
        let items = await Task.detached(priority: .userInitiated) { result.urls.map(FileItem.init(url:)) }.value
        return (items, result.truncated)
    }
}

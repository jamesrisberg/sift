import Foundation

public extension URL {
    /// A file URL in one consistent form: standardized ("." and ".." removed), no
    /// trailing slash (except "/"), symlinks left alone. FileKit keys everything
    /// (items, selections, history) by this form so the same file always compares equal.
    var normalizedFileURL: URL {
        var path = standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return URL(filePath: path, directoryHint: .notDirectory)
    }

    /// The fully resolved path (symlinks followed, including /var -> /private/var, which
    /// `resolvingSymlinksInPath()` strips instead). Matches what FSEvents and
    /// FileManager enumerators report.
    var canonicalPath: String {
        let path = normalizedFileURL.path(percentEncoded: false)
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Same file-system location, ignoring trailing slashes and "." segments.
    func isSameFile(as other: URL) -> Bool {
        normalizedFileURL == other.normalizedFileURL
    }

    /// The containing folder, normalized.
    var parentFolder: URL { normalizedFileURL.deletingLastPathComponent().normalizedFileURL }
}

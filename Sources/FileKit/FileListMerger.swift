import Foundation

/// Merge-on-rescan: reuse existing `FileItem` objects for URLs that are still present
/// so thumbnails and folder counts survive a refresh (lifted from DownloadDetox's
/// `DownloadsViewModel.loadFiles`, plus change detection).
public enum FileListMerger {
    public struct Result {
        /// The merged list in scan order, reusing existing objects where possible.
        public var items: [FileItem]
        /// Items that were not in the previous listing (need thumbnails).
        public var added: [FileItem]
        /// URLs that disappeared.
        public var removed: [URL]
        /// Existing items whose size or modification date changed (thumbnail cleared).
        public var changed: [FileItem]
    }

    public static func merge(existing: [FileItem], scanned: [FileItem]) -> Result {
        var byURL: [URL: FileItem] = [:]
        for item in existing { byURL[item.url] = item }

        var merged: [FileItem] = []
        var added: [FileItem] = []
        var changed: [FileItem] = []
        merged.reserveCapacity(scanned.count)
        var seen = Set<URL>()

        for fresh in scanned {
            guard seen.insert(fresh.url).inserted else { continue }
            if let old = byURL[fresh.url] {
                if old.update(from: fresh) { changed.append(old) }
                merged.append(old)
            } else {
                merged.append(fresh)
                added.append(fresh)
            }
        }
        let removed = existing.map(\.url).filter { !seen.contains($0) }
        return Result(items: merged, added: added, removed: removed, changed: changed)
    }
}

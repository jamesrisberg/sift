import Foundation

/// Pure decisions behind drag and drop, kept out of the view layer so they can be tested.
public enum DragDrop {
    /// URLs a drag starting on `item` should carry: the whole selection in display order if
    /// the item is selected, otherwise just the item. (DownloadDetox could only drag one.)
    public static func dragURLs(startingAt item: URL, selection: Set<URL>, displayOrder: [URL]) -> [URL] {
        guard selection.contains(item), selection.count > 1 else { return [item] }
        // Display order; selected items filtered out of view are not dragged.
        return displayOrder.filter { selection.contains($0) }
    }

    public enum Mode: Sendable { case move, copy }

    /// Filters dropped URLs down to the ones that should be moved or copied into
    /// `destination`: drops items already in it (for moves), the destination itself, and any
    /// ancestor of it (a folder cannot go inside itself). Uses path components, fixing the
    /// string-prefix check that treated "/a/foo" as inside "/a/fo".
    public static func plan(dropping urls: [URL], into destination: URL, mode: Mode) -> [URL] {
        let dest = destination.normalizedFileURL
        var seen = Set<URL>()
        return urls.filter { url in
            let u = url.normalizedFileURL
            guard seen.insert(u).inserted else { return false }
            if u == dest { return false }
            if FileActionService.isAncestor(u, of: dest) { return false }
            if mode == .move, u.parentFolder == dest { return false }
            return true
        }
    }
}

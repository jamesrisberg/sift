import Foundation

/// A completed file-system change, recorded with enough information to reverse it.
///
/// Every case has an inverse that is itself a `FileOperation`, so undo and redo are the
/// same mechanism: execute the inverse, record what actually happened, and keep that on
/// the opposite stack.
public enum FileOperation: Equatable, Sendable {
    /// Moved `from` to `to` (different folder, or both).
    case move(from: URL, to: URL)
    /// Renamed in place; kept separate from `.move` for action names.
    case rename(from: URL, to: URL)
    /// Copied `source` to the new item `to` (also used for Duplicate).
    case copy(source: URL, to: URL)
    /// Moved `original` to the Trash, where it now lives at `trashed`.
    case trash(original: URL, trashed: URL)
    /// Moved `trashed` out of the Trash back to `original`.
    case putBack(trashed: URL, original: URL)
    /// Created an empty folder.
    case createFolder(URL)
    /// Removed an empty folder (the inverse of `createFolder`; refuses non-empty folders).
    case removeEmptyFolder(URL)
    /// Replaced the Finder tags of `url` (`from` is what it had before).
    case setTags(URL, from: [String], to: [String])

    /// The operation that reverses this one, before execution. For `.copy` the inverse
    /// trashes the copy rather than deleting it outright, so nothing is ever lost; its
    /// own inverse (`.putBack`) restores the copy.
    public var inverse: PlannedOperation {
        switch self {
        case let .move(from, to): .move(from: to, to: from)
        case let .rename(from, to): .rename(from: to, to: from)
        case let .copy(_, to): .trash(to)
        case let .trash(original, trashed): .putBack(trashed: trashed, original: original)
        case let .putBack(trashed, original): .trash(original, expectedTrashLocation: trashed)
        case let .createFolder(url): .removeEmptyFolder(url)
        case let .removeEmptyFolder(url): .createFolder(url)
        case let .setTags(url, from, _): .setTags(url, from)
        }
    }

    /// Where the affected item ends up after this operation, if it still exists.
    public var resultURL: URL? {
        switch self {
        case let .move(_, to), let .rename(_, to), let .copy(_, to): to
        case let .trash(_, trashed): trashed
        case let .putBack(_, original): original
        case let .createFolder(url): url
        case .removeEmptyFolder: nil
        case let .setTags(url, _, _): url
        }
    }

    /// Folders whose listings this operation changed (for targeted refreshes).
    public var touchedDirectories: Set<URL> {
        func parent(_ u: URL) -> URL { u.parentFolder }
        switch self {
        case let .move(a, b), let .rename(a, b), let .copy(a, b): return [parent(a), parent(b)]
        case let .trash(original, _): return [parent(original)]
        case let .putBack(_, original): return [parent(original)]
        case let .createFolder(u), let .removeEmptyFolder(u): return [parent(u)]
        case let .setTags(u, _, _): return [parent(u)]
        }
    }

    public var actionName: String {
        switch self {
        case .move: "Move"
        case .rename: "Rename"
        case .copy: "Copy"
        case .trash: "Move to Trash"
        case .putBack: "Put Back"
        case .createFolder: "New Folder"
        case .removeEmptyFolder: "Remove Folder"
        case .setTags: "Tag"
        }
    }
}

/// An operation to execute whose outcome (for example the Trash location) is not yet
/// known. `FileActionService.execute(_:)` turns it into a completed `FileOperation`.
/// Planned operations never overwrite: an occupied destination throws.
public enum PlannedOperation: Equatable, Sendable {
    case move(from: URL, to: URL)
    case rename(from: URL, to: URL)
    case copy(source: URL, to: URL)
    /// `expectedTrashLocation` is informational (the previous trash URL on redo).
    case trash(URL, expectedTrashLocation: URL? = nil)
    case putBack(trashed: URL, original: URL)
    case createFolder(URL)
    case removeEmptyFolder(URL)
    /// Set the item's Finder tags to exactly these names.
    case setTags(URL, [String])
}

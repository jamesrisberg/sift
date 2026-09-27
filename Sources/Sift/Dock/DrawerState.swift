import FileKit
import Foundation

/// Which folder the dock drawer shows. One drawer at a time: clicking the open tile again
/// closes it, clicking another tile swaps the contents in place.
struct DrawerState: Equatable {
    enum Transition: Equatable {
        /// Slide out showing this folder.
        case open(URL)
        /// Already out: show this folder instead, without moving.
        case swap(URL)
        /// Slide back in.
        case close
        case none
    }

    /// The tile folder the drawer was opened on (it may have navigated deeper since).
    private(set) var folder: URL?

    var isOpen: Bool { folder != nil }

    func isShowing(_ url: URL) -> Bool { folder == url.normalizedFileURL }

    /// A click on the tile for `url`.
    @discardableResult
    mutating func toggle(_ url: URL) -> Transition {
        let url = url.normalizedFileURL
        switch folder {
        case nil:
            folder = url
            return .open(url)
        case url:
            folder = nil
            return .close
        default:
            folder = url
            return .swap(url)
        }
    }

    /// Opens on `url` whatever is showing (e.g. from a context menu or `--drawer`).
    @discardableResult
    mutating func show(_ url: URL) -> Transition {
        let url = url.normalizedFileURL
        guard folder != url else { return .none }
        let wasOpen = isOpen
        folder = url
        return wasOpen ? .swap(url) : .open(url)
    }

    /// A click outside, Escape, a mode change or the strip moving.
    @discardableResult
    mutating func close() -> Transition {
        guard isOpen else { return .none }
        folder = nil
        return .close
    }
}

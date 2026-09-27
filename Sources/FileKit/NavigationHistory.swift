import Foundation

/// Back/forward history for a browser pane.
public struct NavigationHistory: Equatable, Sendable {
    public private(set) var current: URL
    public private(set) var backStack: [URL] = []
    public private(set) var forwardStack: [URL] = []
    public var limit: Int = 100

    public init(start: URL) { current = start.normalizedFileURL }

    public var canGoBack: Bool { !backStack.isEmpty }
    public var canGoForward: Bool { !forwardStack.isEmpty }

    /// Visit a new location; clears forward history. Visiting the current URL is a no-op.
    public mutating func visit(_ url: URL) {
        let url = url.normalizedFileURL
        guard url != current else { return }
        backStack.append(current)
        if backStack.count > limit { backStack.removeFirst(backStack.count - limit) }
        forwardStack.removeAll()
        current = url
    }

    @discardableResult
    public mutating func goBack() -> URL? {
        guard let prev = backStack.popLast() else { return nil }
        forwardStack.append(current)
        current = prev
        return prev
    }

    @discardableResult
    public mutating func goForward() -> URL? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        current = next
        return next
    }

    /// Replace the current location without adding history (e.g. the folder was renamed).
    public mutating func replaceCurrent(with url: URL) { current = url.normalizedFileURL }

    /// Breadcrumb trail from the volume root (or home, shown as "~") to `current`.
    public var breadcrumbs: [URL] { Self.breadcrumbs(for: current) }

    public static func breadcrumbs(for url: URL) -> [URL] {
        var crumbs: [URL] = []
        var u = url.normalizedFileURL
        while true {
            crumbs.append(u)
            let parent = u.parentFolder
            if parent == u { break }
            u = parent
        }
        return crumbs.reversed()
    }
}

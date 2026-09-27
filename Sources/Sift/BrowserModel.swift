import AppKit
import FileKit
import Observation

/// One browser pane: a location with history, its listing, selection and view options.
@Observable
@MainActor
final class BrowserModel: Identifiable {
    enum ViewMode: String { case grid, list }

    let id = UUID()
    /// The dock drawer's listing (cards, a shorter context menu), not a browser pane.
    let isDrawer: Bool
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored private let watcher = FileSystemWatcher(latency: 0.3)
    @ObservationIgnored private let scanner = FileScanner()
    @ObservationIgnored private var generation = 0

    private(set) var history: NavigationHistory
    private(set) var items: [FileItem] = []
    /// Filtered and sorted `items`, recomputed only when inputs change.
    private(set) var visible: [FileItem] = []
    private(set) var loadError: String?
    private(set) var isLoading = false

    var filter = FilterCriteria() {
        didSet {
            guard filter != oldValue else { return }
            if filter.searchText != oldValue.searchText { searchTextChanged() }
            refilter()
        }
    }
    var showHidden = false {
        didSet { if showHidden != oldValue { reload() } }
    }
    /// Where the search field looks: filter this folder, search subfolders, or Spotlight.
    var searchScope: SearchScope = .folder {
        didSet { if searchScope != oldValue { searchTextChanged() } }
    }

    /// Search results or a smart view shown instead of the folder listing. `current`
    /// stays the folder the pane was in, which is where it returns.
    private(set) var virtualView: VirtualView?
    /// A search or smart-view query is still gathering.
    private(set) var isSearching = false
    /// The search stopped at its depth or result limit.
    private(set) var resultsTruncated = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var spotlight: SpotlightQuery?
    @ObservationIgnored private var savedSort: (FilterCriteria.SortField, Bool)?

    var isVirtual: Bool { virtualView != nil }
    var viewMode: ViewMode = ViewMode(rawValue: AppEnvironment.defaults.string(forKey: "viewMode") ?? "") ?? .grid {
        didSet { AppEnvironment.defaults.set(viewMode.rawValue, forKey: "viewMode") }
    }
    var selection: Set<URL> = []
    var focus: URL?
    @ObservationIgnored var anchor: URL?
    /// Grid columns as laid out, for arrow-key movement.
    @ObservationIgnored var columns = 1
    /// Item whose name is being edited inline.
    var renaming: URL?
    /// Folder cell currently under a drag.
    var dropHighlight: URL?

    var current: URL { history.current }

    init(app: AppModel, start: URL, isDrawer: Bool = false) {
        self.app = app
        self.isDrawer = isDrawer
        self.history = NavigationHistory(start: start)
        load()
    }

    func stop() {
        watcher.stop()
        stopVirtualQueries()
    }

    // MARK: - Navigation

    /// Opens `url`, selecting `select` once the listing has loaded.
    func navigate(to url: URL, select: [URL] = []) {
        let url = url.normalizedFileURL
        if isVirtual { closeVirtualView(reload: url == current) }
        guard url != current else {
            if !select.isEmpty { reload(select: select) }
            return
        }
        history.visit(url)
        didChangeLocation(select: select)
    }

    func goBack() {
        // From search results or a smart view, Back returns to the folder.
        if isVirtual { return closeVirtualView() }
        let from = current
        if history.goBack() != nil { didChangeLocation(select: [from]) }
    }

    func goForward() {
        if isVirtual { closeVirtualView(reload: false) }
        if history.goForward() != nil { didChangeLocation(select: []) }
    }

    func goUp() {
        if isVirtual { closeVirtualView(reload: false) }
        let from = current
        let parent = current.parentFolder
        guard parent != current else { return }
        history.visit(parent)
        didChangeLocation(select: [from])
    }

    private func didChangeLocation(select: [URL]) {
        items = []
        visible = []
        selection = []
        focus = nil
        anchor = nil
        renaming = nil
        filter.searchText = ""
        load(select: select)
        app?.rememberLocation(current)
        app?.paneDidChange()
    }

    // MARK: - Loading

    private func load(select: [URL] = []) {
        startWatching()
        reload(select: select)
    }

    /// Rescans in the background and merges, keeping existing items (and thumbnails).
    /// `select` replaces the selection with those URLs once they appear.
    func reload(select: [URL] = []) {
        if isVirtual { return refreshVirtual(select: select) }
        generation += 1
        let gen = generation
        let dir = current
        let options = FileScanner.Options(includeHidden: showHidden)
        let scanner = self.scanner
        if items.isEmpty { isLoading = true }
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try scanner.scan(dir, options: options) }
            }.value
            guard gen == generation else { return }
            isLoading = false
            switch result {
            case let .success(scanned):
                loadError = nil
                let merged = FileListMerger.merge(existing: items, scanned: scanned)
                items = merged.items
                refilter()
                selectIfPresent(select)
            case let .failure(error):
                items = []
                visible = []
                loadError = error.localizedDescription
            }
            app?.paneDidChange()
        }
    }

    private func selectIfPresent(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let wanted = Set(urls.map(\.normalizedFileURL))
        let found = visible.map(\.url).filter { wanted.contains($0) }
        if !found.isEmpty {
            selection = Set(found)
            focus = found.first
            anchor = found.first
            app?.refreshPreviewIfNeeded()
        }
    }

    private func refilter() {
        var criteria = filter
        // Search results already match the query term by term; do not filter them again
        // by the whole string.
        if case .search = virtualView?.kind { criteria.searchText = "" }
        visible = criteria.apply(to: items)
        let shown = Set(visible.map(\.url))
        selection = selection.intersection(shown)
        if let f = focus, !shown.contains(f) { focus = nil }
        app?.refreshPreviewIfNeeded()
    }

    // MARK: - Search and smart views

    private func searchTextChanged() {
        searchTask?.cancel()
        let query = filter.searchText.trimmingCharacters(in: .whitespaces)
        // Smart views filter their results locally with the search field.
        if let view = virtualView, !view.isSearch { return }
        guard searchScope != .folder, !query.isEmpty else {
            if case .search = virtualView?.kind { closeVirtualView() }
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.runSearch(query)
        }
    }

    private func runSearch(_ query: String) {
        let root: URL
        if case let .search(_, _, previousRoot) = virtualView?.kind { root = previousRoot } else { root = current }
        stopVirtualQueries()
        enterVirtual(VirtualView(kind: .search(query: query, scope: searchScope, root: root)))
        let gen = generation
        switch searchScope {
        case .folder:
            return
        case .subfolders:
            let options = RecursiveSearch.Options(includeHidden: showHidden)
            searchTask = Task { [weak self] in
                do {
                    let result = try await RecursiveSearch().items(in: root, query: query, options: options)
                    guard let self, gen == self.generation else { return }
                    self.setResults(result.items, truncated: result.truncated)
                } catch is CancellationError {
                } catch {
                    guard let self, gen == self.generation else { return }
                    self.isSearching = false
                    self.loadError = error.localizedDescription
                }
            }
        case .spotlight:
            startSpotlight(SpotlightQuery(predicate: SpotlightQuery.nameContains(query), scopes: [root], limit: 1_000), gen: gen)
        }
    }

    /// Shows Recents or Large Files in this pane.
    func showSmartView(_ kind: VirtualView.Kind) {
        stopVirtualQueries()
        searchTask?.cancel()
        enterVirtual(VirtualView(kind: kind))
        // After entering, so clearing the field does not close the view again.
        filter.searchText = ""
        let gen = generation
        switch kind {
        case .recents:
            filter.sortBy = .modificationDate
            filter.sortAscending = false
            startSpotlight(SpotlightQuery(predicate: SpotlightQuery.recentlyUsed(days: 7),
                                          sortBy: [NSSortDescriptor(key: "kMDItemLastUsedDate", ascending: false)],
                                          limit: 300), gen: gen, skipFolders: true)
        case .largeFiles:
            filter.sortBy = .fileSize
            filter.sortAscending = false
            startSpotlight(SpotlightQuery(predicate: SpotlightQuery.largerThan(VirtualView.largeFileBytes),
                                          sortBy: [NSSortDescriptor(key: NSMetadataItemFSSizeKey, ascending: false)],
                                          limit: 300), gen: gen, skipFolders: true)
        case .search:
            break
        }
    }

    private func enterVirtual(_ view: VirtualView) {
        if virtualView == nil { savedSort = (filter.sortBy, filter.sortAscending) }
        generation += 1
        virtualView = view
        items = []
        visible = []
        selection = []
        focus = nil
        anchor = nil
        renaming = nil
        loadError = nil
        resultsTruncated = false
        isSearching = true
        app?.paneDidChange()
    }

    /// Leaves search results or a smart view and shows the folder again.
    func closeVirtualView(reload shouldReload: Bool = true) {
        guard virtualView != nil else { return }
        stopVirtualQueries()
        searchTask?.cancel()
        generation += 1
        virtualView = nil
        isSearching = false
        resultsTruncated = false
        if let (field, ascending) = savedSort {
            filter.sortBy = field
            filter.sortAscending = ascending
        }
        savedSort = nil
        if searchScope != .folder { filter.searchText = "" }
        items = []
        visible = []
        selection = []
        focus = nil
        anchor = nil
        if shouldReload { reload() }
        app?.paneDidChange()
    }

    private func startSpotlight(_ query: SpotlightQuery, gen: Int, skipFolders: Bool = false) {
        spotlight = query
        query.onResults = { [weak self] urls, _ in
            guard let self, gen == self.generation else { return }
            Task { [weak self] in
                let found = await Task.detached(priority: .userInitiated) {
                    urls.filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
                        .map(FileItem.init(url:))
                        .filter { !skipFolders || (!$0.isBrowsable && $0.url.pathExtension != "app") }
                }.value
                guard let self, gen == self.generation else { return }
                self.setResults(found, truncated: urls.count >= 300 && skipFolders)
            }
        }
        if !query.start() {
            isSearching = false
            loadError = "Spotlight search could not start."
        }
    }

    private func setResults(_ found: [FileItem], truncated: Bool, select: [URL] = []) {
        let merged = FileListMerger.merge(existing: items, scanned: found)
        items = merged.items
        resultsTruncated = truncated
        isSearching = false
        refilter()
        selectIfPresent(select)
        app?.paneDidChange()
    }

    /// After a file operation: re-run a subfolder search; Spotlight views update themselves,
    /// but drop items that no longer exist right away.
    private func refreshVirtual(select: [URL]) {
        guard let view = virtualView else { return }
        if case let .search(query, .subfolders, root) = view.kind {
            let gen = generation
            let options = RecursiveSearch.Options(includeHidden: showHidden)
            searchTask?.cancel()
            searchTask = Task { [weak self] in
                guard let result = try? await RecursiveSearch().items(in: root, query: query, options: options),
                      let self, gen == self.generation else { return }
                self.setResults(result.items, truncated: result.truncated, select: select)
            }
        } else {
            let still = items.filter { FileManager.default.fileExists(atPath: $0.url.path(percentEncoded: false)) }
            setResults(still, truncated: resultsTruncated, select: select)
        }
    }

    private func stopVirtualQueries() {
        spotlight?.stop()
        spotlight = nil
    }

    private func startWatching() {
        let dir = current
        watcher.start(watching: dir) { [weak self] events in
            guard let self, self.current == dir else { return }
            var needsReload = false
            for event in events {
                if event.affectsListing(of: dir) { needsReload = true }
                if let child = event.affectedChild(of: dir) {
                    self.items.first { $0.url == child }?.invalidateFolderItemCount()
                }
            }
            if needsReload { self.reload() }
        }
    }

    // MARK: - Selection

    var selectedURLs: [URL] { visible.map(\.url).filter { selection.contains($0) } }
    var selectedItems: [FileItem] { visible.filter { selection.contains($0.url) } }

    func click(_ item: FileItem, command: Bool, shift: Bool) {
        app?.activate(self)
        if shift, let anchor, let range = indexRange(anchor, item.url) {
            let urls = Set(visible[range].map(\.url))
            selection = command ? selection.union(urls) : urls
        } else if command {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
            anchor = item.url
        } else {
            selection = [item.url]
            anchor = item.url
        }
        focus = item.url
        app?.refreshPreviewIfNeeded()
    }

    func clearSelection() {
        selection = []
        focus = nil
        anchor = nil
        app?.refreshPreviewIfNeeded()
    }

    func selectAll() {
        selection = Set(visible.map(\.url))
        app?.refreshPreviewIfNeeded()
    }

    func moveFocus(_ direction: GridNavigation.Direction, extend: Bool) {
        let urls = visible.map(\.url)
        let cols = viewMode == .grid ? columns : 1
        let index = focus.flatMap { urls.firstIndex(of: $0) }
        guard let next = GridNavigation.move(from: index, direction, columns: cols, count: urls.count) else { return }
        let url = urls[next]
        if extend, let anchor, let range = indexRange(anchor, url) {
            selection = Set(urls[range])
        } else {
            selection = [url]
            anchor = url
        }
        focus = url
        app?.refreshPreviewIfNeeded()
    }

    private func indexRange(_ a: URL, _ b: URL) -> ClosedRange<Int>? {
        guard let i = visible.firstIndex(where: { $0.url == a }),
              let j = visible.firstIndex(where: { $0.url == b }) else { return nil }
        return min(i, j)...max(i, j)
    }

    // MARK: - Opening

    func open(_ item: FileItem) {
        if item.isBrowsable { navigate(to: item.url) } else { NSWorkspace.shared.open(item.url) }
    }

    /// Shows the item's folder with the item selected (from search results, or `reveal`).
    func reveal(_ url: URL) {
        navigate(to: url.parentFolder, select: [url])
    }

    /// Enter: a single folder navigates in; otherwise files open in their default apps.
    func openSelection() {
        let items = selectedItems
        if items.count == 1 { return open(items[0]) }
        for item in items where !item.isBrowsable { NSWorkspace.shared.open(item.url) }
    }

    /// Cmd-Down: enter the focused folder (or open the file).
    func enterSelection() {
        guard let item = selectedItems.first(where: { $0.url == focus }) ?? selectedItems.first else { return }
        open(item)
    }

    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls.isEmpty ? [current] : urls)
    }
}

enum SearchScope: String, CaseIterable, Identifiable {
    case folder = "This Folder"
    case subfolders = "Subfolders"
    case spotlight = "Spotlight"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .folder: "folder"
        case .subfolders: "folder.badge.gearshape"
        case .spotlight: "sparkle.magnifyingglass"
        }
    }
}

/// Something a pane shows instead of a folder listing.
struct VirtualView: Equatable {
    enum Kind: Equatable {
        case search(query: String, scope: SearchScope, root: URL)
        case recents
        case largeFiles
    }

    static let largeFileBytes: Int64 = 100_000_000

    var kind: Kind

    var isSearch: Bool { if case .search = kind { true } else { false } }

    var title: String {
        switch kind {
        case let .search(query, scope, root):
            scope == .spotlight ? "Spotlight: \u{201C}\(query)\u{201D} in \(root.lastPathComponent)"
                : "\u{201C}\(query)\u{201D} in \(root.lastPathComponent) and subfolders"
        case .recents: "Recents"
        case .largeFiles: "Large Files"
        }
    }

    var symbol: String {
        switch kind {
        case .search: "magnifyingglass"
        case .recents: "clock"
        case .largeFiles: "externaldrive"
        }
    }
}

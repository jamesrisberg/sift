import AppKit
import FileKit
import HUDKit
import Observation

/// App-wide state: panes, targets, the undo journal and its NSUndoManager bridge.
@Observable
@MainActor
final class AppModel {
    @ObservationIgnored let service = FileActionService()
    @ObservationIgnored let journal: UndoJournal
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored let thumbnails = ThumbnailGenerator()
    /// `SIFT_TARGETS_FILE` / `SIFT_HOME` point at another targets.json (see `AppEnvironment`).
    @ObservationIgnored let targetStore = TargetStore(fileURL: AppEnvironment.targetsURL)

    private(set) var panes: [BrowserModel] = []
    var activePaneIndex = 0
    var twoPane = false {
        didSet {
            configurePanes()
            AppEnvironment.defaults.set(twoPane, forKey: "twoPane")
        }
    }
    var targets: [Target] = [] {
        didSet { if targets != oldValue { onTargetsChange?() } }
    }
    /// Called when targets are added, removed, recoloured or reordered (the strip relays out).
    @ObservationIgnored var onTargetsChange: (() -> Void)?
    var collisionPolicy: CollisionPolicy {
        didSet { AppEnvironment.defaults.set(collisionPolicy.rawValue, forKey: "collisionPolicy") }
    }
    /// Transient status line ("Moved 3 items to Documents").
    var status: StatusMessage?
    /// Bumped whenever the journal changes so undo/redo UI re-renders.
    var journalVersion = 0
    /// Bumped to ask the active pane's search field to take focus.
    var focusSearchRequest = 0
    /// The panel is the dock strip (MacHUD `panel mode compact`).
    var isCompact = false
    /// Where the dock strip sits (set by the panel controller, which persists it).
    var dockPosition: HUDDockPosition = .bottom
    var dockEdge: DockEdge { DockEdge(position: dockPosition) }
    /// The folder the dock drawer shows, if it is out.
    var drawer = DrawerState()
    /// The drawer's listing; exists while the drawer is out.
    private(set) var drawerPane: BrowserModel?
    /// Badge counts for the strip.
    /// The panel controller, for the strip and drawer to ask for mode and drawer changes.
    @ObservationIgnored weak var dock: DockActions?
    /// Bumped to ask the drawer's search field to take focus.
    var focusDrawerSearchRequest = 0
    /// A sheet shown over the browser.
    var sheet: Sheet?
    /// Folder opened at launch (MacHUD setting `defaultFolder`); nil reopens the last folder.
    var defaultFolder: URL? {
        didSet { AppEnvironment.defaults.set(defaultFolder?.path(percentEncoded: false), forKey: "defaultFolder") }
    }
    @ObservationIgnored private(set) var rules: RulesController!

    enum Sheet: Equatable {
        case rules
        case rename([URL])
    }

    struct StatusMessage: Equatable {
        let text: String
        let isError: Bool
        let id = UUID()
    }

    init() {
        journal = UndoJournal(service: service)
        undoManager.levelsOfUndo = 200
        collisionPolicy = AppEnvironment.defaults.string(forKey: "collisionPolicy")
            .flatMap(CollisionPolicy.init(rawValue:)) ?? .keepBoth
        func existing(_ url: URL?) -> URL? {
            url.flatMap { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) ? $0 : nil }
        }
        defaultFolder = existing(AppEnvironment.defaults.string(forKey: "defaultFolder").map { URL(filePath: $0) })
        let start = defaultFolder ?? existing(AppEnvironment.defaults.url(forKey: "lastFolder")) ?? FileScanner.downloadsURL
        panes = [BrowserModel(app: self, start: start)]
        do {
            targets = try targetStore.load()
        } catch {
            targets = []
            flash("Could not read targets.json: \(error.localizedDescription)", error: true)
        }
        journal.onChange = { [weak self] ops in self?.journalDidChange(ops) }
        if AppEnvironment.defaults.bool(forKey: "twoPane") { twoPane = true }
        rules = RulesController(app: self)
    }

    // MARK: - Control (MacHUD socket)

    /// Called when a pane's location, listing or view changes (for `state` events).
    @ObservationIgnored var onPaneStateChange: (() -> Void)?
    func paneDidChange() { onPaneStateChange?() }

    func navigateActivePane(to url: URL) {
        activePane.navigate(to: url)
    }

    /// Shows the item's folder in the active pane with the item selected.
    func reveal(_ url: URL) {
        activePane.reveal(url.normalizedFileURL)
    }

    /// A target by name (case-insensitive) or by its 1-based number.
    func target(named spec: String) -> Target? {
        if let n = Int(spec), targets.indices.contains(n - 1) { return targets[n - 1] }
        return targets.first { $0.name.caseInsensitiveCompare(spec) == .orderedSame }
    }

    @discardableResult
    func send(_ urls: [URL], to target: Target, copy: Bool = false) -> [FileOperation] {
        copy ? self.copy(urls, into: target.url) : move(urls, into: target.url)
    }

    var activePane: BrowserModel { panes[min(activePaneIndex, panes.count - 1)] }

    /// The browser panes plus the drawer's listing.
    var allPanes: [BrowserModel] { panes + (drawerPane.map { [$0] } ?? []) }

    // MARK: - Dock drawer

    /// Shows `url` in the drawer's listing, creating it on first use.
    func showInDrawer(_ url: URL) {
        if let pane = drawerPane {
            pane.filter = FilterCriteria()
            pane.navigate(to: url)
        } else {
            drawerPane = BrowserModel(app: self, start: url, isDrawer: true)
        }
    }

    /// Drops the drawer's listing (and its watcher) once the drawer is in.
    func releaseDrawerPane() {
        drawerPane?.stop()
        drawerPane = nil
    }

    /// The tile a folder belongs to, for the drawer's title and colour.
    func dockTitle(for url: URL) -> String {
        let url = url.normalizedFileURL
        if url == FileScanner.downloadsURL.normalizedFileURL { return "Downloads" }
        return targets.first { $0.url.normalizedFileURL == url }?.name ?? url.lastPathComponent
    }

    func dockColorHex(for url: URL) -> String {
        let url = url.normalizedFileURL
        if url == FileScanner.downloadsURL.normalizedFileURL { return Theme.downloadsHex }
        return targets.first { $0.url.normalizedFileURL == url }?.colorHex ?? Theme.downloadsHex
    }
    var otherPane: BrowserModel? { panes.count > 1 ? panes[activePaneIndex == 0 ? 1 : 0] : nil }

    func activate(_ pane: BrowserModel) {
        if let i = panes.firstIndex(where: { $0 === pane }) { activePaneIndex = i }
    }

    private func configurePanes() {
        if twoPane, panes.count == 1 {
            let target = targets.first(where: \.exists)?.url ?? panes[0].current
            panes.append(BrowserModel(app: self, start: target))
        } else if !twoPane, panes.count > 1 {
            panes[1].stop()
            panes.removeLast()
            activePaneIndex = 0
        }
    }

    func rememberLocation(_ url: URL) {
        if panes.first?.current == url { AppEnvironment.defaults.set(url, forKey: "lastFolder") }
    }

    /// Set by the panel controller to keep Quick Look in sync with the selection.
    @ObservationIgnored var onSelectionChange: (() -> Void)?
    func refreshPreviewIfNeeded() { onSelectionChange?() }

    // MARK: - Status

    func flash(_ text: String, error: Bool = false) {
        let message = StatusMessage(text: text, isError: error)
        status = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(error ? 6 : 3))
            if self?.status == message { self?.status = nil }
        }
    }

    // MARK: - Journaled operations

    /// Runs a file action, records whatever completed in the journal (even on partial
    /// failure), registers it with the undo manager, and reports errors in the status line.
    @discardableResult
    func perform(_ name: String? = nil, success: ((UndoJournal.Entry) -> String?)? = nil,
                 _ body: () throws -> [FileOperation]) -> [FileOperation] {
        var ops: [FileOperation] = []
        var failure: Error?
        do {
            ops = try body()
        } catch let error as FileActionError {
            // Keep the underlying reason: rebuilding the error with an empty message used to
            // leave only " (N earlier steps completed)" in the status line.
            if case let .partial(completed, _) = error { ops = completed }
            failure = error
        } catch {
            failure = error
        }
        if let entry = journal.record(ops, name: name) {
            undoManager.registerUndo(withTarget: self) { $0.undoStep() }
            undoManager.setActionName(entry.name)
            if failure == nil, let text = success?(entry) { flash(text) }
        }
        if let failure {
            let text: String
            if case let FileActionError.partial(_, underlying) = failure, !underlying.isEmpty {
                text = underlying
            } else {
                text = failure.localizedDescription
            }
            flash(text, error: true)
        }
        return ops
    }

    func undo() {
        guard undoManager.canUndo else { return flash("Nothing to undo") }
        let name = undoManager.undoActionName
        undoManager.undo()
        flash("Undid \(name)")
    }

    func redo() {
        guard undoManager.canRedo else { return flash("Nothing to redo") }
        let name = undoManager.redoActionName
        undoManager.redo()
        flash("Redid \(name)")
    }

    var canUndo: Bool { _ = journalVersion; return journal.canUndo }
    var canRedo: Bool { _ = journalVersion; return journal.canRedo }

    // Called by NSUndoManager. Registering the opposite action while undoing/redoing puts
    // it on the other stack, keeping NSUndoManager and the journal in lockstep.
    private func undoStep() {
        do {
            let entry = try journal.undo()
            undoManager.registerUndo(withTarget: self) { $0.redoStep() }
            if let entry { undoManager.setActionName(entry.name) }
        } catch {
            flash(error.localizedDescription, error: true)
            resyncUndoManager()
        }
    }

    private func redoStep() {
        do {
            let entry = try journal.redo()
            undoManager.registerUndo(withTarget: self) { $0.undoStep() }
            if let entry { undoManager.setActionName(entry.name) }
        } catch {
            flash(error.localizedDescription, error: true)
            resyncUndoManager()
        }
    }

    /// After a failed undo/redo the stacks may differ; rebuild NSUndoManager from the
    /// journal's undo stack (redo history is dropped on both sides).
    private func resyncUndoManager() {
        DispatchQueue.main.async { [self] in
            undoManager.removeAllActions()
            journal.discardRedo()
            for entry in journal.undoStack {
                undoManager.registerUndo(withTarget: self) { $0.undoStep() }
                undoManager.setActionName(entry.name)
            }
            journalVersion += 1
        }
    }

    private func journalDidChange(_ ops: [FileOperation]) {
        journalVersion += 1
        let touched = ops.reduce(into: Set<URL>()) { $0.formUnion($1.touchedDirectories) }
        let results = ops.compactMap(\.resultURL)
        for pane in allPanes where pane.isVirtual || touched.contains(pane.current) {
            pane.reload(select: pane.isVirtual ? results : results.filter { $0.parentFolder == pane.current })
        }
    }

    // MARK: - Actions on URLs

    @discardableResult
    func move(_ urls: [URL], into folder: URL) -> [FileOperation] {
        let plan = DragDrop.plan(dropping: urls, into: folder, mode: .move)
        guard !plan.isEmpty else { return [] }
        return perform(success: { entry in
            "Moved \(Self.count(entry.operations, .move)) to \(folder.lastPathComponent)"
        }) {
            try service.move(plan, into: folder, onCollision: collisionPolicy)
        }
    }

    @discardableResult
    func copy(_ urls: [URL], into folder: URL) -> [FileOperation] {
        let plan = DragDrop.plan(dropping: urls, into: folder, mode: .copy)
        guard !plan.isEmpty else { return [] }
        return perform(success: { entry in
            "Copied \(Self.count(entry.operations, .copy)) to \(folder.lastPathComponent)"
        }) {
            try service.copy(plan, into: folder, onCollision: collisionPolicy)
        }
    }

    func drop(_ urls: [URL], into folder: URL, copy: Bool) {
        _ = copy ? self.copy(urls, into: folder) : move(urls, into: folder)
    }

    func trash(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        perform(success: { entry in "Moved \(Self.count(entry.operations, .trash)) to the Trash" }) {
            try service.trash(urls)
        }
    }

    func duplicate(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        perform("Duplicate") { try service.duplicate(urls) }
    }

    func rename(_ url: URL, to name: String) {
        perform { try service.rename(url, to: name).map { [$0] } ?? [] }
    }

    /// Creates "untitled folder" and starts renaming it.
    func newFolder(in pane: BrowserModel) {
        let ops = perform { [try service.newFolder(in: pane.current)] }
        if let url = ops.first?.resultURL {
            pane.reload(select: [url])
            pane.renaming = url
        }
    }

    func send(toTarget index: Int) {
        guard targets.indices.contains(index) else { return }
        let target = targets[index]
        let urls = activePane.selectedURLs
        guard !urls.isEmpty else { return flash("Select files to send to \(target.name)") }
        guard target.exists else { return flash("\(target.name) no longer exists", error: true) }
        move(urls, into: target.url)
    }

    // MARK: - Tags and batch rename

    /// Tag names offered in menus: the standard Finder tags plus any used in visible panes.
    var knownTags: [String] {
        var names = FileTags.standard.map(\.name)
        var seen = Set(names)
        for pane in panes {
            for item in pane.items {
                for tag in item.tagNames where seen.insert(tag).inserted { names.append(tag) }
            }
        }
        return names
    }

    /// Adds the tag to every item, or removes it when all of them already have it.
    func toggleTag(_ tag: String, on urls: [URL]) {
        guard !urls.isEmpty else { return }
        perform(success: { entry in
            "\(entry.operations.count == 1 ? "1 item" : "\(entry.operations.count) items"): \(tag)"
        }) { try service.toggleTag(tag, on: urls) }
    }

    func clearTags(_ urls: [URL]) {
        perform("Remove Tags") { try service.setTags(urls) { _ in [] } }
    }

    func beginBatchRename(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        sheet = .rename(urls)
    }

    /// Applies a batch rename as one undoable group.
    func batchRename(_ pairs: [(URL, String)]) {
        let count = pairs.filter { $0.0.lastPathComponent != $0.1 }.count
        guard count > 0 else { return }
        perform(count == 1 ? "Rename" : "Rename \(count) Items",
                success: { _ in "Renamed \(count == 1 ? "1 item" : "\(count) items")" }) {
            try service.renameBatch(pairs)
        }
    }

    func sendToOtherPane(copy: Bool) {
        guard let other = otherPane else { return }
        drop(activePane.selectedURLs, into: other.current, copy: copy)
    }

    // MARK: - Pasteboard

    func copyToPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        flash("Copied \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")")
    }

    /// Cmd-V copies pasteboard files here; Option-Cmd-V moves them (Finder's convention).
    func paste(into folder: URL, move: Bool) {
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        drop(urls, into: folder, copy: !move)
    }

    // MARK: - Targets

    func addTarget(_ url: URL) {
        let url = url.normalizedFileURL
        guard !targets.contains(where: { $0.url == url }) else { return flash("\(url.lastPathComponent) is already a target") }
        let color = Target.palette[targets.count % Target.palette.count]
        targets.append(Target(name: url.lastPathComponent, colorHex: color, url: url))
        saveTargets()
    }

    func removeTarget(_ target: Target) {
        targets.removeAll { $0.id == target.id }
        saveTargets()
    }

    func cycleColor(_ target: Target) {
        guard let i = targets.firstIndex(of: target) else { return }
        let next = ((Target.palette.firstIndex(of: target.colorHex) ?? -1) + 1) % Target.palette.count
        targets[i].colorHex = Target.palette[next]
        saveTargets()
    }

    func moveTargets(from source: IndexSet, to destination: Int) {
        targets.move(fromOffsets: source, toOffset: destination)
        saveTargets()
    }

    /// Asks for a folder and adds it as a target.
    func chooseTarget() {
        let open = NSOpenPanel()
        open.title = "Add a Target"
        open.prompt = "Add"
        open.canChooseFiles = false
        open.canChooseDirectories = true
        open.canCreateDirectories = true
        open.allowsMultipleSelection = true
        NSApp.activate()
        guard open.runModal() == .OK else { return }
        for url in open.urls { addTarget(url) }
    }

    private func saveTargets() {
        do { try targetStore.save(targets) } catch {
            flash("Could not save targets: \(error.localizedDescription)", error: true)
        }
    }

    private enum Kind { case move, copy, trash }
    private static func count(_ ops: [FileOperation], _ kind: Kind) -> String {
        let n = ops.filter {
            switch ($0, kind) {
            case (.move, .move), (.copy, .copy): true
            case (.trash, .trash): true
            default: false
            }
        }.count
        return n == 1 ? "1 item" : "\(n) items"
    }
}

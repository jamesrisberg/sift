import AppKit
import FileKit
import Observation

/// Owns rules.json, the live preview shown in the Rules sheet, and auto-apply on
/// watched folders. Every run goes through `AppModel.perform`, so it is one undo step.
@Observable
@MainActor
final class RulesController {
    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored let store = RuleStore(fileURL: AppEnvironment.rulesURL)

    private(set) var ruleSet = RuleSet()
    /// Set when rules.json could not be read; saving is refused so the file is not clobbered.
    private(set) var loadError: String?

    // Preview
    private(set) var previewFolder: URL?
    private(set) var plans: [PlannedRuleAction] = []
    /// Planned steps the user unticked.
    var excluded: Set<URL> = []
    private(set) var isEvaluating = false
    @ObservationIgnored private var previewGeneration = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    // Auto-apply
    @ObservationIgnored private let watcher = FileSystemWatcher(latency: 1.0)
    @ObservationIgnored private var pending: Set<URL> = []
    @ObservationIgnored private var autoTask: Task<Void, Never>?
    /// Items auto-apply already produced, so a rename rule cannot keep re-matching its own output.
    @ObservationIgnored private var processed: Set<URL> = []

    init(app: AppModel) {
        self.app = app
        reload()
    }

    var engine: RuleEngine { RuleEngine(rules: ruleSet.rules, targets: app?.targets ?? []) }

    /// Rereads rules.json (the sheet calls this when it opens, so hand edits show up).
    func reload() {
        do {
            ruleSet = try store.load()
            loadError = nil
        } catch {
            loadError = "rules.json could not be read: \(error.localizedDescription)"
        }
        restartWatching()
    }

    // MARK: - Editing

    func update(_ change: (inout RuleSet) -> Void) {
        let before = ruleSet
        change(&ruleSet)
        guard ruleSet != before else { return }
        scheduleSave()
        if ruleSet.autoApply != before.autoApply || ruleSet.watch != before.watch { restartWatching() }
        if let folder = previewFolder { refreshPreview(in: folder, debounce: true) }
    }

    func updateRule(_ id: UUID, _ change: (inout Rule) -> Void) {
        update { set in
            if let i = set.rules.firstIndex(where: { $0.id == id }) { change(&set.rules[i]) }
        }
    }

    @discardableResult
    func addRule() -> UUID {
        let folder = app?.activePane.current
        let rule = Rule(name: "New Rule", enabled: true,
                        match: RuleMatch(extensions: ["dmg", "pkg"], minAgeDays: 7,
                                         folders: folder.map { [RulePaths.string($0)] }),
                        action: .trash)
        update { $0.rules.append(rule) }
        return rule.id
    }

    func removeRule(_ id: UUID) {
        update { $0.rules.removeAll { $0.id == id } }
    }

    func moveRule(_ id: UUID, by offset: Int) {
        update { set in
            guard let i = set.rules.firstIndex(where: { $0.id == id }) else { return }
            let j = i + offset
            guard set.rules.indices.contains(j) else { return }
            set.rules.swapAt(i, j)
        }
    }

    func setAutoApply(_ on: Bool) { update { $0.autoApply = on } }

    func addWatchFolder(_ url: URL) {
        let path = RulePaths.string(url)
        update { if !$0.watch.contains(path) { $0.watch.append(path) } }
    }

    func removeWatchFolder(_ path: String) { update { $0.watch.removeAll { $0 == path } } }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard loadError == nil else {
            app?.flash("Not saving rules: fix or remove rules.json first", error: true)
            return
        }
        do { try store.save(ruleSet) } catch {
            app?.flash("Could not save rules: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: - Preview and apply

    /// Evaluates the rules against the items in `folder` (shallow) off the main thread.
    func refreshPreview(in folder: URL, debounce: Bool = false) {
        previewGeneration += 1
        let gen = previewGeneration
        if previewFolder != folder { excluded = [] }
        previewFolder = folder
        isEvaluating = true
        let engine = self.engine
        let includeHidden = app?.activePane.showHidden ?? false
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            let plans = await Task.detached(priority: .userInitiated) {
                Self.plan(engine: engine, folder: folder, includeHidden: includeHidden)
            }.value
            guard let self, gen == self.previewGeneration else { return }
            self.plans = plans
            self.isEvaluating = false
        }
    }

    nonisolated static func plan(engine: RuleEngine, folder: URL, includeHidden: Bool, only: Set<URL>? = nil) -> [PlannedRuleAction] {
        let fm = FileManager.default
        var options: FileManager.DirectoryEnumerationOptions = []
        if !includeHidden { options.insert(.skipsHiddenFiles) }
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: options)) ?? []
        let subjects = urls
            .map { folder.appending(path: $0.lastPathComponent).normalizedFileURL }
            .filter { only?.contains($0) ?? true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(RuleSubject.init(url:))
        return engine.evaluate(subjects)
    }

    var selectedPlans: [PlannedRuleAction] { plans.filter { $0.problem == nil && !excluded.contains($0.id) } }

    /// Runs the ticked steps as one undoable group.
    func applySelected() {
        guard let app else { return }
        let chosen = selectedPlans
        guard !chosen.isEmpty else { return }
        let policy = app.collisionPolicy
        app.perform("Apply Rules", success: { entry in
            "Rules: \(entry.operations.count == 1 ? "1 change" : "\(entry.operations.count) changes")"
        }) {
            try RuleEngine.apply(chosen, service: app.service, onCollision: policy)
        }
        if let folder = previewFolder { refreshPreview(in: folder) }
    }

    // MARK: - Auto-apply

    private func restartWatching() {
        watcher.stop()
        pending = []
        guard ruleSet.autoApply else { return }
        let folders = ruleSet.watchURLs.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
        }
        guard !folders.isEmpty else { return }
        let canonical = Dictionary(folders.map { ($0.canonicalPath, $0) }, uniquingKeysWith: { a, _ in a })
        watcher.start(watching: folders) { [weak self] events in
            guard let self else { return }
            for event in events {
                // Only direct children that appeared or changed; folder-level events are ignored.
                let parent = (event.path as NSString).deletingLastPathComponent
                guard let folder = canonical[parent] else { continue }
                if event.flags.contains(.removed), !FileManager.default.fileExists(atPath: event.path) { continue }
                self.pending.insert(folder.appending(path: (event.path as NSString).lastPathComponent).normalizedFileURL)
            }
            self.scheduleAutoApply()
        }
    }

    private func scheduleAutoApply() {
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.runAutoApply()
        }
    }

    private static let partialExtensions: Set<String> = ["download", "crdownload", "part", "partial", "tmp", "opdownload"]

    private func runAutoApply() {
        guard let app, ruleSet.autoApply else { return }
        let now = Date()
        var ready: [URL] = []
        var later: Set<URL> = []
        for url in pending where !processed.contains(url) {
            let path = url.path(percentEncoded: false)
            guard FileManager.default.fileExists(atPath: path),
                  !Self.partialExtensions.contains(url.pathExtension.lowercased()) else { continue }
            // Still being written: try again on the next pass.
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, now.timeIntervalSince(modified) < 3 { later.insert(url); continue }
            ready.append(url)
        }
        pending = later
        if !later.isEmpty { scheduleAutoApply() }
        guard !ready.isEmpty else { return }

        let plans = engine.evaluate(ready.map(RuleSubject.init(url:))).filter { $0.problem == nil }
        guard !plans.isEmpty else { return }
        let ops = app.perform("Auto-Apply Rules", success: { entry in
            "Rules applied to \(entry.operations.count == 1 ? "1 item" : "\(entry.operations.count) items") (Cmd-Z to undo)"
        }) {
            try RuleEngine.apply(plans, service: app.service, onCollision: app.collisionPolicy)
        }
        for op in ops { if let url = op.resultURL { processed.insert(url.normalizedFileURL) } }
        if processed.count > 5_000 { processed.removeAll() }
    }
}

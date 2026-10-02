import AppKit
import FileKit
import HUDKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var panel: PanelController!
    private var statusItem: NSStatusItem!
    private var control: ControlHost!
    static let hotKey = HUDHotKey(key: "/", modifiers: ["option"])

    func applicationDidFinishLaunching(_ notification: Notification) {
        HUDEditMenu.install(appName: "Sift")
        model = AppModel()
        panel = PanelController(model: model)
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        // A `--snapshot` run only draws: no control socket (a running app owns that name), no
        // announcement, no hotkey, no menu bar item.
        let snapshotting = value("--snapshot") != nil
        control = ControlHost(model: model, panel: panel)
        if !snapshotting {
            control.start()
            setupStatusItem()
            // While MacHUD runs, its menu hosts this one and the icon hides (HUDKit menu bar consolidation).
            control.router.menuProvider = { [weak self] in self?.statusItem?.menu }
            // The `menuBar.consumed` opt-out lives in <data directory>/menubar.json, so it follows SIFT_HOME.
            HUDStatusItemPolicy.attach(statusItem, appID: control.manifest.id, store: .home(AppEnvironment.dataDirectory))
            if AppEnvironment.hotKeysEnabled,
               HUDHotKeyCenter.shared.register(Self.hotKey, onPress: { [weak self] in self?.panel.toggle() }) == nil {
                model.flash("Option-/ is taken by another app; use the menu bar icon", error: true)
            }
        }
        // `--open <folder>`: start there (used with --snapshot).
        if let folder = value("--open") { model.navigateActivePane(to: RulePaths.url(folder)) }
        // `--search <query>`: start a subfolder search (used with --snapshot).
        if let query = value("--search") {
            model.activePane.viewMode = .list
            model.activePane.searchScope = .subfolders
            model.activePane.filter.searchText = query
        }
        // Show on launch so a first-time user sees something happen.
        panel.show()

        // `--snapshot <path.png>`: write a PNG of the panel after it settles (for docs and
        // for verifying the UI without Screen Recording permission). `--snapshot-mode
        // compact|full`, `--dock-position <position>`, `--drawer <folder>` (dock mode with
        // the drawer out) and `--snapshot-sheet rules|rename` pick what is pictured.
        if let path = value("--snapshot") {
            let drawerFolder = value("--drawer").map(RulePaths.url)
            switch value("--snapshot-mode") {
            case "compact": panel.setMode(.compact)
            case "full": panel.setMode(.full)
            default: if drawerFolder != nil { panel.setMode(.compact) }
            }
            if let position = value("--dock-position").flatMap(HUDDockPosition.init(rawValue:)) {
                panel.moveDock(to: position)
            }
            if let drawerFolder {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.panel.drawer.show(drawerFolder) }
            }
            let sheet = value("--snapshot-sheet")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                let pane = self.model.activePane
                switch sheet {
                case "rules":
                    self.model.sheet = .rules
                case "rename":
                    pane.selectAll()
                    self.model.beginBatchRename(pane.selectedURLs)
                default:
                    break
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.panel.writeSnapshot(to: URL(filePath: path))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel.withdrawDock()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel.show()
        return true
    }

    // MARK: - Status item

    private enum Tag: Int { case twoPane = 1, hidden, collision, compact }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = HUDStatusIcon.image(fallbackSymbol: "tray.full", accessibilityDescription: "Sift")

        let menu = NSMenu()
        menu.delegate = self
        let toggle = NSMenuItem(title: "Show Sift", action: #selector(togglePanel), keyEquivalent: "/")
        toggle.keyEquivalentModifierMask = [.option]
        menu.addItem(toggle)
        let compact = NSMenuItem(title: "Dock Mode", action: #selector(toggleCompact), keyEquivalent: "")
        compact.tag = Tag.compact.rawValue
        menu.addItem(compact)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Rules…", action: #selector(showRules), keyEquivalent: ""))
        menu.addItem(.separator())

        let two = NSMenuItem(title: "Two-Pane Mode", action: #selector(toggleTwoPane), keyEquivalent: "")
        two.tag = Tag.twoPane.rawValue
        menu.addItem(two)
        let hidden = NSMenuItem(title: "Show Hidden Files", action: #selector(toggleHidden), keyEquivalent: "")
        hidden.tag = Tag.hidden.rawValue
        menu.addItem(hidden)

        let collision = NSMenu()
        for policy in CollisionPolicy.allCases {
            let item = NSMenuItem(title: policy.menuTitle, action: #selector(setCollision(_:)), keyEquivalent: "")
            item.representedObject = policy.rawValue
            item.tag = Tag.collision.rawValue
            item.target = self
            collision.addItem(item)
        }
        let collisionItem = NSMenuItem(title: "When Names Collide", action: nil, keyEquivalent: "")
        collisionItem.submenu = collision
        menu.addItem(collisionItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reveal Targets File", action: #selector(revealTargets), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal Rules File", action: #selector(revealRules), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Sift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if item.tag == Tag.twoPane.rawValue { item.state = model.twoPane ? .on : .off }
            if item.tag == Tag.compact.rawValue { item.state = panel.mode == .compact ? .on : .off }
            if item.tag == Tag.hidden.rawValue { item.state = model.activePane.showHidden ? .on : .off }
            if item.action == #selector(togglePanel) { item.title = panel.isVisible ? "Hide Sift" : "Show Sift" }
            for sub in item.submenu?.items ?? [] where sub.tag == Tag.collision.rawValue {
                sub.state = (sub.representedObject as? String) == model.collisionPolicy.rawValue ? .on : .off
            }
        }
    }

    @objc private func togglePanel() { panel.toggle() }
    @objc private func toggleCompact() { panel.setMode(panel.mode == .compact ? .full : .compact) }
    @objc private func showRules() {
        if panel.mode != .full { panel.setMode(.full) }
        panel.show()
        model.sheet = .rules
    }
    @objc private func revealRules() {
        let url = model.rules.store.fileURL
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { model.rules.saveNow() }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    @objc private func toggleTwoPane() {
        model.twoPane.toggle()
        if panel.mode != .full { panel.setMode(.full) }
        panel.show()
    }
    @objc private func toggleHidden() {
        let value = !model.activePane.showHidden
        for pane in model.panes { pane.showHidden = value }
    }
    @objc private func setCollision(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let p = CollisionPolicy(rawValue: raw) {
            model.collisionPolicy = p
        }
        control.publishIfChanged()
    }
    @objc private func revealTargets() {
        NSWorkspace.shared.activateFileViewerSelecting([model.targetStore.fileURL])
    }
}

extension CollisionPolicy {
    var menuTitle: String {
        switch self {
        case .keepBoth: "Keep Both"
        case .replace: "Replace (old item goes to Trash)"
        case .skip: "Skip"
        }
    }
}

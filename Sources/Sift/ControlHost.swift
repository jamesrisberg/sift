import AppKit
import FileKit
import HUDKit

/// Sift's side of the MacHUD contract: serves the control socket at
/// `~/Library/Application Support/MacHUD/sockets/sift.sock` through HUDKit's router.
/// See docs/CONTRACT.md for the verbs.
@MainActor
final class ControlHost: HUDPanelHost {
    static let panelID = "browser"

    /// Used when running outside a bundle (e.g. `swift run`); mirrors Sources/Sift/Resources/machud.json.
    static let builtinManifest = HUDManifest(id: "xyz.machud.sift", name: "Sift", socket: "sift", panels: [
        HUDManifest.Panel(id: panelID, title: "Sift", symbol: "square.grid.2x2",
                          defaultSize: HUDSize(PanelController.fullSize), compactSize: HUDSize(PanelController.compactSize),
                          capabilities: ["acceptsFileDrop"],
                          verbs: ["show", "hide", "toggle", "frame", "mode", "navigate", "reveal", "send", "drop"],
                          settingsSchema: "settings.json", kind: .windowed, order: 1),
    ])

    let manifest: HUDManifest
    let server: HUDSocketServer
    private(set) var router: HUDControlRouter!
    private let model: AppModel
    private let panel: PanelController
    private var lastPublished: String?
    /// True while the router handles a `panel` command; it publishes `state` itself afterwards.
    private var routerWillPublish = false

    init(model: AppModel, panel: PanelController) {
        self.model = model
        self.panel = panel
        manifest = HUDManifest.main ?? Self.builtinManifest
        server = HUDSocketServer(path: HUDSocket.path(for: AppEnvironment.socketName), label: "sift.socket")
        router = HUDControlRouter(host: self, server: server, manifest: manifest)
    }

    func start() {
        router.install()
        if !server.start() { NSLog("Sift: control socket failed to start at %@", server.path) }
        panel.onStateChange = { [weak self] in self?.publishIfChanged() }
        model.onPaneStateChange = { [weak self] in self?.publishIfChanged() }
    }

    /// Pushes `state` to subscribers when anything they can see changed.
    func publishIfChanged() {
        let signature = panelStates.map { "\($0.visible)|\($0.mode)|\($0.badge ?? "")|\($0.status ?? "")" }.joined()
        guard signature != lastPublished else { return }
        lastPublished = signature
        if !routerWillPublish { router.publishState() }
    }

    /// Runs a panel change requested over the socket without publishing twice.
    private func routed(_ body: () throws -> Void) rethrows {
        routerWillPublish = true
        defer { routerWillPublish = false }
        try body()
    }

    // MARK: - HUDPanelHost

    var panelDescriptors: [HUDManifest.Panel] { manifest.panels }

    var panelStates: [HUDPanelState] {
        let pane = model.activePane
        let status = pane.virtualView?.title ?? RulePaths.string(pane.current)
        return [HUDPanelState(id: Self.panelID, visible: panel.isShown, mode: panel.mode,
                              badge: String(pane.items.count), status: status)]
    }

    private func check(_ id: String) throws {
        guard id == Self.panelID else { throw HUDControlError.noSuchPanel(id) }
    }

    func showPanel(_ id: String) throws { try check(id); routed { panel.show() } }
    func hidePanel(_ id: String) throws { try check(id); routed { panel.hide() } }

    /// MacHUD's dock: `from=` slides out of that edge, `reason=hover` fades in fast without focus.
    func showPanel(_ id: String, options: [String: String]) throws {
        try check(id)
        routed { panel.show(HUDPanelTransition(options)) }
    }

    /// `to=` slides back toward the dock, `reason=hover` fades out almost at once.
    func hidePanel(_ id: String, options: [String: String]) throws {
        try check(id)
        routed { panel.hide(HUDPanelTransition(options)) }
    }

    func setPanelFrame(_ id: String, frame: CGRect) throws {
        try check(id)
        guard frame.width >= 100, frame.height >= 40 else { throw HUDControlError.invalid("frame too small") }
        routed { panel.setFrame(frame) }
    }

    func setPanelMode(_ id: String, mode: HUDPanelMode) throws {
        try setPanelMode(id, mode: mode, options: HUDPanelModeOptions())
    }

    /// `parked` honours the edge/peek MacHUD passes (HUDKit 0.2) and remembers them.
    func setPanelMode(_ id: String, mode: HUDPanelMode, options: HUDPanelModeOptions) throws {
        try check(id)
        routed { panel.setMode(mode, options: options) }
    }

    // MARK: Settings

    func settings() -> [String: Any] {
        [
            "defaultFolder": model.defaultFolder.map(RulePaths.string) ?? "",
            "collisionPolicy": model.collisionPolicy.rawValue,
            "showHidden": model.activePane.showHidden,
            "rulesAutoApply": model.rules.ruleSet.autoApply,
            "launchMode": panel.launchMode.rawValue,
            "dock.position": model.dockPosition.rawValue,
        ]
    }

    func updateSettings(_ values: [String: String]) throws {
        // Validate everything before changing anything.
        var apply: [() -> Void] = []
        for (key, value) in values {
            switch key {
            case "defaultFolder":
                if value.isEmpty {
                    apply.append { self.model.defaultFolder = nil }
                } else {
                    let url = RulePaths.url(value)
                    guard Self.isDirectory(url) else { throw HUDControlError.invalid("defaultFolder: no folder at \(value)") }
                    apply.append { self.model.defaultFolder = url }
                }
            case "collisionPolicy":
                guard let policy = CollisionPolicy(rawValue: value) else {
                    throw HUDControlError.invalid("collisionPolicy must be one of \(CollisionPolicy.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                apply.append { self.model.collisionPolicy = policy }
            case "showHidden":
                let on = try Self.bool(value, key)
                apply.append { for pane in self.model.panes { pane.showHidden = on } }
            case "dock.position":
                guard let position = HUDDockPosition(rawValue: value) else {
                    throw HUDControlError.invalid("dock.position must be one of \(HUDDockPosition.menuOrder.map(\.rawValue).joined(separator: ", "))")
                }
                apply.append { self.panel.moveDock(to: position) }
            case "launchMode":
                guard let mode = LaunchMode(rawValue: value) else {
                    throw HUDControlError.invalid("launchMode must be one of \(LaunchMode.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                apply.append { self.panel.launchMode = mode }
            case "rulesAutoApply":
                let on = try Self.bool(value, key)
                apply.append { self.model.rules.setAutoApply(on) }
            default:
                throw HUDControlError.invalid("unknown setting \(key)")
            }
        }
        apply.forEach { $0() }
    }

    // MARK: Actions

    func performAction(_ name: String, args: [String: String], done: @escaping ([String: Any]) -> Void) {
        do {
            switch name {
            case "show", "hide", "toggle":
                // Action forms of the panel verbs; the router does not publish for actions.
                switch name {
                case "show": panel.show()
                case "hide": panel.hide()
                default: panel.isShown ? panel.hide() : panel.show()
                }
                done(["ok": true, "visible": panel.isShown])
            case "navigate":
                let url = try folder(args["path"])
                model.navigateActivePane(to: url)
                done(["ok": true, "path": url.path(percentEncoded: false)])
            case "reveal":
                guard let path = args["path"], !path.isEmpty else { throw HUDControlError.invalid("path= required") }
                let url = RulePaths.url(path)
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
                    throw HUDControlError.invalid("nothing at \(path)")
                }
                if panel.mode != .full { panel.setMode(.full) }
                model.reveal(url)
                panel.show()
                done(["ok": true, "path": url.path(percentEncoded: false)])
            case HUDDrop.action:
                // Files dropped on MacHUD's dock button (`acceptsFileDrop`): show where they are.
                let urls = HUDDrop.urls(from: args)
                guard !urls.isEmpty else { throw HUDControlError.invalid("drop needs paths=") }
                guard let plan = Self.dropReveal(urls) else {
                    throw HUDControlError.invalid("nothing at \(urls[0].path(percentEncoded: false))")
                }
                if panel.mode != .full { panel.setMode(.full) }
                model.activePane.navigate(to: plan.folder, select: plan.selected)
                panel.show()
                done(["ok": true, "folder": plan.folder.path(percentEncoded: false),
                      "selected": plan.selected.map { $0.path(percentEncoded: false) },
                      "skipped": urls.count - plan.selected.count])
            case "send":
                let urls = (args["path"] ?? args["paths"] ?? "").split(separator: ",").map { RulePaths.url(String($0)) }
                guard !urls.isEmpty else { throw HUDControlError.invalid("path= required") }
                if let missing = urls.first(where: { !FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }) {
                    throw HUDControlError.invalid("nothing at \(missing.path(percentEncoded: false))")
                }
                guard let spec = args["target"], let target = model.target(named: spec) else {
                    throw HUDControlError.invalid("target= must be a target name or number (1-\(model.targets.count))")
                }
                guard target.exists else { throw HUDControlError.invalid("\(target.name) no longer exists") }
                let copy = args["copy"] == "1" || args["copy"] == "true"
                let ops = model.send(urls, to: target, copy: copy)
                done(["ok": true, "target": target.name, "moved": ops.compactMap(\.resultURL).count,
                      "results": ops.compactMap { $0.resultURL?.path(percentEncoded: false) }])
            default:
                throw HUDControlError.invalid("unknown action \(name) (navigate, reveal, send, drop)")
            }
        } catch {
            done(["ok": false, "error": "\(error)"])
        }
    }

    /// Where a drop lands: the folder of the first dropped item that exists, with every dropped
    /// item in that same folder selected (one item: its folder with it selected). Items elsewhere
    /// or missing are skipped. nil when none exists.
    static func dropReveal(_ urls: [URL]) -> (folder: URL, selected: [URL])? {
        let existing = urls.map(\.normalizedFileURL).filter {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
        guard let first = existing.first else { return nil }
        let folder = first.parentFolder
        var seen = Set<URL>()
        let selected = existing.filter { $0.parentFolder == folder && seen.insert($0).inserted }
        return (folder, selected)
    }

    private func folder(_ path: String?) throws -> URL {
        guard let path, !path.isEmpty else { throw HUDControlError.invalid("path= required") }
        let url = RulePaths.url(path)
        guard Self.isDirectory(url) else { throw HUDControlError.invalid("no folder at \(path)") }
        return url
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }

    private static func bool(_ value: String, _ key: String) throws -> Bool {
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: throw HUDControlError.invalid("\(key) must be true or false")
        }
    }

    func quit() { NSApp.terminate(nil) }
}

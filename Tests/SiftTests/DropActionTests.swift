import AppKit
import FileKit
import HUDKit
@testable import Sift
import XCTest

/// `action drop paths=` (files dropped on MacHUD's dock button), driven through the router.
@MainActor
final class DropActionTests: XCTestCase {
    private static var home: URL = {
        // Isolate before anything reads AppEnvironment: no real rules, targets, socket or docks.json.
        let home = FileManager.default.temporaryDirectory.appending(path: "sift-drop-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SIFT_HOME", home.path, 1)
        setenv("SIFT_SOCKET", "sift-tests-\(getpid())", 1)
        setenv("SIFT_NO_HOTKEYS", "1", 1)
        return home
    }()

    private var suiteName = ""
    private var model: AppModel!
    private var panel: PanelController!
    private var host: ControlHost!
    private var dir: URL!

    override func setUp() async throws {
        _ = Self.home
        suiteName = "sift.tests.\(UUID().uuidString)"
        let memory = PanelMemory(defaults: UserDefaults(suiteName: suiteName)!)
        memory.launchMode = .full
        model = AppModel()
        panel = PanelController(model: model, memory: memory,
                                docks: HUDDockRegistry(url: Self.home.appending(path: "docks-\(suiteName).json")),
                                dockID: "xyz.sift.tests")
        host = ControlHost(model: model, panel: panel)
        dir = Self.home.appending(path: "files-\(UUID().uuidString)")
        for sub in ["a", "b"] {
            try FileManager.default.createDirectory(at: dir.appending(path: sub), withIntermediateDirectories: true)
        }
        for file in ["a/one two.txt", "a/three.txt", "a/four.txt", "b/five.txt"] {
            try Data("x".utf8).write(to: dir.appending(path: file))
        }
    }

    override func tearDown() async throws {
        panel?.panel.orderOut(nil)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: dir)
    }

    private func drop(_ urls: [URL]) -> [String: Any] {
        var out: [String: Any] = [:]
        host.router.handle("action", args: HUDDrop.args(for: urls).merging(["name": HUDDrop.action]) { a, _ in a }) { out = $0 }
        return out
    }

    private func settle(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    private func path(_ rel: String) -> URL { dir.appending(path: rel).normalizedFileURL }

    func testOneItemOpensItsFolderWithItSelected() {
        let r = drop([path("a/one two.txt")])
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        XCTAssertEqual(r["folder"] as? String, path("a").path(percentEncoded: false))
        XCTAssertEqual(r["selected"] as? [String], [path("a/one two.txt").path(percentEncoded: false)])
        XCTAssertTrue(panel.isShown)
        XCTAssertEqual(model.activePane.current, path("a"))
        settle { !model.activePane.selection.isEmpty }
        XCTAssertEqual(model.activePane.selection, [path("a/one two.txt")])
    }

    func testSeveralItemsSelectThoseSharingTheFirstItemsFolder() {
        let r = drop([path("a/three.txt"), path("b/five.txt"), path("a/four.txt"), path("a/gone.txt")])
        XCTAssertEqual(r["ok"] as? Bool, true, "\(r)")
        XCTAssertEqual(r["folder"] as? String, path("a").path(percentEncoded: false))
        XCTAssertEqual(r["selected"] as? [String], [path("a/three.txt"), path("a/four.txt")].map { $0.path(percentEncoded: false) })
        XCTAssertEqual(r["skipped"] as? Int, 2)
        XCTAssertEqual(model.activePane.current, path("a"))
        settle { model.activePane.selection.count == 2 }
        XCTAssertEqual(model.activePane.selection, [path("a/three.txt"), path("a/four.txt")])
    }

    func testTheFirstExistingItemPicksTheFolder() {
        let r = drop([path("a/gone.txt"), path("b/five.txt")])
        XCTAssertEqual(r["folder"] as? String, path("b").path(percentEncoded: false))
    }

    func testBareCLIFormAndErrors() {
        var out: [String: Any] = [:]
        let cli = HUDSocketClient.parseArguments(["drop", "paths=\(HUDDrop.encode([path("b/five.txt")]))"])
        host.router.handle("action", args: cli) { out = $0 }
        XCTAssertEqual(out["ok"] as? Bool, true, "\(out)")
        host.router.handle("action", args: ["name": "drop"]) { out = $0 }
        XCTAssertEqual(out["error"] as? String, "drop needs paths=")
        let missing = drop([path("nowhere.txt")])
        XCTAssertEqual(missing["ok"] as? Bool, false)
        XCTAssertEqual(missing["error"] as? String, "nothing at \(path("nowhere.txt").path(percentEncoded: false))")
    }

    func testManifestListsDropWithTheCapability() {
        let panel = ControlHost.builtinManifest.panels[0]
        XCTAssertTrue(panel.capabilities.contains(HUDDrop.capability))
        XCTAssertTrue(panel.verbs.contains(HUDDrop.action))
    }
}

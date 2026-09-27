import AppKit
import HUDKit
@testable import Sift
import XCTest

/// MacHUD's `panel show|hide` options (`from=`, `to=`, `anchor=`, `reason=`): the motion each
/// picks, and the real ControlHost + PanelController handling them.
@MainActor
final class PanelTransitionTests: XCTestCase {
    private static var home: URL = {
        // Isolate before anything reads AppEnvironment: no real rules, targets, socket or docks.json.
        let home = FileManager.default.temporaryDirectory.appending(path: "sift-transition-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("SIFT_HOME", home.path, 1)
        setenv("SIFT_SOCKET", "sift-tests-\(getpid())", 1)
        setenv("SIFT_NO_HOTKEYS", "1", 1)
        return home
    }()

    private var suiteName = ""
    private var panel: PanelController!
    private var host: ControlHost!

    override func setUp() async throws {
        _ = Self.home
        suiteName = "sift.tests.\(UUID().uuidString)"
        let memory = PanelMemory(defaults: UserDefaults(suiteName: suiteName)!)
        memory.launchMode = .full
        let model = AppModel()
        panel = PanelController(model: model, memory: memory,
                                docks: HUDDockRegistry(url: Self.home.appending(path: "docks-\(suiteName).json")),
                                dockID: "xyz.sift.tests")
        host = ControlHost(model: model, panel: panel)
    }

    override func tearDown() async throws {
        panel?.panel.orderOut(nil)
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func settle(_ seconds: TimeInterval = 0.5) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Choosing the motion

    func testHoverShowIsAQuickFadeWithoutFocus() {
        let t = HUDPanelTransition(["from": "bottom", "anchor": "100,0,48,48", "reason": "hover"])
        XCTAssertEqual(PanelMotion.show(t), PanelMotion(edge: nil, duration: 0.08))
        XCTAssertLessThanOrEqual(PanelMotion.show(t).duration, 0.1)
        XCTAssertFalse(PanelMotion.takesFocus(t))
    }

    func testFromSlidesOutOfThatEdge() {
        for (edge, reason) in [(HUDEdge.bottom, "click"), (.left, "summon"), (.top, "")] {
            let t = HUDPanelTransition(["from": edge.rawValue, "reason": reason])
            XCTAssertEqual(PanelMotion.show(t), PanelMotion(edge: edge, duration: HUDAnimation.revealDuration))
            XCTAssertTrue(PanelMotion.takesFocus(t))
        }
    }

    func testPlainShowAndHideFade() {
        XCTAssertEqual(PanelMotion.show(HUDPanelTransition()), PanelMotion(edge: nil, duration: HUDAnimation.revealDuration))
        XCTAssertEqual(PanelMotion.hide(HUDPanelTransition()), PanelMotion(edge: nil, duration: HUDAnimation.concealDuration))
        XCTAssertTrue(PanelMotion.takesFocus(HUDPanelTransition(["reason": "poke"])), "unknown reasons are plain shows")
    }

    func testHideTowardTheDock() {
        XCTAssertEqual(PanelMotion.hide(HUDPanelTransition(["to": "right"])), PanelMotion(edge: .right, duration: HUDAnimation.concealDuration))
        XCTAssertEqual(PanelMotion.hide(HUDPanelTransition(["to": "bottom", "reason": "hover"])), PanelMotion(edge: .bottom, duration: 0.1))
        XCTAssertEqual(PanelMotion.hide(HUDPanelTransition(["reason": "hover"])), PanelMotion(edge: nil, duration: 0.1))
    }

    // MARK: - The host

    func testShowFromAnEdgeLandsOnMacHUDsFrame() throws {
        let frame = CGRect(x: 200, y: 150, width: 900, height: 560)
        try host.setPanelFrame(ControlHost.panelID, frame: frame)
        try host.showPanel(ControlHost.panelID, options: ["from": "bottom", "anchor": "600,0,48,48", "reason": "click"])
        XCTAssertTrue(panel.isShown)
        XCTAssertTrue(panel.panel.isVisible)
        XCTAssertLessThan(panel.panel.frame.minY, frame.minY, "starts below, sliding up out of the dock")
        settle()
        XCTAssertEqual(panel.panel.frame, frame, "panel frame is respected")
        XCTAssertEqual(panel.panel.alphaValue, 1)
        XCTAssertEqual(host.panelStates.first?.visible, true)
    }

    func testHideTowardAnEdgeOrdersOutAndRestoresTheFrame() throws {
        let frame = CGRect(x: 240, y: 180, width: 900, height: 560)
        try host.setPanelFrame(ControlHost.panelID, frame: frame)
        try host.showPanel(ControlHost.panelID, options: [:])
        settle()
        try host.hidePanel(ControlHost.panelID, options: ["to": "bottom"])
        XCTAssertFalse(panel.isShown)
        settle()
        XCTAssertFalse(panel.panel.isVisible)
        XCTAssertEqual(panel.panel.frame, frame, "the next show starts from its rest frame")
        XCTAssertEqual(panel.panel.alphaValue, 1)
    }

    func testShowDuringAHideWins() throws {
        let frame = CGRect(x: 260, y: 200, width: 900, height: 560)
        try host.setPanelFrame(ControlHost.panelID, frame: frame)
        try host.showPanel(ControlHost.panelID, options: [:])
        settle()
        // The pointer leaves one dock button and comes straight back: hide, then show at once.
        try host.hidePanel(ControlHost.panelID, options: ["to": "bottom", "reason": "hover"])
        settle(0.03)
        try host.showPanel(ControlHost.panelID, options: ["from": "bottom", "reason": "hover"])
        settle()
        XCTAssertTrue(panel.isShown)
        XCTAssertTrue(panel.panel.isVisible, "the hide's completion must not order it out")
        XCTAssertEqual(panel.panel.alphaValue, 1)
        XCTAssertEqual(panel.panel.frame, frame, "back where it belongs, not part-way to the dock")

        // And a slide-in interrupted by a hide ends hidden, at its rest frame.
        try host.hidePanel(ControlHost.panelID, options: [:])
        try host.showPanel(ControlHost.panelID, options: ["from": "left"])
        try host.hidePanel(ControlHost.panelID, options: ["to": "left"])
        settle()
        XCTAssertFalse(panel.panel.isVisible)
        XCTAssertEqual(panel.panel.frame, frame)
    }

    func testHoverShowDoesNotTakeKeyboardFocus() throws {
        try host.showPanel(ControlHost.panelID, options: ["reason": "hover"])
        settle(0.2)
        XCTAssertTrue(panel.panel.isVisible)
        XCTAssertFalse(panel.panel.isKeyWindow)
    }

    func testUnknownPanelIsRejected() {
        XCTAssertThrowsError(try host.showPanel("nope", options: ["from": "top"])) { error in
            XCTAssertEqual(error as? HUDControlError, .noSuchPanel("nope"))
        }
        XCTAssertThrowsError(try host.hidePanel("nope", options: ["to": "top"]))
    }

    func testDockModeShowSlidesToTheStrip() throws {
        panel.setMode(.compact)
        settle()
        try host.hidePanel(ControlHost.panelID, options: [:])
        settle()
        try host.showPanel(ControlHost.panelID, options: ["from": "bottom", "reason": "click"])
        settle()
        XCTAssertEqual(panel.panel.frame, panel.stripFrame())
        XCTAssertEqual(panel.mode, .compact)
    }
}

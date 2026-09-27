import CoreGraphics
import Foundation
import HUDKit
@testable import Sift
import XCTest

/// The strip and drawer keep clear of the MacHUD dock, read from a `docks.json` like the one
/// MacHUD publishes (a fake file here).
final class DockAvoidanceTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private var dir: URL!
    private var registry: HUDDockRegistry!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "sift-docks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        registry = HUDDockRegistry(url: dir.appending(path: "docks.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Writes MacHUD's entry the way MacHUD would (a live pid, so it is not ignored as stale).
    private func writeMacHUD(position: String, frames: [[Double]], pid: Int32 = getpid()) throws {
        let json: [String: Any] = ["com.jrisberg.machud": [
            "position": position, "frames": frames, "updatedAt": "2026-09-26T12:00:00Z", "pid": pid,
        ]]
        try JSONSerialization.data(withJSONObject: json).write(to: registry.url)
    }

    private var others: [CGRect] { PanelController.frames(of: registry.others(than: "xyz.machud.sift")) }

    func testStripSlidesClearOfTheMacHUDDockOnTheSameEdge() throws {
        // MacHUD's bottom dock, centred: 400 wide at x 520...920.
        try writeMacHUD(position: "bottom", frames: [[520, 6, 400, 56]])
        XCTAssertEqual(others, [CGRect(x: 520, y: 6, width: 400, height: 56)])

        let layout = DockLayout.standard(position: .bottom, targetCount: 3)
        let ideal = layout.stripFrame(in: visible)
        XCTAssertTrue(ideal.intersects(others[0]), "both want the middle of the bottom edge")
        let placed = layout.stripFrame(in: visible, avoiding: others)
        XCTAssertFalse(placed.intersects(others[0].insetBy(dx: -DockLayout.dockGap + 0.5, dy: 0)), "never overlaps, gap kept")
        XCTAssertEqual(placed.minY, ideal.minY, "stays on its edge")
        XCTAssertEqual(placed.size, ideal.size)
        XCTAssertTrue(placed.maxX == 520 - DockLayout.dockGap || placed.minX == 920 + DockLayout.dockGap, "\(placed)")
        XCTAssertTrue(visible.insetBy(dx: 6, dy: 6).contains(placed))
    }

    func testDocksOnOtherEdgesDoNotMoveTheStrip() throws {
        try writeMacHUD(position: "left", frames: [[6, 300, 56, 300]])
        let layout = DockLayout.standard(position: .bottom, targetCount: 3)
        XCTAssertEqual(layout.stripFrame(in: visible, avoiding: others), layout.stripFrame(in: visible))
    }

    func testCornerStripStepsPastAnLShapedMacHUDDock() throws {
        // MacHUD in the top-left corner: an L whose vertical arm runs 300 pt down the left side.
        try writeMacHUD(position: "topLeft", frames: [[6, 569, 56, 300], [6, 813, 400, 56]])
        let layout = DockLayout.standard(position: .topLeft, targetCount: 3)
        let placed = layout.stripFrame(in: visible, avoiding: others)
        XCTAssertEqual(placed.minX, 6)
        XCTAssertLessThanOrEqual(placed.maxY, 569 - DockLayout.dockGap, "below MacHUD's arm")
        for frame in others { XCTAssertFalse(placed.intersects(frame)) }
    }

    func testStaleEntriesAreIgnored() throws {
        // A pid that cannot be running: MacHUD crashed and left its entry behind.
        try writeMacHUD(position: "bottom", frames: [[520, 6, 400, 56]], pid: 999_999)
        XCTAssertEqual(others, [])
    }

    func testOwnEntryIsNotAnObstacle() throws {
        try registry.publish(appID: "xyz.machud.sift", position: .bottom, frames: [CGRect(x: 558, y: 6, width: 324, height: 56)])
        XCTAssertEqual(others, [])
    }

    func testDrawerOpensAwayFromAnAdjacentMacHUDDock() throws {
        try writeMacHUD(position: "bottom", frames: [[520, 6, 400, 56]])
        let layout = DockLayout.standard(position: .bottom, targetCount: 3)
        let strip = layout.stripFrame(in: visible, avoiding: others)
        let drawer = layout.drawerFrame(strip: strip, in: visible, avoiding: others)
        if strip.minX > 920 {
            XCTAssertEqual(drawer.minX, strip.minX, "MacHUD on the left: the drawer runs right from the strip")
        } else {
            // MacHUD on the right: the drawer runs left from the strip (as far as the screen allows).
            XCTAssertEqual(drawer.minX, max(6, strip.maxX - drawer.width))
            XCTAssertLessThan(drawer.midX, strip.midX)
        }
        XCTAssertEqual(drawer.minY, strip.maxY + DockLayout.drawerGap)

        // Without a neighbour it is centred on the strip.
        let alone = layout.drawerFrame(strip: strip, in: visible, avoiding: [])
        XCTAssertEqual(alone.midX, strip.midX, accuracy: 0.5)
    }

    func testDrawerSlidesClearOfAnLArmBesideIt() throws {
        // MacHUD's bottom-left L: its vertical arm rises beside where the drawer would open.
        try writeMacHUD(position: "bottomLeft", frames: [[6, 6, 56, 500], [6, 6, 400, 56]])
        let layout = DockLayout.standard(position: .bottom, targetCount: 3)
        let strip = CGRect(x: 412, y: 6, width: layout.contentLength, height: 56)
        let drawer = layout.drawerFrame(strip: strip, in: visible, avoiding: others)
        XCTAssertGreaterThanOrEqual(drawer.minX, 62 + DockLayout.dockGap, "clear of the vertical arm")
        XCTAssertEqual(drawer.minX, strip.minX, "and opening away from the dock")
    }

    func testWatchReportsMacHUDMoving() throws {
        let changed = expectation(description: "watch fires")
        let watch = registry.watch(debounce: 0.05) { _ in changed.fulfill() }
        try writeMacHUD(position: "right", frames: [[1378, 300, 56, 300]])
        wait(for: [changed], timeout: 3)
        withExtendedLifetime(watch) {}
        XCTAssertEqual(registry.others(than: "xyz.machud.sift")["com.jrisberg.machud"]?.position, .right)
    }
}

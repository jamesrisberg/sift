import CoreGraphics
import HUDKit
@testable import Sift
import XCTest

/// Dismissing hides, summoning brings the panel back where it was, in the mode it was in.
final class PanelMemoryTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "sift.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaults() {
        let memory = PanelMemory(defaults: defaults)
        XCTAssertNil(memory.fullFrame)
        XCTAssertEqual(memory.mode, .full)
        XCTAssertEqual(memory.dockPosition, .bottom)
    }

    func testFramesModeAndDockSurviveARelaunch() {
        let frame = CGRect(x: 120, y: 80, width: 900, height: 560)
        let memory = PanelMemory(defaults: defaults)
        memory.fullFrame = frame
        memory.mode = .compact
        memory.dockPosition = .topRight

        let later = PanelMemory(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(later.fullFrame, frame)
        XCTAssertEqual(later.mode, .compact)
        XCTAssertEqual(later.dockPosition, .topRight)
    }

    func testLaunchModeDefaultsToTheDock() {
        let memory = PanelMemory(defaults: defaults)
        XCTAssertEqual(memory.launchMode, .dock)
        XCTAssertEqual(memory.initialMode, .compact)
        memory.mode = .full
        XCTAssertEqual(memory.initialMode, .compact, "dock wins over the last mode by default")
    }

    func testLaunchModeFullAndLast() {
        let memory = PanelMemory(defaults: defaults)
        memory.mode = .compact
        memory.launchMode = .full
        XCTAssertEqual(memory.initialMode, .full)
        memory.launchMode = .last
        XCTAssertEqual(memory.initialMode, .compact)
        memory.mode = .full
        XCTAssertEqual(memory.initialMode, .full)
        XCTAssertEqual(PanelMemory(defaults: UserDefaults(suiteName: suiteName)!).launchMode, .last)
        defaults.set("sideways", forKey: PanelMemory.launchModeKey)
        XCTAssertEqual(memory.launchMode, .dock)
        XCTAssertEqual(LaunchMode.last.mode(last: .parked), .full)
    }

    func testParkingIsNeverRemembered() {
        let memory = PanelMemory(defaults: defaults)
        memory.mode = .compact
        memory.mode = .parked
        XCTAssertEqual(memory.mode, .compact, "a summon never comes back parked")
        defaults.set("parked", forKey: PanelMemory.modeKey)
        XCTAssertEqual(memory.mode, .full)
    }

    func testBadValuesFallBack() {
        defaults.set("{{0, 0}, {0, 0}}", forKey: PanelMemory.fullFrameKey)
        defaults.set("middle", forKey: PanelMemory.dockPositionKey)
        let memory = PanelMemory(defaults: defaults)
        XCTAssertNil(memory.fullFrame)
        XCTAssertEqual(memory.dockPosition, .bottom)
    }

    func testSummonReturnsToTheLastFrame() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 875)]
        let dismissed = CGRect(x: 300, y: 200, width: 900, height: 560)
        XCTAssertEqual(PanelMemory.summonFrame(remembered: nil, dismissedAt: dismissed, screens: screens), dismissed)

        let remembered = CGRect(x: 10, y: 10, width: 800, height: 500)
        XCTAssertEqual(PanelMemory.summonFrame(remembered: remembered, dismissedAt: dismissed, screens: screens), remembered)

        // Its screen went away (an external display): fall back, then give up (the caller centres).
        let gone = CGRect(x: 3000, y: 0, width: 900, height: 560)
        XCTAssertEqual(PanelMemory.summonFrame(remembered: gone, dismissedAt: dismissed, screens: screens), dismissed)
        XCTAssertNil(PanelMemory.summonFrame(remembered: gone, dismissedAt: gone, screens: screens))
    }
}

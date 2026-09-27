import CoreGraphics
import HUDKit
@testable import Sift
import XCTest

/// `panel mode parked edge= peek=`: park where MacHUD says, and keep parking there.
final class ParkingSpotTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    /// Closest to the left edge, so the nearest-edge fallback is `.left`.
    private let rest = CGRect(x: 40, y: 300, width: 400, height: 300)

    func testWithoutAnEdgeParksAtTheNearestEdge() {
        let spot = ParkingSpot(peek: 14)
        XCTAssertEqual(spot.edge(for: rest, in: screen), .left)
        XCTAssertEqual(spot.offScreenFrame(for: rest, in: screen).maxX, 14)
    }

    func testParkedWithEdgeAndPeekParksThere() {
        var spot = ParkingSpot(peek: 14)
        XCTAssertTrue(spot.update(with: HUDPanelModeOptions(edge: .right, peek: 24)))
        XCTAssertEqual(spot.edge(for: rest, in: screen), .right, "the requested edge wins over the nearest one")
        let parked = spot.offScreenFrame(for: rest, in: screen)
        XCTAssertEqual(parked.minX, screen.maxX - 24, "only the requested peek shows")
        XCTAssertEqual(parked.size, rest.size)
        XCTAssertEqual(parked.minY, rest.minY, "the other axis stays put")

        XCTAssertTrue(spot.update(with: HUDPanelModeOptions(edge: .top)))
        XCTAssertEqual(spot.offScreenFrame(for: rest, in: screen).minY, screen.maxY - 24, "a new edge keeps the last peek")
    }

    func testLaterParkedWithoutArgsReusesTheLastEdge() {
        var spot = ParkingSpot(peek: 14)
        spot.update(with: HUDPanelModeOptions(edge: .bottom, peek: 8))
        XCTAssertFalse(spot.update(with: HUDPanelModeOptions()), "a bare parked changes nothing")
        XCTAssertEqual(spot.edge, .bottom)
        XCTAssertEqual(spot.peek, 8)
        XCTAssertEqual(spot.offScreenFrame(for: rest, in: screen).maxY, 8)
    }

    func testPeekIsClampedToTheFrame() {
        var spot = ParkingSpot(peek: 14)
        spot.update(with: HUDPanelModeOptions(edge: .left, peek: -5))
        XCTAssertEqual(spot.peek, 0)
        spot.update(with: HUDPanelModeOptions(peek: 10_000))
        XCTAssertEqual(spot.offScreenFrame(for: rest, in: screen), CGRect(x: 0, y: 300, width: 400, height: 300),
                       "a peek wider than the panel leaves it fully on screen, not past the far edge")
    }
}

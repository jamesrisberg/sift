import CoreGraphics
import HUDKit
@testable import Sift
import XCTest

/// The strip's tiles, its place on each edge, snapping, and where the drawer opens.
final class DockLayoutTests: XCTestCase {
    /// A visible frame below a 25 pt menu bar.
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @MainActor
    func testStandardStripHasTrashDownloadsTargetsAndAdd() {
        let layout = DockLayout.standard(position: .bottom, targetCount: 3)
        XCTAssertEqual(layout.tileCount, 6)
        XCTAssertEqual(layout.groups, [1, 4, 1], "Trash | Downloads, targets | +")
        XCTAssertEqual(layout.style, .standard, "the MacHUD tool dock's strip")
        XCTAssertEqual(layout.thickness, 64)
        // 10 + 6 * 44 + 5 * 6 + 2 * 13 (dividers) + 10
        XCTAssertEqual(layout.contentLength, 340)
        XCTAssertEqual(layout.contentSize, CGSize(width: 340, height: 64))
        XCTAssertEqual(PanelController.compactSize, layout.contentSize, "the manifest's compactSize is this strip")
    }

    func testTileFramesAlongABottomStrip() {
        let layout = DockLayout.standard(position: .bottom, targetCount: 2)
        let frames = layout.tileFrames
        XCTAssertEqual(frames.count, 5)
        XCTAssertEqual(frames[0], CGRect(x: 10, y: 10, width: 44, height: 44), "Trash, 10 pt in from the border")
        XCTAssertEqual(frames[1].minX, frames[0].maxX + 6 + 7 + 6, "a divider after Trash")
        XCTAssertEqual(frames[2].minX, frames[1].maxX + 6)
        XCTAssertEqual(frames[4].minX, frames[3].maxX + 19, "a divider before +")
        XCTAssertEqual(layout.contentLength, frames[4].maxX + 10)
        for frame in frames { XCTAssertEqual(frame.minY, 10); XCTAssertEqual(frame.size, CGSize(width: 44, height: 44)) }
        // Dividers sit halfway between the tiles they separate.
        let dividers = layout.placement.dividers
        XCTAssertEqual(dividers[0].midX, (frames[0].maxX + frames[1].minX) / 2)
        XCTAssertEqual(dividers[1].midX, (frames[3].maxX + frames[4].minX) / 2)
        XCTAssertEqual(layout.tile(at: CGPoint(x: frames[2].midX, y: 32)), 2)
        XCTAssertNil(layout.tile(at: CGPoint(x: frames[0].maxX + 3, y: 32)), "the gap between tiles drags the strip")
    }

    func testTileFramesDownASideStrip() {
        for edge in [DockEdge.left, .right] {
            let layout = DockLayout.standard(position: HUDDockPosition(edge: edge.hudEdge), targetCount: 2)
            let horizontal = DockLayout.standard(position: .bottom, targetCount: 2)
            for (side, bottom) in zip(layout.tileFrames, horizontal.tileFrames) {
                XCTAssertEqual(side, CGRect(x: bottom.minY, y: horizontal.contentLength - bottom.maxX, width: 44, height: 44),
                               "the same run, top to bottom")
            }
            XCTAssertEqual(layout.contentSize, CGSize(width: 64, height: horizontal.contentLength))
        }
    }

    func testStripFramePerPosition() {
        let layout = DockLayout.standard(position: .bottom, targetCount: 3)
        func frame(_ position: HUDDockPosition) -> CGRect {
            var l = layout
            l.position = position
            return l.stripFrame(in: visible)
        }
        XCTAssertEqual(frame(.bottom), CGRect(x: 720 - 170, y: 6, width: 340, height: 64), "centred, 6 pt above the bottom")
        XCTAssertEqual(frame(.top), CGRect(x: 720 - 170, y: 875 - 6 - 64, width: 340, height: 64), "centred under the menu bar")

        let left = frame(.left)
        XCTAssertEqual(left.minX, 6)
        XCTAssertEqual(left.size, CGSize(width: 64, height: 340))
        XCTAssertEqual(left.midY, visible.midY, accuracy: 0.5)
        XCTAssertEqual(frame(.right).maxX, 1440 - 6)

        // Corners: a column down (or up) the side from the corner, never an L.
        XCTAssertEqual(frame(.topLeft), CGRect(x: 6, y: 875 - 6 - 340, width: 64, height: 340))
        XCTAssertEqual(frame(.bottomLeft), CGRect(x: 6, y: 6, width: 64, height: 340))
        XCTAssertEqual(frame(.topRight), CGRect(x: 1440 - 6 - 64, y: 875 - 6 - 340, width: 64, height: 340))
        XCTAssertEqual(frame(.bottomRight), CGRect(x: 1440 - 6 - 64, y: 6, width: 64, height: 340))
        for corner in [HUDDockPosition.topLeft, .topRight, .bottomLeft, .bottomRight] {
            var l = layout
            l.position = corner
            XCTAssertFalse(l.edge.isHorizontal, "\(corner) runs along the vertical edge")
        }
    }

    func testLongStripsShrinkTheirTilesToFit() {
        let layout = DockLayout.standard(position: .left, targetCount: 40)
        let fitted = layout.fitted(in: visible)
        XCTAssertLessThan(fitted.style.itemSize, 44, "tiles shrink as the tool dock's do")
        XCTAssertLessThanOrEqual(fitted.contentLength, visible.height - 12)
        let frame = layout.stripFrame(in: visible)
        XCTAssertEqual(frame.size, fitted.contentSize)
        XCTAssertEqual(frame.minX, 6)
        var corner = layout
        corner.position = .topLeft
        XCTAssertEqual(corner.stripFrame(in: visible).size, frame.size, "a corner strip is the side strip")
        XCTAssertEqual(DockLayout.standard(position: .left, targetCount: 3).fitted(in: visible).style, .standard,
                       "never grown")
    }

    func testSnapsToTheNearestOfEightPositions() {
        func snap(_ x: CGFloat, _ y: CGFloat) -> HUDDockPosition {
            DockLayout.snap(CGRect(x: x - 50, y: y - 20, width: 100, height: 40), in: visible)
        }
        XCTAssertEqual(snap(720, 60), .bottom)
        XCTAssertEqual(snap(720, 850), .top)
        XCTAssertEqual(snap(40, 400), .left)
        XCTAssertEqual(snap(1400, 400), .right)
        XCTAssertEqual(snap(100, 820), .topLeft)
        XCTAssertEqual(snap(1350, 820), .topRight)
        XCTAssertEqual(snap(100, 40), .bottomLeft)
        XCTAssertEqual(snap(1350, 40), .bottomRight)

        // A strip snaps back to where it already is.
        for position in HUDDockPosition.allCases {
            let layout = DockLayout.standard(position: position, targetCount: 3)
            XCTAssertEqual(DockLayout.snap(layout.stripFrame(in: visible), in: visible), position, "\(position)")
        }
    }

    func testDrawerOpensPerpendicularToTheEdge() {
        // Bottom: above the strip, centred on it.
        let bottom = DockLayout.standard(position: .bottom, targetCount: 3)
        let strip = bottom.stripFrame(in: visible)
        let up = bottom.drawerFrame(strip: strip, in: visible)
        XCTAssertEqual(up.minY, strip.maxY + DockLayout.drawerGap)
        XCTAssertEqual(up.midX, strip.midX)
        XCTAssertEqual(up.size, DockLayout.horizontalDrawer)
        let tuckedUp = bottom.drawerTuckedFrame(for: up)
        XCTAssertEqual(tuckedUp.minY, up.minY - DockLayout.drawerSlide, "slides up out of the strip")
        XCTAssertEqual(tuckedUp.minX, up.minX)

        // Top: below the strip.
        var top = bottom
        top.position = .top
        let topStrip = top.stripFrame(in: visible)
        let down = top.drawerFrame(strip: topStrip, in: visible)
        XCTAssertEqual(down.maxY, topStrip.minY - DockLayout.drawerGap)
        XCTAssertEqual(down.size, DockLayout.horizontalDrawer)
        XCTAssertEqual(top.drawerTuckedFrame(for: down).minY, down.minY + DockLayout.drawerSlide, "slides down")

        // Left (and the left corners): to the right of the strip.
        var left = bottom
        left.position = .left
        let leftStrip = left.stripFrame(in: visible)
        let right = left.drawerFrame(strip: leftStrip, in: visible)
        XCTAssertEqual(right.minX, leftStrip.maxX + DockLayout.drawerGap)
        XCTAssertEqual(right.midY, leftStrip.midY, accuracy: 0.5)
        XCTAssertEqual(right.size, DockLayout.verticalDrawer)
        XCTAssertEqual(left.drawerTuckedFrame(for: right).minX, right.minX - DockLayout.drawerSlide, "slides right")

        // Right: to the left of the strip.
        var rightEdge = bottom
        rightEdge.position = .bottomRight
        let rightStrip = rightEdge.stripFrame(in: visible)
        let leftward = rightEdge.drawerFrame(strip: rightStrip, in: visible)
        XCTAssertEqual(leftward.maxX, rightStrip.minX - DockLayout.drawerGap)
        XCTAssertEqual(leftward.minY, 6, "kept on screen beside a corner strip")
        XCTAssertEqual(rightEdge.drawerTuckedFrame(for: leftward).minX, leftward.minX + DockLayout.drawerSlide, "slides left")
    }

    func testDrawerStaysOnScreenBesideAStripNearACorner() {
        let bottom = DockLayout.standard(position: .bottom, targetCount: 1)
        let strip = CGRect(x: 6, y: 6, width: bottom.contentLength, height: 56)
        let drawer = bottom.drawerFrame(strip: strip, in: visible)
        XCTAssertEqual(drawer.minX, 6, "pushed right to stay inside the screen")

        let corner = DockLayout.standard(position: .topLeft, targetCount: 1)
        let beside = corner.drawerFrame(strip: corner.stripFrame(in: visible), in: visible)
        XCTAssertEqual(beside.maxY, visible.maxY - 6)

        let small = CGRect(x: 0, y: 0, width: 500, height: 300)
        let cramped = bottom.drawerFrame(strip: bottom.stripFrame(in: small), in: small)
        XCTAssertLessThanOrEqual(cramped.maxY, small.maxY - 6)
        XCTAssertLessThanOrEqual(cramped.width, small.width - 12)
    }
}

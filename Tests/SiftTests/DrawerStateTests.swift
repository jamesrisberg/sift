import FileKit
import Foundation
@testable import Sift
import XCTest

/// One drawer at a time: open, swap in place, close on the same tile or outside.
final class DrawerStateTests: XCTestCase {
    private let downloads = URL(filePath: "/Users/me/Downloads", directoryHint: .isDirectory)
    private let invoices = URL(filePath: "/Users/me/Invoices", directoryHint: .isDirectory)

    func testClickOpensThenTheSameTileCloses() {
        var state = DrawerState()
        XCTAssertFalse(state.isOpen)
        XCTAssertEqual(state.toggle(downloads), .open(downloads.normalizedFileURL))
        XCTAssertTrue(state.isOpen)
        XCTAssertTrue(state.isShowing(downloads))
        XCTAssertEqual(state.toggle(downloads), .close)
        XCTAssertFalse(state.isOpen)
        XCTAssertNil(state.folder)
    }

    func testAnotherTileSwapsInPlace() {
        var state = DrawerState()
        state.toggle(downloads)
        XCTAssertEqual(state.toggle(invoices), .swap(invoices.normalizedFileURL))
        XCTAssertTrue(state.isShowing(invoices))
        XCTAssertFalse(state.isShowing(downloads), "only one drawer at a time")
        XCTAssertEqual(state.toggle(invoices), .close)
    }

    func testCloseFromOutside() {
        var state = DrawerState()
        XCTAssertEqual(state.close(), .none, "nothing to close")
        state.toggle(invoices)
        XCTAssertEqual(state.close(), .close)
        XCTAssertEqual(state.close(), .none)
        XCTAssertEqual(state.toggle(invoices), .open(invoices.normalizedFileURL), "reopens after an outside close")
    }

    func testShowOpensOrSwapsButNeverCloses() {
        var state = DrawerState()
        XCTAssertEqual(state.show(downloads), .open(downloads.normalizedFileURL))
        XCTAssertEqual(state.show(downloads), .none)
        XCTAssertEqual(state.show(invoices), .swap(invoices.normalizedFileURL))
    }

    func testEquivalentURLsAreTheSameTile() {
        var state = DrawerState()
        state.toggle(URL(filePath: "/Users/me/Invoices/"))
        XCTAssertEqual(state.toggle(URL(filePath: "/Users/me/./Invoices")), .close)
    }
}

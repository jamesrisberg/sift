import XCTest
@testable import FileKit

final class NavigationHistoryTests: XCTestCase {
    func testBackForward() {
        let a = URL(filePath: "/a"), b = URL(filePath: "/a/b"), c = URL(filePath: "/a/b/c")
        var h = NavigationHistory(start: a)
        h.visit(b); h.visit(c)
        XCTAssertEqual(h.goBack(), b)
        XCTAssertEqual(h.goBack(), a)
        XCTAssertNil(h.goBack())
        XCTAssertEqual(h.goForward(), b)
        h.visit(URL(filePath: "/z"))
        XCTAssertFalse(h.canGoForward)
        h.visit(URL(filePath: "/z"))
        XCTAssertEqual(h.backStack.count, 2, "revisiting current is a no-op")
    }

    func testBreadcrumbs() {
        let crumbs = NavigationHistory.breadcrumbs(for: URL(filePath: "/Users/x/Downloads"))
        XCTAssertEqual(crumbs.map { $0.path(percentEncoded: false) }, ["/", "/Users", "/Users/x", "/Users/x/Downloads"])
    }
}

final class DragDropTests: XCTestCase {
    let a = URL(filePath: "/d/a"), b = URL(filePath: "/d/b"), c = URL(filePath: "/d/c")

    func testDragCarriesSelectionInDisplayOrder() {
        XCTAssertEqual(DragDrop.dragURLs(startingAt: c, selection: [c, a], displayOrder: [a, b, c]), [a, c])
        XCTAssertEqual(DragDrop.dragURLs(startingAt: b, selection: [c, a], displayOrder: [a, b, c]), [b])
        XCTAssertEqual(DragDrop.dragURLs(startingAt: a, selection: [a], displayOrder: [a, b, c]), [a])
    }

    func testDropPlan() {
        let dest = URL(filePath: "/d/folder")
        let urls = [a, dest, URL(filePath: "/d"), URL(filePath: "/d/folder/x"), a, URL(filePath: "/d/fold")]
        XCTAssertEqual(DragDrop.plan(dropping: urls, into: dest, mode: .move), [a, URL(filePath: "/d/fold")])
        XCTAssertEqual(DragDrop.plan(dropping: [URL(filePath: "/d/folder/x")], into: dest, mode: .copy),
                       [URL(filePath: "/d/folder/x")], "copying within a folder duplicates")
    }
}

final class GridNavigationTests: XCTestCase {
    func testMoves() {
        // 3 columns, 7 items:  0 1 2 / 3 4 5 / 6
        XCTAssertEqual(GridNavigation.move(from: nil, .down, columns: 3, count: 7), 0)
        XCTAssertEqual(GridNavigation.move(from: nil, .up, columns: 3, count: 7), 6)
        XCTAssertEqual(GridNavigation.move(from: 1, .down, columns: 3, count: 7), 4)
        XCTAssertEqual(GridNavigation.move(from: 4, .down, columns: 3, count: 7), 6, "partial last row clamps")
        XCTAssertEqual(GridNavigation.move(from: 6, .down, columns: 3, count: 7), 6)
        XCTAssertEqual(GridNavigation.move(from: 1, .up, columns: 3, count: 7), 1)
        XCTAssertEqual(GridNavigation.move(from: 0, .left, columns: 3, count: 7), 0)
        XCTAssertEqual(GridNavigation.move(from: 6, .right, columns: 3, count: 7), 6)
        XCTAssertNil(GridNavigation.move(from: nil, .down, columns: 3, count: 0))
    }
}

final class TargetStoreTests: TempDirTestCase {
    func testRoundTripAndDefaults() throws {
        let store = TargetStore(fileURL: root.appending(path: "Sift/targets.json"))
        let defaults = try store.load()
        XCTAssertEqual(defaults.map(\.name), ["Desktop", "Documents", "Pictures"])
        let targets = [Target(name: "Inbox", colorHex: "FB923C", url: root)]
        try store.save(targets)
        XCTAssertEqual(try store.load(), targets)
    }

    func testCorruptFileThrows() throws {
        let file = try makeFile("targets.json", contents: "{nope")
        XCTAssertThrowsError(try TargetStore(fileURL: file).load())
    }
}

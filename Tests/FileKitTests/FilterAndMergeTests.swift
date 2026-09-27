import XCTest
@testable import FileKit

final class FilterCriteriaTests: TempDirTestCase {
    func testSearchCategoryAndFoldersFirst() throws {
        try makeFile("Beta.png")
        try makeFile("alpha.txt")
        try makeDir("Zeta")
        let items = try FileScanner().scan(root)

        var f = FilterCriteria()
        XCTAssertEqual(f.apply(to: items).map(\.name), ["Zeta", "alpha.txt", "Beta.png"])

        f.foldersFirst = false
        XCTAssertEqual(f.apply(to: items).map(\.name), ["alpha.txt", "Beta.png", "Zeta"])

        f.sortAscending = false
        XCTAssertEqual(f.apply(to: items).map(\.name), ["Zeta", "Beta.png", "alpha.txt"])

        f = FilterCriteria()
        f.searchText = "BET"
        XCTAssertEqual(f.apply(to: items).map(\.name), ["Beta.png"])
        XCTAssertTrue(f.isActive)

        f = FilterCriteria()
        f.categories = [.image, .folder]
        XCTAssertEqual(f.apply(to: items).map(\.name), ["Zeta", "Beta.png"])
        f.reset()
        XCTAssertFalse(f.isActive)
    }

    func testSortBySizeWithNameTieBreak() throws {
        try makeFile("b.txt", contents: "12345")
        try makeFile("a.txt", contents: "12345")
        try makeFile("c.txt", contents: "1")
        var f = FilterCriteria()
        f.sortBy = .fileSize
        f.sortAscending = false
        XCTAssertEqual(f.apply(to: try FileScanner().scan(root)).map(\.name), ["a.txt", "b.txt", "c.txt"])
    }

    func testDateAndSizeRanges() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12))!
        let lastYear = cal.date(byAdding: .year, value: -1, to: now)!
        XCTAssertTrue(FilterCriteria.DateRange.today.matches(now, now: now, calendar: cal))
        XCTAssertFalse(FilterCriteria.DateRange.today.matches(lastYear, now: now, calendar: cal))
        XCTAssertTrue(FilterCriteria.DateRange.older.matches(lastYear, now: now, calendar: cal))
        XCTAssertFalse(FilterCriteria.DateRange.today.matches(nil, now: now))
        XCTAssertTrue(FilterCriteria.SizeRange.tiny.matches(10))
        XCTAssertTrue(FilterCriteria.SizeRange.huge.matches(2_000_000_000))
        XCTAssertFalse(FilterCriteria.SizeRange.small.matches(500))
    }
}

final class FileListMergerTests: TempDirTestCase {
    func testMergeKeepsExistingObjectsAndReportsChanges() throws {
        let a = try makeFile("a.txt", contents: "a")
        let b = try makeFile("b.txt", contents: "b")
        let first = try FileScanner().scan(root)
        let initial = FileListMerger.merge(existing: [], scanned: first)
        XCTAssertEqual(initial.added.count, 2)

        let aItem = try XCTUnwrap(initial.items.first { $0.url == a })
        let bItem = try XCTUnwrap(initial.items.first { $0.url == b })
        let fakeThumb = try XCTUnwrap(Self.onePixelImage())
        aItem.thumbnail = fakeThumb
        bItem.thumbnail = fakeThumb

        // Change b (size and mtime), remove nothing yet, add c.
        try "bbbbbbbb".data(using: .utf8)!.write(to: b)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: b.path)
        let c = try makeFile("c.txt")
        try FileManager.default.removeItem(at: a)

        let second = FileListMerger.merge(existing: initial.items, scanned: try FileScanner().scan(root))
        XCTAssertEqual(Set(second.items.map(\.url)), [b, c])
        XCTAssertEqual(second.removed, [a])
        XCTAssertEqual(second.added.map(\.url), [c])
        XCTAssertEqual(second.changed.map(\.url), [b])
        let bAfter = try XCTUnwrap(second.items.first { $0.url == b })
        XCTAssertTrue(bAfter === bItem, "existing object is reused")
        XCTAssertNil(bAfter.thumbnail, "changed file drops its stale thumbnail")
        XCTAssertEqual(bAfter.fileSize, 8)
    }

    func testUnchangedItemsKeepThumbnails() throws {
        try makeFile("a.txt")
        let first = FileListMerger.merge(existing: [], scanned: try FileScanner().scan(root))
        first.items[0].thumbnail = Self.onePixelImage()
        let second = FileListMerger.merge(existing: first.items, scanned: try FileScanner().scan(root))
        XCTAssertTrue(second.items[0] === first.items[0])
        XCTAssertNotNil(second.items[0].thumbnail)
        XCTAssertTrue(second.added.isEmpty && second.removed.isEmpty && second.changed.isEmpty)
    }

    static func onePixelImage() -> CGImage? {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return ctx?.makeImage()
    }
}

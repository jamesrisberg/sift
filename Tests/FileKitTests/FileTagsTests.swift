import XCTest
@testable import FileKit

final class FileTagsTests: TempDirTestCase {
    let service = FileActionService()

    func testTagRoundTrip() throws {
        let a = try makeFile("a.txt")
        XCTAssertEqual(try FileTags.read(a), [])
        try FileTags.write(["Red", "Project X", "red"], to: a)
        XCTAssertEqual(try FileTags.read(a), ["Red", "Project X"])
        XCTAssertEqual(FileItem(url: a).tagNames, ["Red", "Project X"])
        XCTAssertEqual(FileTags.colors(of: a)["Red"], .red)
        try FileTags.write([], to: a)
        XCTAssertEqual(try FileTags.read(a), [])
    }

    func testSetTagsIsUndoable() throws {
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        try FileTags.write(["Blue"], to: b)
        let journal = UndoJournal(service: service)

        let ops = try service.toggleTag("Green", on: [a, b])
        XCTAssertEqual(ops, [.setTags(a, from: [], to: ["Green"]), .setTags(b, from: ["Blue"], to: ["Blue", "Green"])])
        journal.record(ops)
        XCTAssertEqual(journal.undoName, "Tag 2 Items")

        try journal.undo()
        XCTAssertEqual(try FileTags.read(a), [])
        XCTAssertEqual(try FileTags.read(b), ["Blue"])
        try journal.redo()
        XCTAssertEqual(try FileTags.read(b), ["Blue", "Green"])

        // Toggling when every item has the tag removes it.
        let off = try service.toggleTag("Green", on: [a, b])
        XCTAssertEqual(off.count, 2)
        XCTAssertEqual(try FileTags.read(a), [])
    }

    func testTagFilter() throws {
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        try FileTags.write(["Work"], to: a)
        var filter = FilterCriteria()
        filter.tags = ["Work"]
        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(filter.apply(to: [FileItem(url: a), FileItem(url: b)]).map(\.url), [a])
    }

    func testMergePicksUpTagChanges() throws {
        let a = try makeFile("a.txt")
        let old = FileItem(url: a)
        try FileTags.write(["Red"], to: a)
        _ = FileListMerger.merge(existing: [old], scanned: [FileItem(url: a)])
        XCTAssertEqual(old.tagNames, ["Red"])
    }
}

import XCTest
@testable import FileKit

final class RenameTemplateTests: TempDirTestCase {
    private func input(_ name: String, dir: Bool = false, date: Date? = nil) -> RenameTemplate.Input {
        RenameTemplate.Input(url: URL(filePath: "/tmp/x/\(name)"), isDirectory: dir, date: date)
    }

    func testTokens() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14
        let t = RenameTemplate(pattern: "{date} {n:3} {name} ({ext}) {bogus}", startNumber: 9)
        XCTAssertEqual(try t.name(for: input("IMG_1.jpg", date: date), index: 0, calendar: utc),
                       "2023-11-14 009 IMG_1 (jpg) {bogus}.jpg")
        XCTAssertEqual(try t.name(for: input("IMG_2.jpg", date: date), index: 2, calendar: utc),
                       "2023-11-14 011 IMG_2 (jpg) {bogus}.jpg")
        let custom = RenameTemplate(pattern: "{date:yyyyMMdd}-{n}", keepExtension: false)
        XCTAssertEqual(try custom.name(for: input("a.txt", date: date), index: 0, calendar: utc), "20231114-1")
    }

    func testExtensionHandling() throws {
        let t = RenameTemplate(pattern: "{name}-v2")
        XCTAssertEqual(try t.name(for: input("notes"), index: 0), "notes-v2")
        XCTAssertEqual(try t.name(for: input("archive.tar.gz"), index: 0), "archive.tar-v2.gz")
        XCTAssertEqual(try t.name(for: input("Photos.2024", dir: true), index: 0), "Photos.2024-v2")
        let whole = RenameTemplate(pattern: "{name}.{ext}.bak", keepExtension: false)
        XCTAssertEqual(try whole.name(for: input("a.txt"), index: 0), "a.txt.bak")
    }

    func testFindReplace() throws {
        var t = RenameTemplate(find: "img", replace: "Photo")
        XCTAssertEqual(try t.name(for: input("IMG_001.JPG"), index: 0), "Photo_001.JPG")
        t.caseSensitive = true
        XCTAssertEqual(try t.name(for: input("IMG_001.JPG"), index: 0), "IMG_001.JPG")
        // Literal mode escapes regex metacharacters and $ in the replacement.
        let literal = RenameTemplate(find: "(1)", replace: "$1")
        XCTAssertEqual(try literal.name(for: input("a (1).txt"), index: 0), "a $1.txt")
        let regex = RenameTemplate(find: #"^(\w+)_(\d+)$"#, replace: "$2-$1", useRegex: true)
        XCTAssertEqual(try regex.name(for: input("IMG_001.jpg"), index: 0), "001-IMG.jpg")
        XCTAssertThrowsError(try RenameTemplate(find: "(", useRegex: true).validate())
    }

    func testPlanFlagsProblems() throws {
        let a = try makeFile("a.txt"), b = try makeFile("b.txt")
        try makeFile("taken.txt")
        let rows = BatchRename.validate([(a, "same.txt"), (b, "SAME.txt")])
        XCTAssertEqual(rows.map(\.problem), [.duplicate, .duplicate])
        XCTAssertEqual(BatchRename.validate([(a, "taken.txt")]).first?.problem, .exists)
        XCTAssertEqual(BatchRename.validate([(a, "x/y")]).first?.problem, .invalidCharacters)
        XCTAssertEqual(BatchRename.validate([(a, " ")]).first?.problem, .empty)
        // Taking another batch member's name is fine (it moves away).
        XCTAssertEqual(BatchRename.validate([(a, "b.txt"), (b, "c.txt")]).map(\.problem), [nil, nil])
    }

    func testRenameBatchSwapIsOneUndoableGroup() throws {
        let service = FileActionService()
        let journal = UndoJournal(service: service)
        let a = try makeFile("a.txt", contents: "A"), b = try makeFile("b.txt", contents: "B")
        let ops = try service.renameBatch([(a, "b.txt"), (b, "a.txt")])
        journal.record(ops)
        XCTAssertEqual(read(a), "B")
        XCTAssertEqual(read(b), "A")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["a.txt", "b.txt"])
        try journal.undo()
        XCTAssertEqual(read(a), "A")
        XCTAssertEqual(read(b), "B")
    }

    func testRenameBatchSequentialNames() throws {
        let service = FileActionService()
        let files = try ["x.jpg", "y.jpg", "z.jpg"].map { try makeFile($0) }
        let rows = try BatchRename.plan(files.map { RenameTemplate.Input(url: $0) },
                                        template: RenameTemplate(pattern: "Trip {n:2}"))
        XCTAssertEqual(rows.map(\.newName), ["Trip 01.jpg", "Trip 02.jpg", "Trip 03.jpg"])
        let ops = try service.renameBatch(rows.map { ($0.source, $0.newName) })
        XCTAssertEqual(ops.count, 3)
        XCTAssertEqual(UndoJournal.defaultName(for: ops), "Rename 3 Items")
        XCTAssertTrue(exists(root.appending(path: "Trip 02.jpg")))
        XCTAssertThrowsError(try service.renameBatch([(files[0], "a"), (files[1], "a")]))
    }
}

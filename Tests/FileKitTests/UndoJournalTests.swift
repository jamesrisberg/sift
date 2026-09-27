import XCTest
@testable import FileKit

final class UndoJournalTests: TempDirTestCase {
    let service = FileActionService()
    lazy var journal = UndoJournal(service: service)

    func testMoveUndoRedo() throws {
        let a = try makeFile("a.txt")
        let dest = try makeDir("dest")
        let moved = dest.appending(path: "a.txt")
        journal.record(try service.move([a], into: dest, onCollision: .keepBoth))
        XCTAssertEqual(journal.undoName, "Move")

        try journal.undo()
        XCTAssertTrue(exists(a)); XCTAssertFalse(exists(moved))
        XCTAssertFalse(journal.canUndo); XCTAssertTrue(journal.canRedo)

        try journal.redo()
        XCTAssertFalse(exists(a)); XCTAssertTrue(exists(moved))
        XCTAssertTrue(journal.canUndo); XCTAssertFalse(journal.canRedo)
    }

    func testTrashPutBackRoundTrip() throws {
        let a = try makeFile("trash-me-\(UUID().uuidString).txt", contents: "keep")
        let ops = try service.trash([a])
        track(ops)
        journal.record(ops)
        XCTAssertEqual(journal.undoName, "Move to Trash")
        XCTAssertFalse(exists(a))

        let undone = try XCTUnwrap(try journal.undo())
        XCTAssertEqual(read(a), "keep")
        guard case .putBack = undone.operations[0] else { return XCTFail("expected putBack") }

        let redone = try XCTUnwrap(try journal.redo())
        track(redone.operations)
        XCTAssertFalse(exists(a))
        guard case let .trash(_, newTrashURL) = redone.operations[0] else { return XCTFail("expected trash") }
        XCTAssertTrue(exists(newTrashURL))

        // Undo again uses the *new* trash location.
        try journal.undo()
        XCTAssertEqual(read(a), "keep")
    }

    func testRenameRoundTrip() throws {
        let a = try makeFile("a.txt")
        let op = try XCTUnwrap(try service.rename(a, to: "b.txt"))
        journal.record([op])
        try journal.undo()
        XCTAssertTrue(exists(a)); XCTAssertFalse(exists(root.appending(path: "b.txt")))
        try journal.redo()
        XCTAssertFalse(exists(a)); XCTAssertTrue(exists(root.appending(path: "b.txt")))
    }

    func testNewFolderUndoOnlyRemovesEmptyFolder() throws {
        let op = try service.newFolder(in: root)
        let folder = try XCTUnwrap(op.resultURL)
        journal.record([op])
        try journal.undo()
        XCTAssertFalse(exists(folder))
        try journal.redo()
        XCTAssertTrue(exists(folder))

        // Put something inside: undo must refuse and keep the entry for a later retry.
        try makeFile("stuff.txt", in: folder)
        XCTAssertThrowsError(try journal.undo()) { error in
            guard case UndoJournal.JournalError.partial(_, let completed, let underlying) = error else {
                return XCTFail("expected partial error, got \(error)")
            }
            XCTAssertEqual(completed, 0)
            XCTAssertEqual(underlying as? FileActionError, .folderNotEmpty(folder))
        }
        XCTAssertTrue(exists(folder.appending(path: "stuff.txt")))
        XCTAssertTrue(journal.canUndo, "failed entry stays on the undo stack")
    }

    func testCopyUndoTrashesCopyAndRedoRestoresIt() throws {
        let a = try makeFile("a.txt", contents: "data")
        let dest = try makeDir("dest")
        let copy = dest.appending(path: "a.txt")
        journal.record(try service.copy([a], into: dest, onCollision: .keepBoth))
        let undone = try XCTUnwrap(try journal.undo())
        track(undone.operations)
        XCTAssertFalse(exists(copy)); XCTAssertTrue(exists(a))
        try journal.redo()
        XCTAssertEqual(read(copy), "data")
    }

    func testReplaceGroupUndoRestoresBoth() throws {
        let dest = try makeDir("dest")
        let old = try makeFile("dest/a.txt", contents: "old")
        let new = try makeFile("a.txt", contents: "new")
        let ops = try service.move([new], into: dest, onCollision: .replace)
        track(ops)
        journal.record(ops)
        XCTAssertEqual(journal.undoName, "Move")
        XCTAssertEqual(read(old), "new")

        try journal.undo()
        XCTAssertEqual(read(old), "old")
        XCTAssertEqual(read(new), "new")

        let redone = try XCTUnwrap(try journal.redo())
        track(redone.operations)
        XCTAssertEqual(read(old), "new")
        XCTAssertFalse(exists(new))
    }

    func testMultiItemGroupAndRedoClearedByNewAction() throws {
        let a = try makeFile("a.txt"), b = try makeFile("b.txt")
        let dest = try makeDir("dest")
        journal.record(try service.move([a, b], into: dest, onCollision: .keepBoth))
        XCTAssertEqual(journal.undoName, "Move 2 Items")
        try journal.undo()
        XCTAssertTrue(exists(a) && exists(b))
        XCTAssertTrue(journal.canRedo)
        journal.record([try service.newFolder(in: root)])
        XCTAssertFalse(journal.canRedo)
        journal.record([])
        XCTAssertEqual(journal.undoStack.count, 1, "empty groups are ignored")
    }

    func testPartialUndoKeepsBothHalves() throws {
        let a = try makeFile("a.txt"), b = try makeFile("b.txt")
        let dest = try makeDir("dest")
        journal.record(try service.move([a, b], into: dest, onCollision: .keepBoth))
        // Block a's return path so undo of the first operation fails. Undo runs in reverse,
        // so b goes back first, then a fails.
        try makeFile("a.txt", contents: "squatter")
        XCTAssertThrowsError(try journal.undo())
        XCTAssertTrue(exists(b))
        XCTAssertEqual(journal.redoStack.last?.operations.count, 1, "b's undo is redoable")
        XCTAssertEqual(journal.undoStack.last?.operations.count, 1, "a's move remains undoable")
    }

    func testOnChangeFires() throws {
        var calls = 0
        journal.onChange = { _ in calls += 1 }
        journal.record([try service.newFolder(in: root)])
        try journal.undo()
        try journal.redo()
        XCTAssertEqual(calls, 3)
    }

    func testLimit() throws {
        let small = UndoJournal(service: service, limit: 2)
        for _ in 0..<3 { small.record([try service.newFolder(in: root)]) }
        XCTAssertEqual(small.undoStack.count, 2)
    }
}

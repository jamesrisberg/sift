import XCTest
@testable import FileKit

final class FileActionServiceTests: TempDirTestCase {
    let service = FileActionService()

    func testMoveIntoFolder() throws {
        let a = try makeFile("a.txt")
        let dest = try makeDir("dest")
        let ops = try service.move([a], into: dest, onCollision: .keepBoth)
        XCTAssertEqual(ops, [.move(from: a, to: dest.appending(path: "a.txt"))])
        XCTAssertFalse(exists(a))
        XCTAssertTrue(exists(dest.appending(path: "a.txt")))
    }

    func testMoveIntoSameFolderIsNoOp() throws {
        let a = try makeFile("a.txt")
        XCTAssertEqual(try service.move([a], into: root, onCollision: .replace), [])
        XCTAssertTrue(exists(a))
    }

    func testCollisionPolicies() throws {
        let dest = try makeDir("dest")
        let existing = try makeFile("dest/a.txt", contents: "old")

        // skip
        let a1 = try makeFile("a.txt", contents: "new1")
        XCTAssertEqual(try service.move([a1], into: dest, onCollision: .skip), [])
        XCTAssertTrue(exists(a1))
        XCTAssertEqual(read(existing), "old")

        // keep both
        let ops = try service.move([a1], into: dest, onCollision: .keepBoth)
        XCTAssertEqual(ops, [.move(from: a1, to: dest.appending(path: "a 2.txt"))])
        XCTAssertEqual(read(dest.appending(path: "a 2.txt")), "new1")

        // replace trashes the old one first (so it can be undone)
        let a2 = try makeFile("a.txt", contents: "new2")
        let replaceOps = try service.move([a2], into: dest, onCollision: .replace)
        track(replaceOps)
        XCTAssertEqual(replaceOps.count, 2)
        guard case let .trash(original, trashedURL) = replaceOps[0] else { return XCTFail("expected trash first") }
        XCTAssertEqual(original, existing)
        XCTAssertTrue(exists(trashedURL))
        XCTAssertEqual(replaceOps[1], .move(from: a2, to: existing))
        XCTAssertEqual(read(existing), "new2")
    }

    func testMoveFolderIntoItselfThrows() throws {
        let folder = try makeDir("folder")
        let inner = try makeDir("folder/inner")
        XCTAssertThrowsError(try service.move([folder], into: inner, onCollision: .keepBoth)) { error in
            XCTAssertEqual(error as? FileActionError, .intoItself(folder))
        }
    }

    func testCopyAndDuplicateNaming() throws {
        let a = try makeFile("report.pdf", contents: "r")
        let dest = try makeDir("dest")
        let copyOps = try service.copy([a], into: dest, onCollision: .keepBoth)
        XCTAssertEqual(copyOps, [.copy(source: a, to: dest.appending(path: "report.pdf"))])
        XCTAssertTrue(exists(a))

        // Copy onto its own folder duplicates.
        let selfCopy = try service.copy([a], into: root, onCollision: .skip)
        XCTAssertEqual(selfCopy.first?.resultURL?.lastPathComponent, "report copy.pdf")

        let dup = try service.duplicate([a])
        XCTAssertEqual(dup.first?.resultURL?.lastPathComponent, "report copy 2.pdf")
    }

    func testRename() throws {
        let a = try makeFile("a.txt")
        try makeFile("taken.txt")
        XCTAssertThrowsError(try service.rename(a, to: "taken.txt"))
        XCTAssertThrowsError(try service.rename(a, to: "bad/name"))
        XCTAssertThrowsError(try service.rename(a, to: "  "))
        XCTAssertNil(try service.rename(a, to: "a.txt"))
        let op = try service.rename(a, to: "b.txt")
        XCTAssertEqual(op, .rename(from: a, to: root.appending(path: "b.txt")))
        // Case-only rename works on case-insensitive volumes.
        let b = root.appending(path: "b.txt")
        XCTAssertNoThrow(try service.rename(b, to: "B.txt"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("B.txt"))
    }

    func testNewFolderIsUnique() throws {
        let first = try service.newFolder(in: root)
        let second = try service.newFolder(in: root)
        XCTAssertEqual(first.resultURL?.lastPathComponent, "untitled folder")
        XCTAssertEqual(second.resultURL?.lastPathComponent, "untitled folder 2")
    }

    func testExecuteNeverOverwrites() throws {
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        XCTAssertThrowsError(try service.execute(.move(from: a, to: b))) { error in
            XCTAssertEqual(error as? FileActionError, .destinationExists(b))
        }
        XCTAssertThrowsError(try service.execute(.move(from: root.appending(path: "missing"), to: root.appending(path: "x"))))
    }

    func testBatchFailureReportsCompletedOperations() throws {
        let a = try makeFile("a.txt")
        let dest = try makeDir("dest")
        let missing = root.appending(path: "missing.txt")
        XCTAssertThrowsError(try service.move([a, missing], into: dest, onCollision: .keepBoth)) { error in
            guard case let FileActionError.partial(completed, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(completed, [.move(from: a, to: dest.appending(path: "a.txt"))])
        }
        // A failure on the first item is not partial.
        XCTAssertThrowsError(try service.move([missing], into: dest, onCollision: .keepBoth)) { error in
            XCTAssertEqual(error as? FileActionError, .sourceMissing(missing))
        }
    }

    func testIsAncestorUsesComponents() {
        let foo = URL(filePath: "/a/foo")
        XCTAssertTrue(FileActionService.isAncestor(foo, of: URL(filePath: "/a/foo/bar")))
        XCTAssertFalse(FileActionService.isAncestor(foo, of: URL(filePath: "/a/foobar")))
        XCTAssertFalse(FileActionService.isAncestor(foo, of: foo))
    }
}

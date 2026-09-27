import XCTest
@testable import FileKit

final class FileScannerTests: TempDirTestCase {
    func testShallowScanSkipsHiddenAndDescendants() throws {
        try makeFile("a.txt")
        try makeFile(".hidden")
        try makeFile("sub/inner.txt")
        let items = try FileScanner().scan(root)
        XCTAssertEqual(Set(items.map(\.name)), ["a.txt", "sub"])
        let sub = try XCTUnwrap(items.first { $0.name == "sub" })
        XCTAssertTrue(sub.isDirectory)
        XCTAssertTrue(sub.isBrowsable)
        XCTAssertEqual(sub.category, .folder)
    }

    func testIncludeHidden() throws {
        try makeFile("a.txt")
        try makeFile(".hidden")
        let items = try FileScanner().scan(root, options: .init(includeHidden: true))
        XCTAssertEqual(Set(items.map(\.name)), ["a.txt", ".hidden"])
    }

    func testRecursiveDepth() throws {
        try makeFile("a.txt")
        try makeFile("l1/b.txt")
        try makeFile("l1/l2/c.txt")
        try makeFile("l1/l2/l3/d.txt")

        let depth1 = try FileScanner().scan(root, options: .recursive(depth: 1))
        XCTAssertEqual(Set(depth1.map(\.name)), ["a.txt", "l1", "b.txt", "l2"])

        let depth2 = try FileScanner().scan(root, options: .recursive(depth: 2))
        XCTAssertEqual(Set(depth2.map(\.name)), ["a.txt", "l1", "b.txt", "l2", "c.txt", "l3"])
    }

    func testPackagesAreNotDescended() throws {
        try makeFile("Thing.app/Contents/Info.plist")
        let items = try FileScanner().scan(root, options: .recursive(depth: 5))
        XCTAssertEqual(items.map(\.name), ["Thing.app"])
        XCTAssertTrue(items[0].isPackage)
        XCTAssertFalse(items[0].isBrowsable)
        XCTAssertEqual(items[0].category, .app)
    }

    func testUnreadableDirectoryThrowsInsteadOfLookingEmpty() throws {
        let locked = try makeDir("locked")
        try makeFile("locked/secret.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertThrowsError(try FileScanner().scan(locked))
        // In a recursive scan of the parent, the unreadable child is listed but skipped.
        let items = try FileScanner().scan(root, options: .recursive(depth: 2))
        XCTAssertEqual(items.map(\.name), ["locked"])
    }

    func testMissingDirectoryThrows() {
        XCTAssertThrowsError(try FileScanner().scan(root.appending(path: "nope")))
    }

    func testItemMetadataAndCategories() throws {
        try makeFile("photo.png")
        try makeFile("notes.md", contents: String(repeating: "a", count: 2048))
        try makeFile("main.swift")
        let items = try FileScanner().scan(root)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })
        XCTAssertEqual(byName["photo.png"]?.category, .image)
        XCTAssertEqual(byName["main.swift"]?.category, .code)
        XCTAssertEqual(byName["notes.md"]?.fileSize, 2048)
        XCTAssertNotNil(byName["notes.md"]?.modificationDate)
    }

    @MainActor
    func testFolderCountIsLazyAndCached() async throws {
        try makeFile("sub/one.txt")
        try makeFile("sub/two.txt")
        let sub = FileItem(url: root.appending(path: "sub"))
        XCTAssertNil(sub.folderItemCount)
        XCTAssertEqual(sub.formattedSize, "--")
        await sub.loadFolderItemCount()
        XCTAssertEqual(sub.folderItemCount, 2)
        XCTAssertEqual(sub.formattedSize, "2 items")
        try makeFile("sub/three.txt")
        await sub.loadFolderItemCount()
        XCTAssertEqual(sub.folderItemCount, 2, "cached until invalidated")
        sub.invalidateFolderItemCount()
        await sub.loadFolderItemCount()
        XCTAssertEqual(sub.folderItemCount, 3)
    }
}

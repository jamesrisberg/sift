import XCTest
@testable import FileKit

final class RecursiveSearchTests: TempDirTestCase {
    func testFindsNestedMatchesBreadthFirst() throws {
        try makeFile("Report final.pdf")
        try makeFile("a/b/c/report draft.docx")
        try makeFile("a/notes.txt")
        try makeFile("a/.hidden report")
        try makeDir("Reports.app/Contents/report inside package")
        let result = try RecursiveSearch().search(root, query: "REPORT")
        XCTAssertEqual(result.urls.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") },
                       ["Report final.pdf", "Reports.app", "a/b/c/report draft.docx"])
        XCTAssertFalse(result.truncated)
        // URLs stay under the folder the caller asked for (no /private prefix).
        XCTAssertTrue(result.urls.allSatisfy { $0.path.hasPrefix(root.path) })
    }

    func testDepthLimitAndHidden() throws {
        try makeFile("x1.txt")
        try makeFile("d/x2.txt")
        try makeFile("d/e/x3.txt")
        try makeFile(".x4.txt")
        let shallow = try RecursiveSearch().search(root, query: "x", options: .init(maxDepth: 2))
        XCTAssertEqual(Set(shallow.urls.map(\.lastPathComponent)), ["x1.txt", "x2.txt"])
        XCTAssertTrue(shallow.truncated)
        let hidden = try RecursiveSearch().search(root, query: "x4", options: .init(includeHidden: true))
        XCTAssertEqual(hidden.urls.map(\.lastPathComponent), [".x4.txt"])
    }

    func testTermsAndLimit() throws {
        for i in 0..<5 { try makeFile("photo \(i) beach.jpg") }
        try makeFile("photo city.jpg")
        XCTAssertEqual(try RecursiveSearch().search(root, query: "beach  PHOTO").urls.count, 5)
        let limited = try RecursiveSearch().search(root, query: "photo", options: .init(limit: 3))
        XCTAssertEqual(limited.urls.count, 3)
        XCTAssertTrue(limited.truncated)
        XCTAssertFalse(RecursiveSearch.matches("anything", query: "   "))
        XCTAssertTrue(RecursiveSearch.matches("Café menu", query: "cafe"))
    }

    func testAsyncItemsAndCancellation() async throws {
        try makeFile("deep/er/match.txt")
        let (items, _) = try await RecursiveSearch().items(in: root, query: "match")
        XCTAssertEqual(items.map(\.name), ["match.txt"])

        // Cancel from inside the task so the check is deterministic.
        let task = Task { [root] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try RecursiveSearch().search(root!, query: "match")
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertThrowsError(try RecursiveSearch().search(root.appending(path: "missing"), query: "x"))
    }

    func testSpotlightPredicates() {
        XCTAssertEqual(SpotlightQuery.nameContains("a b").predicateFormat,
                       #"kMDItemFSName CONTAINS[cd] "a" AND kMDItemFSName CONTAINS[cd] "b""#)
        XCTAssertTrue(SpotlightQuery.largerThan(100).predicateFormat.contains("kMDItemFSSize > 100"))
    }
}

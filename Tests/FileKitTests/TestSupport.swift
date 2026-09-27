import XCTest
@testable import FileKit

/// Base class that gives each test a fresh temp directory and cleans up anything it sent
/// to the Trash.
class TempDirTestCase: XCTestCase {
    var root: URL!
    var trashed: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "SiftTests-\(UUID().uuidString)")
            .normalizedFileURL  // deliberately the /var (not /private/var) form
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        trashed = []
    }

    override func tearDownWithError() throws {
        for url in trashed { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func makeFile(_ relative: String, contents: String = "x", in dir: URL? = nil) throws -> URL {
        let url = (dir ?? root).appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    @discardableResult
    func makeDir(_ relative: String) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    /// Remember any trash locations in the given operations for cleanup.
    func track(_ ops: [FileOperation]) {
        for op in ops { if case let .trash(_, t) = op { trashed.append(t) } }
    }
}

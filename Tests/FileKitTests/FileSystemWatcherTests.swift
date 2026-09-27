import XCTest
@testable import FileKit

final class FileSystemWatcherTests: TempDirTestCase {
    func testDeliversEventPathsAndFlags() throws {
        let watcher = FileSystemWatcher(latency: 0.1)
        let got = expectation(description: "created event")
        let target = root.appending(path: "new.txt")
        var events: [FileEvent] = []
        watcher.start(watching: root) { batch in
            events.append(contentsOf: batch)
            if batch.contains(where: { $0.path == FileEvent.canonicalPath(target) && $0.flags.contains(.created) }) {
                got.fulfill()
            }
        }
        // FSEvents needs a moment before it reports changes made right after start.
        Thread.sleep(forTimeInterval: 0.2)
        try makeFile("new.txt")
        wait(for: [got], timeout: 5)
        let event = try XCTUnwrap(events.first { $0.path == FileEvent.canonicalPath(target) })
        XCTAssertTrue(event.flags.contains(.isFile))
        XCTAssertTrue(event.affectsListing(of: root))
        watcher.stop()
        XCTAssertFalse(watcher.isWatching)
    }

    func testCoalescesOneEventPerPathPerBatch() throws {
        let watcher = FileSystemWatcher(latency: 0.3)
        let got = expectation(description: "batch")
        got.assertForOverFulfill = false
        var batches: [[FileEvent]] = []
        watcher.start(watching: root) { batch in
            batches.append(batch)
            got.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.2)
        let url = try makeFile("busy.txt", contents: "1")
        for i in 2...5 { try "\(i)".data(using: .utf8)!.write(to: url) }
        wait(for: [got], timeout: 5)
        for batch in batches {
            let paths = batch.map(\.path)
            XCTAssertEqual(paths.count, Set(paths).count, "duplicate paths in a batch")
        }
        watcher.stop()
    }

    func testStopPreventsFurtherDelivery() throws {
        let watcher = FileSystemWatcher(latency: 0.1)
        var count = 0
        watcher.start(watching: root) { _ in count += 1 }
        watcher.stop()
        try makeFile("after.txt")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertEqual(count, 0)
    }

    func testEventRelevanceHelpers() {
        let dir = URL(filePath: "/Users/x/Downloads")
        let child = FileEvent(path: "/Users/x/Downloads/a.txt", flags: [.created])
        let grandchild = FileEvent(path: "/Users/x/Downloads/sub/deep.txt", flags: [.created])
        let elsewhere = FileEvent(path: "/Users/x/Documents/a.txt", flags: [.created])
        let rescan = FileEvent(path: "/Users/x", flags: [.mustScanSubDirs])
        XCTAssertTrue(child.affectsListing(of: dir))
        XCTAssertFalse(grandchild.affectsListing(of: dir))
        XCTAssertFalse(elsewhere.affectsListing(of: dir))
        XCTAssertTrue(rescan.affectsListing(of: dir))
        XCTAssertEqual(grandchild.affectedChild(of: dir)?.lastPathComponent, "sub")
        XCTAssertNil(child.affectedChild(of: dir))
    }
}

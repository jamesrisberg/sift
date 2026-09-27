import Foundation

/// A live Spotlight (`NSMetadataQuery`) search. Results update as the index changes.
/// Use from the main thread (NSMetadataQuery needs a run loop).
@MainActor
public final class SpotlightQuery {
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private let limit: Int

    /// Called on the main thread with the current results (file URLs, normalized).
    public var onResults: (([URL], _ finishedGathering: Bool) -> Void)?

    public init(predicate: NSPredicate, scopes: [Any] = [NSMetadataQueryUserHomeScope],
                sortBy: [NSSortDescriptor] = [], limit: Int = 500) {
        self.limit = limit
        query.predicate = predicate
        query.searchScopes = scopes
        query.sortDescriptors = sortBy
        query.notificationBatchingInterval = 0.3
    }

    public var isRunning: Bool { query.isStarted && !query.isStopped }

    @discardableResult
    public func start() -> Bool {
        let center = NotificationCenter.default
        let gather = center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deliver(finished: true) }
        }
        let update = center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deliver(finished: true) }
        }
        observers = [gather, update]
        return query.start()
    }

    public func stop() {
        query.stop()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
    }

    private func deliver(finished: Bool) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var urls: [URL] = []
        let count = min(query.resultCount, limit)
        urls.reserveCapacity(count)
        for i in 0..<count {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            urls.append(URL(filePath: path).normalizedFileURL)
        }
        onResults?(urls, finished)
    }

    // MARK: - Predicates

    /// File name contains every term (case and diacritic insensitive).
    nonisolated public static func nameContains(_ query: String) -> NSPredicate {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let parts = terms.map { NSPredicate(format: "%K CONTAINS[cd] %@", NSMetadataItemFSNameKey, $0) }
        return parts.count == 1 ? parts[0] : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// Items opened within the last `days` days.
    nonisolated public static func recentlyUsed(days: Int, now: Date = Date()) -> NSPredicate {
        NSPredicate(format: "%K >= %@", "kMDItemLastUsedDate", now.addingTimeInterval(-Double(days) * 86_400) as NSDate)
    }

    /// Files larger than `bytes`.
    nonisolated public static func largerThan(_ bytes: Int64) -> NSPredicate {
        NSPredicate(format: "%K > %lld", NSMetadataItemFSSizeKey, bytes)
    }
}

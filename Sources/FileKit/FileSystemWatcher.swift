import Foundation
import CoreServices

/// One file-system change reported by FSEvents.
public struct FileEvent: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable, Hashable {
        public let rawValue: UInt32
        public init(rawValue: UInt32) { self.rawValue = rawValue }

        public static let created = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemCreated))
        public static let removed = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemRemoved))
        public static let renamed = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemRenamed))
        public static let modified = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemModified))
        public static let inodeMetaModified = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemInodeMetaMod))
        public static let finderInfoModified = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemFinderInfoMod))
        public static let xattrModified = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemXattrMod))
        public static let isFile = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemIsFile))
        public static let isDirectory = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemIsDir))
        public static let isSymlink = Flags(rawValue: UInt32(kFSEventStreamEventFlagItemIsSymlink))
        /// Events were dropped or coalesced by the kernel: rescan everything under the path.
        public static let mustScanSubDirs = Flags(rawValue: UInt32(kFSEventStreamEventFlagMustScanSubDirs))
        public static let rootChanged = Flags(rawValue: UInt32(kFSEventStreamEventFlagRootChanged))
    }

    /// Canonical path (symlinks resolved, e.g. /private/var/... for temp dirs).
    public let path: String
    public let flags: Flags

    public init(path: String, flags: Flags) {
        self.path = path
        self.flags = flags
    }

    public var url: URL { URL(filePath: path) }

    /// Whether this event changes the listing of `directory` (a direct child was created,
    /// removed, renamed or modified, the directory itself changed, or a full rescan is needed).
    public func affectsListing(of directory: URL) -> Bool {
        let dir = Self.canonicalPath(directory)
        if flags.contains(.mustScanSubDirs) || flags.contains(.rootChanged) {
            return path == dir || path.hasPrefix(dir + "/") || dir.hasPrefix(path + "/") || path == "/"
        }
        return path == dir || (path as NSString).deletingLastPathComponent == dir
    }

    /// If this event happened inside a direct child folder of `directory`, that child's URL
    /// (useful for invalidating cached folder item counts).
    public func affectedChild(of directory: URL) -> URL? {
        let dir = Self.canonicalPath(directory)
        guard path.hasPrefix(dir + "/") else { return nil }
        let rest = path.dropFirst(dir.count + 1)
        guard let first = rest.split(separator: "/").first, rest.contains("/") else { return nil }
        return directory.normalizedFileURL.appending(path: String(first)).normalizedFileURL
    }

    public static func canonicalPath(_ url: URL) -> String { url.canonicalPath }
}

/// FSEvents wrapper that delivers coalesced batches of `FileEvent`s (one per path per
/// batch, flags OR-ed together) on a queue of your choice.
public final class FileSystemWatcher {
    public typealias Handler = ([FileEvent]) -> Void

    public let latency: TimeInterval
    private let deliveryQueue: DispatchQueue
    private let streamQueue = DispatchQueue(label: "sift.filekit.watcher", qos: .utility)
    private var stream: FSEventStreamRef?
    private var box: HandlerBox?

    public private(set) var watchedPaths: [URL] = []
    public var isWatching: Bool { stream != nil }

    /// - Parameters:
    ///   - latency: seconds FSEvents waits to coalesce changes (0.5 matches DownloadDetox).
    ///   - queue: where the handler runs (main by default).
    public init(latency: TimeInterval = 0.5, queue: DispatchQueue = .main) {
        self.latency = latency
        self.deliveryQueue = queue
    }

    deinit { stop() }

    public func start(watching directories: [URL], handler: @escaping Handler) {
        stop()
        guard !directories.isEmpty else { return }
        let box = HandlerBox(handler: handler, queue: deliveryQueue)
        self.box = box

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<HandlerBox>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
            guard let info else { return }
            let box = Unmanaged<HandlerBox>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
            var order: [String] = []
            var merged: [String: FileEvent.Flags] = [:]
            for i in 0..<min(count, paths.count) {
                let path = paths[i]
                let flags = FileEvent.Flags(rawValue: eventFlags[i])
                if merged[path] == nil { order.append(path) }
                merged[path, default: []].formUnion(flags)
            }
            let events = order.map { FileEvent(path: $0, flags: merged[$0] ?? []) }
            box.deliver(events)
        }

        let paths = directories.map { FileEvent.canonicalPath($0) } as CFArray
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags
        ) else {
            Unmanaged.passUnretained(box).release()
            self.box = nil
            return
        }
        self.stream = stream
        self.watchedPaths = directories
        FSEventStreamSetDispatchQueue(stream, streamQueue)
        FSEventStreamStart(stream)
    }

    public func start(watching directory: URL, handler: @escaping Handler) {
        start(watching: [directory], handler: handler)
    }

    public func stop() {
        box?.cancel()
        box = nil
        watchedPaths = []
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

/// Owned by the FSEvents stream (retained through the context) so the callback never
/// touches a deallocated watcher. `cancel()` stops delivery of in-flight batches.
private final class HandlerBox {
    private let lock = NSLock()
    private var handler: FileSystemWatcher.Handler?
    private let queue: DispatchQueue

    init(handler: @escaping FileSystemWatcher.Handler, queue: DispatchQueue) {
        self.handler = handler
        self.queue = queue
    }

    func cancel() {
        lock.lock(); handler = nil; lock.unlock()
    }

    func deliver(_ events: [FileEvent]) {
        guard !events.isEmpty else { return }
        queue.async { [self] in
            lock.lock(); let h = handler; lock.unlock()
            h?(events)
        }
    }
}

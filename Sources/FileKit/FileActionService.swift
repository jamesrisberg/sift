import Foundation

/// What to do when a move or copy destination already has an item with the same name.
/// Passed in as a value (DownloadDetox ran a modal NSAlert here), so the UI decides
/// up front and the service stays testable.
public enum CollisionPolicy: String, Sendable, CaseIterable {
    /// Move the existing item to the Trash (undoable), then place the new one.
    case replace
    /// Place the new one under a unique name ("name 2.ext").
    case keepBoth
    /// Leave both where they are and record nothing.
    case skip
}

public enum FileActionError: LocalizedError, Equatable {
    case destinationExists(URL)
    case sourceMissing(URL)
    case folderNotEmpty(URL)
    case invalidName(String)
    case intoItself(URL)
    /// A multi-item action failed partway. `completed` already happened and should still
    /// be recorded in the undo journal.
    case partial(completed: [FileOperation], underlying: String)

    public var errorDescription: String? {
        switch self {
        case let .destinationExists(u): "\"\(u.lastPathComponent)\" already exists."
        case let .sourceMissing(u): "\"\(u.lastPathComponent)\" no longer exists."
        case let .folderNotEmpty(u): "\"\(u.lastPathComponent)\" is not empty."
        case let .invalidName(n): "\"\(n)\" is not a valid file name."
        case let .intoItself(u): "Cannot move \"\(u.lastPathComponent)\" into itself."
        case let .partial(done, underlying): "\(underlying) (\(done.count) earlier step\(done.count == 1 ? "" : "s") completed)"
        }
    }
}

/// Performs file operations and returns `FileOperation` records for the undo journal.
/// Every public method is synchronous and throws; callers decide threading.
public final class FileActionService: @unchecked Sendable {
    private let fm: FileManager

    public init(fileManager: FileManager = .default) {
        self.fm = fileManager
    }

    // MARK: - High-level actions (return what happened, for the journal)

    public func trash(_ urls: [URL]) throws -> [FileOperation] {
        return try batch { ops in
            for url in urls { ops.append(try execute(.trash(url.normalizedFileURL))) }
        }
    }

    /// Moves each URL into `directory`. Items already in `directory` are skipped.
    /// Returns the completed operations, including any `.trash` for replaced items.
    public func move(_ urls: [URL], into directory: URL, onCollision policy: CollisionPolicy) throws -> [FileOperation] {
        let urls = urls.map(\.normalizedFileURL), directory = directory.normalizedFileURL
        return try batch { ops in
            for url in urls {
                try checkNotIntoItself(url, directory)
                let target = directory.appending(path: url.lastPathComponent)
                if Self.same(url, target) { continue }
                guard let dest = try resolveCollision(target, policy: policy, ops: &ops) else { continue }
                ops.append(try execute(.move(from: url, to: dest)))
            }
        }
    }

    /// Copies each URL into `directory`. Copying an item onto itself makes a duplicate.
    public func copy(_ urls: [URL], into directory: URL, onCollision policy: CollisionPolicy) throws -> [FileOperation] {
        let urls = urls.map(\.normalizedFileURL), directory = directory.normalizedFileURL
        return try batch { ops in
            for url in urls {
                try checkNotIntoItself(url, directory)
                let target = directory.appending(path: url.lastPathComponent)
                let dest: URL
                if Self.same(url, target) {
                    dest = Self.uniqueURL(for: target, fileManager: fm, style: .copy)
                } else {
                    guard let d = try resolveCollision(target, policy: policy, ops: &ops) else { continue }
                    dest = d
                }
                ops.append(try execute(.copy(source: url, to: dest)))
            }
        }
    }

    /// "report.pdf" -> "report copy.pdf", "report copy 2.pdf", ...
    public func duplicate(_ urls: [URL]) throws -> [FileOperation] {
        return try batch { ops in
            for url in urls.map(\.normalizedFileURL) {
                let dest = Self.uniqueURL(for: url, fileManager: fm, style: .copy)
                ops.append(try execute(.copy(source: url, to: dest)))
            }
        }
    }

    public func rename(_ url: URL, to newName: String) throws -> FileOperation? {
        let url = url.normalizedFileURL
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
            throw FileActionError.invalidName(newName)
        }
        if name == url.lastPathComponent { return nil }
        let dest = url.deletingLastPathComponent().appending(path: name)
        // Case-only renames on case-insensitive volumes: the destination "exists" but is the
        // same file, which moveItem handles.
        if fm.fileExists(atPath: dest.path(percentEncoded: false)),
           name.lowercased() != url.lastPathComponent.lowercased() {
            throw FileActionError.destinationExists(dest)
        }
        return try execute(.rename(from: url, to: dest))
    }

    public func newFolder(in directory: URL, name: String = "untitled folder") throws -> FileOperation {
        let url = Self.uniqueURL(for: directory.normalizedFileURL.appending(path: name), fileManager: fm, style: .number)
        return try execute(.createFolder(url))
    }

    /// Changes the Finder tags of each item with `transform` (current tags in, new tags out).
    /// Items whose tags would not change are left alone and not recorded.
    public func setTags(_ urls: [URL], transform: ([String]) -> [String]) throws -> [FileOperation] {
        return try batch { ops in
            for url in urls.map(\.normalizedFileURL) {
                try requireExists(url)
                let current = try FileTags.read(url)
                let wanted = transform(current)
                if wanted == current { continue }
                ops.append(try execute(.setTags(url, wanted)))
            }
        }
    }

    /// Adds `tag` to every item that lacks it, or removes it from all of them when every
    /// item already has it (Finder's toggle behaviour for a multi-selection).
    public func toggleTag(_ tag: String, on urls: [URL]) throws -> [FileOperation] {
        let all = urls.allSatisfy { ((try? FileTags.read($0)) ?? []).contains(tag) }
        return try setTags(urls) { current in
            all ? current.filter { $0 != tag } : (current.contains(tag) ? current : current + [tag])
        }
    }

    // MARK: - Primitive execution (used by the journal for undo/redo)

    @discardableResult
    public func execute(_ op: PlannedOperation) throws -> FileOperation {
        switch op {
        case let .move(from, to):
            try requireExists(from)
            try requireFree(to)
            try fm.moveItem(at: from, to: to)
            return .move(from: from, to: to)
        case let .rename(from, to):
            try requireExists(from)
            if !Self.caseOnlyChange(from, to) { try requireFree(to) }
            try fm.moveItem(at: from, to: to)
            return .rename(from: from, to: to)
        case let .copy(source, to):
            try requireExists(source)
            try requireFree(to)
            try fm.copyItem(at: source, to: to)
            return .copy(source: source, to: to)
        case let .trash(url, _):
            try requireExists(url)
            var resulting: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &resulting)
            return .trash(original: url, trashed: (resulting as URL?) ?? url)
        case let .putBack(trashed, original):
            try requireExists(trashed)
            try requireFree(original)
            try fm.moveItem(at: trashed, to: original)
            return .putBack(trashed: trashed, original: original)
        case let .createFolder(url):
            try requireFree(url)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return .createFolder(url)
        case let .removeEmptyFolder(url):
            try requireExists(url)
            let contents = try fm.contentsOfDirectory(atPath: url.path(percentEncoded: false))
            // .DS_Store alone does not count as content.
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else { throw FileActionError.folderNotEmpty(url) }
            try fm.removeItem(at: url)
            return .removeEmptyFolder(url)
        case let .setTags(url, tags):
            try requireExists(url)
            let old = try FileTags.read(url)
            try FileTags.write(tags, to: url)
            return .setTags(url, from: old, to: try FileTags.read(url))
        }
    }

    // MARK: - Helpers

    /// Runs a multi-item loop; if it throws after some operations completed, rethrows as
    /// `.partial` carrying them so the caller can still journal (and undo) them.
    private func batch(_ body: (inout [FileOperation]) throws -> Void) throws -> [FileOperation] {
        var ops: [FileOperation] = []
        do {
            try body(&ops)
            return ops
        } catch {
            if ops.isEmpty { throw error }
            throw FileActionError.partial(completed: ops, underlying: error.localizedDescription)
        }
    }

    private func resolveCollision(_ target: URL, policy: CollisionPolicy, ops: inout [FileOperation]) throws -> URL? {
        guard exists(target) else { return target }
        switch policy {
        case .skip: return nil
        case .keepBoth: return Self.uniqueURL(for: target, fileManager: fm, style: .number)
        case .replace:
            ops.append(try execute(.trash(target)))
            return target
        }
    }

    private func checkNotIntoItself(_ url: URL, _ directory: URL) throws {
        if Self.isAncestor(url, of: directory) || Self.same(url, directory) {
            throw FileActionError.intoItself(url)
        }
    }

    private func exists(_ url: URL) -> Bool {
        // fileExists follows symlinks; attributesOfItem sees dangling links too.
        (try? fm.attributesOfItem(atPath: url.path(percentEncoded: false))) != nil
    }

    private func requireExists(_ url: URL) throws {
        guard exists(url) else { throw FileActionError.sourceMissing(url) }
    }

    private func requireFree(_ url: URL) throws {
        guard !exists(url) else { throw FileActionError.destinationExists(url) }
    }

    static func same(_ a: URL, _ b: URL) -> Bool { a.isSameFile(as: b) }

    static func caseOnlyChange(_ a: URL, _ b: URL) -> Bool {
        a.parentFolder == b.parentFolder
            && a.lastPathComponent != b.lastPathComponent
            && a.lastPathComponent.lowercased() == b.lastPathComponent.lowercased()
    }

    /// True when `ancestor` is a strict parent folder of `url` (component-wise, so
    /// "/a/foo" is not treated as containing "/a/foobar", unlike a string prefix test).
    public static func isAncestor(_ ancestor: URL, of url: URL) -> Bool {
        let a = ancestor.normalizedFileURL.pathComponents
        let u = url.normalizedFileURL.pathComponents
        return u.count > a.count && Array(u.prefix(a.count)) == a
    }

    public enum UniqueNameStyle { case number, copy }

    /// First free name: `.number` gives "name 2.ext", "name 3.ext"; `.copy` gives
    /// "name copy.ext", "name copy 2.ext" (Finder's duplicate naming).
    public static func uniqueURL(for url: URL, fileManager fm: FileManager = .default, style: UniqueNameStyle) -> URL {
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        func make(_ stem: String) -> URL { dir.appending(path: ext.isEmpty ? stem : "\(stem).\(ext)") }
        func free(_ u: URL) -> Bool { (try? fm.attributesOfItem(atPath: u.path(percentEncoded: false))) == nil }

        switch style {
        case .number:
            if free(url) { return url }
            var n = 2
            while !free(make("\(base) \(n)")) { n += 1 }
            return make("\(base) \(n)")
        case .copy:
            let first = make("\(base) copy")
            if free(first) { return first }
            var n = 2
            while !free(make("\(base) copy \(n)")) { n += 1 }
            return make("\(base) copy \(n)")
        }
    }
}

import Foundation

/// A journal of file operations with undo and redo.
///
/// Each entry is a group of completed operations performed as one user action (e.g.
/// "Move 3 Items"). Undo executes the inverses in reverse order and moves the resulting
/// completed operations to the redo stack; redo does the same in the other direction.
/// Because undo re-records what actually happened (a fresh Trash URL, for instance), the
/// two stacks never go stale.
///
/// Not thread-safe; use from one actor (the app uses the main actor).
public final class UndoJournal {
    public struct Entry: Equatable {
        public var name: String
        public var operations: [FileOperation]
        public init(name: String, operations: [FileOperation]) {
            self.name = name
            self.operations = operations
        }
    }

    public enum JournalError: LocalizedError {
        /// Undo or redo failed partway. The operations that did run are kept on the
        /// opposite stack so they can be reversed again.
        case partial(entry: String, completed: Int, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case let .partial(entry, _, underlying):
                "Could not fully reverse \"\(entry)\": \(underlying.localizedDescription)"
            }
        }
    }

    public private(set) var undoStack: [Entry] = []
    public private(set) var redoStack: [Entry] = []
    public let limit: Int
    private let service: FileActionService

    /// Called after every record, undo or redo with the operations that just ran.
    public var onChange: (([FileOperation]) -> Void)?

    public init(service: FileActionService, limit: Int = 200) {
        self.service = service
        self.limit = limit
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    /// Records a completed user action. Empty groups are ignored. Clears the redo stack.
    @discardableResult
    public func record(_ operations: [FileOperation], name: String? = nil) -> Entry? {
        guard !operations.isEmpty else { return nil }
        let entry = Entry(name: name ?? Self.defaultName(for: operations), operations: operations)
        undoStack.append(entry)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        onChange?(operations)
        return entry
    }

    @discardableResult
    public func undo() throws -> Entry? {
        guard let entry = undoStack.popLast() else { return nil }
        let reversed = try reverse(entry, from: &undoStack, onto: &redoStack)
        onChange?(reversed.operations)
        return reversed
    }

    @discardableResult
    public func redo() throws -> Entry? {
        guard let entry = redoStack.popLast() else { return nil }
        let reversed = try reverse(entry, from: &redoStack, onto: &undoStack)
        onChange?(reversed.operations)
        return reversed
    }

    /// Drops redo history (used when an external undo stack has to be rebuilt).
    public func discardRedo() { redoStack.removeAll() }

    public func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func reverse(_ entry: Entry, from source: inout [Entry], onto stack: inout [Entry]) throws -> Entry {
        var done: [FileOperation] = []
        for (index, op) in entry.operations.enumerated().reversed() {
            do {
                done.append(try service.execute(op.inverse))
            } catch {
                // Keep what ran reversible, and leave what did not run (including the
                // failed operation) on the original stack so it can be retried.
                if !done.isEmpty { stack.append(Entry(name: entry.name, operations: done)) }
                source.append(Entry(name: entry.name, operations: Array(entry.operations[...index])))
                onChange?(done)
                throw JournalError.partial(entry: entry.name, completed: done.count, underlying: error)
            }
        }
        let result = Entry(name: entry.name, operations: done)
        stack.append(result)
        return result
    }

    public static func defaultName(for ops: [FileOperation]) -> String {
        // A replace shows up as trash + move; name the group after the primary action.
        let primary = ops.last { if case .trash = $0 { return false } else { return true } } ?? ops[0]
        let count = ops.filter { $0.actionName == primary.actionName }.count
        switch primary {
        case .trash: return count == 1 ? "Move to Trash" : "Move \(count) Items to Trash"
        case .move: return count == 1 ? "Move" : "Move \(count) Items"
        case .copy: return count == 1 ? "Copy" : "Copy \(count) Items"
        case .setTags: return count == 1 ? "Tag" : "Tag \(count) Items"
        case .rename: return count == 1 ? "Rename" : "Rename \(count) Items"
        default: return primary.actionName
        }
    }
}

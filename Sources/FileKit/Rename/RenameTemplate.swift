import Foundation

/// Builds new file names from a pattern plus an optional find/replace.
///
/// Tokens in `pattern`:
/// - `{name}`: the original name without its extension, after find/replace
/// - `{ext}`: the original extension without the dot (empty if none)
/// - `{n}` / `{n:3}`: a counter starting at `startNumber`, optionally zero-padded
/// - `{date}` / `{date:yyyyMMdd}`: the item's date (modification date by default), formatted
///
/// Unknown tokens are kept literally. With `keepExtension` (the default) the original
/// extension is appended to the result, so `{n:2} {name}` turns "IMG_1.jpg" into "01 IMG_1.jpg".
public struct RenameTemplate: Equatable, Sendable {
    public var pattern: String
    public var find: String
    public var replace: String
    public var useRegex: Bool
    public var caseSensitive: Bool
    public var keepExtension: Bool
    public var startNumber: Int
    public var dateFormat: String

    public init(pattern: String = "{name}", find: String = "", replace: String = "", useRegex: Bool = false,
                caseSensitive: Bool = false, keepExtension: Bool = true, startNumber: Int = 1,
                dateFormat: String = "yyyy-MM-dd") {
        self.pattern = pattern
        self.find = find
        self.replace = replace
        self.useRegex = useRegex
        self.caseSensitive = caseSensitive
        self.keepExtension = keepExtension
        self.startNumber = startNumber
        self.dateFormat = dateFormat
    }

    public enum TemplateError: LocalizedError, Equatable {
        case invalidRegex(String)
        public var errorDescription: String? {
            switch self {
            case let .invalidRegex(why): "Invalid regular expression: \(why)"
            }
        }
    }

    /// One item to rename.
    public struct Input: Equatable, Sendable {
        public var url: URL
        public var isDirectory: Bool
        public var date: Date?
        public init(url: URL, isDirectory: Bool = false, date: Date? = nil) {
            self.url = url
            self.isDirectory = isDirectory
            self.date = date
        }

        /// Folders have no extension ("Photos.2024" is a name, not a type).
        var stem: String { isDirectory || url.pathExtension.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }
        var ext: String { isDirectory ? "" : url.pathExtension }
    }

    /// Throws if the find pattern is not a valid regular expression.
    public func validate() throws { _ = try makeRegex() }

    /// The new name for the `index`th item (0-based) of a batch.
    public func name(for input: Input, index: Int, calendar: Calendar = .current) throws -> String {
        let regex = try makeRegex()
        return render(input, index: index, regex: regex, calendar: calendar)
    }

    /// New names for a whole batch, in order.
    public func names(for inputs: [Input], calendar: Calendar = .current) throws -> [String] {
        let regex = try makeRegex()
        return inputs.enumerated().map { render($1, index: $0, regex: regex, calendar: calendar) }
    }

    private func makeRegex() throws -> NSRegularExpression? {
        guard !find.isEmpty else { return nil }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        do {
            let source = useRegex ? find : NSRegularExpression.escapedPattern(for: find)
            return try NSRegularExpression(pattern: source, options: options)
        } catch {
            throw TemplateError.invalidRegex(find)
        }
    }

    private func render(_ input: Input, index: Int, regex: NSRegularExpression?, calendar: Calendar) -> String {
        var stem = input.stem
        if let regex {
            let template = useRegex ? replace : NSRegularExpression.escapedTemplate(for: replace)
            stem = regex.stringByReplacingMatches(in: stem, range: NSRange(stem.startIndex..., in: stem), withTemplate: template)
        }
        var out = ""
        var rest = Substring(pattern)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            guard let close = rest[open...].firstIndex(of: "}") else { rest = rest[open...]; break }
            let token = rest[rest.index(after: open)..<close]
            out += expand(token, stem: stem, input: input, index: index, calendar: calendar) ?? "{\(token)}"
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        if keepExtension, !input.ext.isEmpty { out += ".\(input.ext)" }
        return out
    }

    private func expand(_ token: Substring, stem: String, input: Input, index: Int, calendar: Calendar) -> String? {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        let key = parts.first?.lowercased() ?? ""
        let arg = parts.count > 1 ? parts[1] : nil
        switch key {
        case "name": return stem
        case "ext": return input.ext
        case "n":
            let n = startNumber + index
            guard let width = arg.flatMap(Int.init), width > 0 else { return String(n) }
            let digits = String(abs(n))
            return (n < 0 ? "-" : "") + String(repeating: "0", count: max(0, width - digits.count)) + digits
        case "date":
            guard let date = input.date else { return "" }
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = arg ?? dateFormat
            return f.string(from: date)
        default:
            return nil
        }
    }
}

/// Plans and validates a batch rename before anything touches the disk.
public enum BatchRename {
    public enum Problem: Equatable, Sendable {
        case empty
        case invalidCharacters
        /// Another item in the batch would get the same name.
        case duplicate
        /// Something not in the batch already has this name.
        case exists

        public var message: String {
            switch self {
            case .empty: "Empty name"
            case .invalidCharacters: "Contains / or :"
            case .duplicate: "Duplicate name"
            case .exists: "Already exists"
            }
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public var id: URL { source }
        public var source: URL
        public var newName: String
        public var problem: Problem?
        public var isUnchanged: Bool { newName == source.lastPathComponent }
        public var destination: URL { source.deletingLastPathComponent().appending(path: newName).normalizedFileURL }
    }

    /// Computes the new names and flags problems. Items are renamed in their own folders.
    public static func plan(_ inputs: [RenameTemplate.Input], template: RenameTemplate,
                            fileManager fm: FileManager = .default) throws -> [Row] {
        let names = try template.names(for: inputs)
        return validate(zip(inputs.map(\.url.normalizedFileURL), names).map { ($0, $1) }, fileManager: fm)
    }

    /// Flags problems in a list of (source, new name) pairs. Names compare case-insensitively,
    /// like the default APFS volume.
    public static func validate(_ pairs: [(URL, String)], fileManager fm: FileManager = .default) -> [Row] {
        let sources = Set(pairs.map { key($0.0) })
        var counts: [String: Int] = [:]
        for (url, name) in pairs { counts[key(url.deletingLastPathComponent().appending(path: name)), default: 0] += 1 }
        return pairs.map { url, name in
            var row = Row(source: url, newName: name, problem: nil)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let dest = url.deletingLastPathComponent().appending(path: name)
            if trimmed.isEmpty || name == "." || name == ".." {
                row.problem = .empty
            } else if name.contains("/") || name.contains(":") {
                row.problem = .invalidCharacters
            } else if counts[key(dest), default: 0] > 1 {
                row.problem = .duplicate
            } else if !row.isUnchanged, !sources.contains(key(dest)),
                      (try? fm.attributesOfItem(atPath: dest.path(percentEncoded: false))) != nil {
                row.problem = .exists
            }
            return row
        }
    }

    static func key(_ url: URL) -> String { url.normalizedFileURL.path(percentEncoded: false).lowercased() }
}

extension FileActionService {
    /// Renames several items as one action. Handles swaps and chains ("a"->"b", "b"->"c") by
    /// going through temporary names when a new name is another item's current name.
    /// Throws before touching anything if the plan has problems.
    public func renameBatch(_ pairs: [(URL, String)]) throws -> [FileOperation] {
        let rows = BatchRename.validate(pairs.map { ($0.0.normalizedFileURL, $0.1) })
        if let bad = rows.first(where: { $0.problem != nil }) {
            throw FileActionError.invalidName("\(bad.newName) (\(bad.problem!.message))")
        }
        let changing = rows.filter { !$0.isUnchanged }
        let sources = Set(changing.map { BatchRename.key($0.source) })
        let needsTemp = changing.contains { row in
            sources.contains(BatchRename.key(row.destination)) && !Self.caseOnlyChange(row.source, row.destination)
        }
        var ops: [FileOperation] = []
        do {
            if needsTemp {
                var temps: [(URL, URL)] = []
                for row in changing {
                    let temp = row.source.deletingLastPathComponent()
                        .appending(path: ".sift-rename-\(UUID().uuidString.prefix(8))-\(row.source.lastPathComponent)")
                    ops.append(try execute(.rename(from: row.source, to: temp)))
                    temps.append((temp, row.destination))
                }
                for (temp, dest) in temps { ops.append(try execute(.rename(from: temp, to: dest))) }
            } else {
                for row in changing { ops.append(try execute(.rename(from: row.source, to: row.destination))) }
            }
        } catch {
            if ops.isEmpty { throw error }
            throw FileActionError.partial(completed: ops, underlying: error.localizedDescription)
        }
        return ops
    }
}

import Foundation
import UniformTypeIdentifiers

/// What the engine knows about one item. Built from disk with `init(url:)`, or directly in tests.
public struct RuleSubject: Equatable, Sendable {
    public var url: URL
    public var isDirectory: Bool
    public var contentType: String?
    public var size: Int64
    /// When the item arrived: date added to its folder, else creation, else modification date.
    public var dateAdded: Date?
    public var modificationDate: Date?
    public var whereFroms: [String]
    public var tags: [String]

    public init(url: URL, isDirectory: Bool = false, contentType: String? = nil, size: Int64 = 0,
                dateAdded: Date? = nil, modificationDate: Date? = nil, whereFroms: [String] = [], tags: [String] = []) {
        self.url = url.normalizedFileURL
        self.isDirectory = isDirectory
        self.contentType = contentType
        self.size = size
        self.dateAdded = dateAdded
        self.modificationDate = modificationDate
        self.whereFroms = whereFroms
        self.tags = tags
    }

    public init(url: URL) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentTypeKey, .fileSizeKey,
                                         .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey, .tagNamesKey]
        let v = try? url.resourceValues(forKeys: keys)
        self.init(url: url,
                  isDirectory: (v?.isDirectory ?? false) && !(v?.isPackage ?? false),
                  contentType: v?.contentType?.identifier,
                  size: Int64(v?.fileSize ?? 0),
                  dateAdded: v?.addedToDirectoryDate ?? v?.creationDate ?? v?.contentModificationDate,
                  modificationDate: v?.contentModificationDate,
                  whereFroms: WhereFroms.read(url),
                  tags: v?.tagNames ?? [])
    }

    public var name: String { url.lastPathComponent }
}

/// One step the rules want to take, for preview and then `RuleEngine.apply`.
public struct PlannedRuleAction: Identifiable, Equatable, Sendable {
    public var id: URL { source }
    public var ruleID: UUID
    public var ruleName: String
    public var source: URL
    /// The file operation, in FileKit's planned form. Moves name the intended destination;
    /// `apply` resolves name collisions with the caller's policy.
    public var operation: PlannedOperation
    /// Why this step cannot run as planned (missing destination, name taken).
    public var problem: String?

    public var summary: String {
        switch operation {
        case let .move(_, to): "Move to \(RulePaths.string(to.parentFolder))"
        case .trash: "Move to Trash"
        case let .rename(_, to): "Rename to \(to.lastPathComponent)"
        case let .setTags(_, tags): "Tags: \(tags.joined(separator: ", "))"
        default: "\(operation)"
        }
    }
}

/// Pure rule evaluation: first enabled matching rule wins for each item.
public struct RuleEngine: Sendable {
    public var rules: [Rule]
    /// Resolves `{"type": "move", "target": "Name"}`.
    public var targets: [Target]

    public init(rules: [Rule], targets: [Target] = []) {
        self.rules = rules
        self.targets = targets
    }

    public enum RuleError: LocalizedError, Equatable {
        case invalidRegex(rule: String, pattern: String)
        public var errorDescription: String? {
            switch self {
            case let .invalidRegex(rule, pattern): "Rule \"\(rule)\" has an invalid name pattern: \(pattern)"
            }
        }
    }

    /// Throws for rules that can never evaluate (bad regular expressions).
    public func validate() throws {
        for rule in rules { _ = try Self.regex(for: rule) }
    }

    /// Does `rule` match `subject`? Disabled rules never match.
    public static func matches(_ rule: Rule, _ subject: RuleSubject, now: Date = Date()) -> Bool {
        guard rule.enabled, !rule.match.isEmpty else { return false }
        let m = rule.match
        if subject.isDirectory, m.includeFolders != true { return false }
        if let folders = m.folders, !folders.isEmpty {
            let parent = subject.url.parentFolder
            let inside = folders.map(RulePaths.url).contains { $0 == parent || FileActionService.isAncestor($0, of: parent) }
            if !inside { return false }
        }
        if let exts = m.extensions, !exts.isEmpty {
            let ext = subject.url.pathExtension.lowercased()
            let wanted = exts.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }
            if subject.isDirectory || !wanted.contains(ext) { return false }
        }
        if let types = m.types, !types.isEmpty {
            guard let type = subject.contentType.flatMap(UTType.init) else { return false }
            if !types.compactMap(UTType.init).contains(where: { type.conforms(to: $0) }) { return false }
        }
        if let pattern = m.nameRegex, !pattern.isEmpty {
            guard let regex = try? regex(for: rule) else { return false }
            let name = subject.name
            if regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil { return false }
        }
        if let days = m.minAgeDays {
            guard let added = subject.dateAdded, now.timeIntervalSince(added) >= days * 86_400 else { return false }
        }
        if let domains = m.sourceDomains, !domains.isEmpty {
            let hosts = WhereFroms.domains(subject.whereFroms)
            if !hosts.contains(where: { host in domains.contains { WhereFroms.host(host, matches: $0) } }) { return false }
        }
        if let min = m.minSize, subject.size < min { return false }
        if let max = m.maxSize, subject.size > max { return false }
        return true
    }

    /// The first enabled rule that matches.
    public func firstMatch(for subject: RuleSubject, now: Date = Date()) -> Rule? {
        rules.first { Self.matches($0, subject, now: now) }
    }

    /// Plans one step per matching item. Items whose action would change nothing (already in
    /// the destination, already tagged, name unchanged) are left out.
    public func evaluate(_ subjects: [RuleSubject], now: Date = Date(),
                         fileManager fm: FileManager = .default) -> [PlannedRuleAction] {
        var plans: [PlannedRuleAction] = []
        var renameCounters: [UUID: Int] = [:]
        var claimedNames = Set<String>()
        for subject in subjects {
            guard let rule = firstMatch(for: subject, now: now) else { continue }
            var plan = PlannedRuleAction(ruleID: rule.id, ruleName: rule.name, source: subject.url,
                                         operation: .trash(subject.url), problem: nil)
            switch rule.action {
            case .trash:
                break
            case let .move(to):
                guard let folder = destination(to) else {
                    plan.operation = .move(from: subject.url, to: subject.url)
                    plan.problem = "No target named \(to.dropFirst("target:".count))"
                    plans.append(plan)
                    continue
                }
                if folder == subject.url.parentFolder { continue }
                plan.operation = .move(from: subject.url, to: folder.appending(path: subject.name))
                var isDir: ObjCBool = false
                if !fm.fileExists(atPath: folder.path(percentEncoded: false), isDirectory: &isDir) || !isDir.boolValue {
                    plan.problem = "\(RulePaths.string(folder)) does not exist"
                } else if FileActionService.isAncestor(subject.url, of: folder) || subject.url == folder {
                    plan.problem = "Cannot move a folder into itself"
                }
            case let .tag(tags):
                let merged = subject.tags + tags.filter { !subject.tags.contains($0) }
                if merged == subject.tags { continue }
                plan.operation = .setTags(subject.url, merged)
            case let .rename(template):
                let index = renameCounters[rule.id, default: 0]
                renameCounters[rule.id] = index + 1
                let input = RenameTemplate.Input(url: subject.url, isDirectory: subject.isDirectory,
                                                 date: subject.modificationDate ?? subject.dateAdded)
                guard let name = try? RenameTemplate(pattern: template).name(for: input, index: index) else { continue }
                if name == subject.name { continue }
                let dest = subject.url.deletingLastPathComponent().appending(path: name).normalizedFileURL
                plan.operation = .rename(from: subject.url, to: dest)
                let row = BatchRename.validate([(subject.url, name)], fileManager: fm)[0]
                if let problem = row.problem {
                    plan.problem = problem.message
                } else if !claimedNames.insert(BatchRename.key(dest)).inserted {
                    plan.problem = BatchRename.Problem.duplicate.message
                }
            }
            plans.append(plan)
        }
        return plans
    }

    /// Resolves a move destination: a path ("~" allowed) or "target:Name".
    public func destination(_ to: String) -> URL? {
        if to.hasPrefix("target:") {
            let name = String(to.dropFirst("target:".count))
            return targets.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.url.normalizedFileURL
        }
        return RulePaths.url(to)
    }

    /// Runs the planned steps (skipping ones with problems) as one group. Moves use
    /// `policy` for name collisions. Throws `FileActionError.partial` if a step fails after
    /// others completed, so the caller can still journal them.
    public static func apply(_ plans: [PlannedRuleAction], service: FileActionService,
                             onCollision policy: CollisionPolicy) throws -> [FileOperation] {
        var ops: [FileOperation] = []
        do {
            for plan in plans where plan.problem == nil {
                switch plan.operation {
                case let .move(from, to):
                    ops += try service.move([from], into: to.parentFolder, onCollision: policy)
                case let .rename(from, to):
                    if let op = try service.rename(from, to: to.lastPathComponent) { ops.append(op) }
                case .trash, .setTags:
                    ops.append(try service.execute(plan.operation))
                default:
                    continue
                }
            }
        } catch let FileActionError.partial(done, underlying) {
            ops += done
            throw FileActionError.partial(completed: ops, underlying: underlying)
        } catch {
            if ops.isEmpty { throw error }
            throw FileActionError.partial(completed: ops, underlying: error.localizedDescription)
        }
        return ops
    }

    static func regex(for rule: Rule) throws -> NSRegularExpression? {
        guard let pattern = rule.match.nameRegex, !pattern.isEmpty else { return nil }
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            throw RuleError.invalidRegex(rule: rule.name, pattern: pattern)
        }
    }
}

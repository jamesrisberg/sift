import Foundation

/// A declarative rule: when an item matches every condition in `match`, run `action`.
/// Stored in `rules.json` (see `RuleStore`).
public struct Rule: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var match: RuleMatch
    public var action: RuleAction

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, match: RuleMatch = RuleMatch(),
                action: RuleAction = .trash) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.match = match
        self.action = action
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Rule"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        match = try c.decodeIfPresent(RuleMatch.self, forKey: .match) ?? RuleMatch()
        action = try c.decode(RuleAction.self, forKey: .action)
    }
}

/// Match conditions. Every condition that is set must hold (AND); a list condition holds
/// when any entry matches (OR). A rule with no conditions matches nothing, so an empty
/// rule can never sweep a whole folder by accident.
public struct RuleMatch: Codable, Equatable, Hashable, Sendable {
    /// File extensions without the dot, case-insensitive ("pdf", "jpg").
    public var extensions: [String]?
    /// Uniform type identifiers; an item matches if its type conforms to any ("public.image").
    public var types: [String]?
    /// Regular expression searched in the full file name (case-insensitive).
    public var nameRegex: String?
    /// Only items added (or created) at least this many days ago.
    public var minAgeDays: Double?
    /// Download source domains from `kMDItemWhereFroms`; "github.com" also matches subdomains.
    public var sourceDomains: [String]?
    /// Size range in bytes (inclusive).
    public var minSize: Int64?
    public var maxSize: Int64?
    /// Only items inside these folders (at any depth). Paths may start with "~".
    public var folders: [String]?
    /// Match folders too (by default only files and packages match).
    public var includeFolders: Bool?

    public init(extensions: [String]? = nil, types: [String]? = nil, nameRegex: String? = nil,
                minAgeDays: Double? = nil, sourceDomains: [String]? = nil, minSize: Int64? = nil,
                maxSize: Int64? = nil, folders: [String]? = nil, includeFolders: Bool? = nil) {
        self.extensions = extensions
        self.types = types
        self.nameRegex = nameRegex
        self.minAgeDays = minAgeDays
        self.sourceDomains = sourceDomains
        self.minSize = minSize
        self.maxSize = maxSize
        self.folders = folders
        self.includeFolders = includeFolders
    }

    /// True when no content condition is set (`folders` and `includeFolders` only scope).
    public var isEmpty: Bool {
        (extensions ?? []).isEmpty && (types ?? []).isEmpty && (nameRegex ?? "").isEmpty && minAgeDays == nil
            && (sourceDomains ?? []).isEmpty && minSize == nil && maxSize == nil
    }
}

/// What a matching rule does.
public enum RuleAction: Codable, Equatable, Hashable, Sendable {
    /// Move into a folder (path, "~" allowed) or a target by name.
    case move(to: String)
    case trash
    /// Add these Finder tags.
    case tag([String])
    /// Rename with a `RenameTemplate` pattern ("{date} {name}"); the extension is kept.
    case rename(template: String)

    private enum CodingKeys: String, CodingKey { case type, to, target, tags, template }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "move":
            if let to = try c.decodeIfPresent(String.self, forKey: .to) {
                self = .move(to: to)
            } else if let target = try c.decodeIfPresent(String.self, forKey: .target) {
                self = .move(to: "target:\(target)")
            } else {
                throw DecodingError.dataCorruptedError(forKey: .to, in: c, debugDescription: "move needs \"to\" or \"target\"")
            }
        case "trash": self = .trash
        case "tag": self = .tag(try c.decode([String].self, forKey: .tags))
        case "rename": self = .rename(template: try c.decode(String.self, forKey: .template))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown action type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .move(to):
            try c.encode("move", forKey: .type)
            if to.hasPrefix("target:") {
                try c.encode(String(to.dropFirst("target:".count)), forKey: .target)
            } else {
                try c.encode(to, forKey: .to)
            }
        case .trash: try c.encode("trash", forKey: .type)
        case let .tag(tags):
            try c.encode("tag", forKey: .type)
            try c.encode(tags, forKey: .tags)
        case let .rename(template):
            try c.encode("rename", forKey: .type)
            try c.encode(template, forKey: .template)
        }
    }

    public var summary: String {
        switch self {
        case let .move(to):
            to.hasPrefix("target:") ? "Move to \(to.dropFirst("target:".count))" : "Move to \((to as NSString).abbreviatingWithTildeInPath)"
        case .trash: "Move to Trash"
        case let .tag(tags): "Tag \(tags.joined(separator: ", "))"
        case let .rename(template): "Rename to \(template)"
        }
    }
}

/// `rules.json`: the rules plus watch settings.
public struct RuleSet: Codable, Equatable, Sendable {
    public var version: Int
    /// Apply rules automatically when files appear in `watch` folders.
    public var autoApply: Bool
    /// Folders watched for auto-apply ("~/Downloads").
    public var watch: [String]
    public var rules: [Rule]

    public init(version: Int = 1, autoApply: Bool = false, watch: [String] = [], rules: [Rule] = []) {
        self.version = version
        self.autoApply = autoApply
        self.watch = watch
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        autoApply = try c.decodeIfPresent(Bool.self, forKey: .autoApply) ?? false
        watch = try c.decodeIfPresent([String].self, forKey: .watch) ?? []
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
    }

    public var watchURLs: [URL] { watch.map { RulePaths.url($0) } }
}

/// "~" expansion and abbreviation for paths stored in rules.json.
public enum RulePaths {
    public static func url(_ path: String) -> URL {
        URL(filePath: (path as NSString).expandingTildeInPath).normalizedFileURL
    }

    public static func string(_ url: URL) -> String {
        (url.normalizedFileURL.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}

/// Loads and saves `~/Library/Application Support/Sift/rules.json`.
public struct RuleStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = RuleStore.defaultURL) { self.fileURL = fileURL }

    public static var defaultURL: URL {
        TargetStore.defaultURL.deletingLastPathComponent().appending(path: "rules.json")
    }

    /// An empty set when there is no file yet; throws on a corrupt file rather than
    /// silently replacing the user's rules.
    public func load() throws -> RuleSet {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return RuleSet() }
        return try JSONDecoder().decode(RuleSet.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ set: RuleSet) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(set).write(to: fileURL, options: .atomic)
    }
}

import Foundation

/// A favourite folder files can be sent to (successor of DownloadDetox's buckets).
public struct Target: Codable, Identifiable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// "RRGGBB".
    public var colorHex: String
    public var url: URL

    public init(id: UUID = UUID(), name: String, colorHex: String = "7C5CFC", url: URL) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.url = url
    }

    public var exists: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }

    public static let palette = ["7C5CFC", "F472B6", "2DD4BF", "FB923C", "60A5FA", "EF4444", "34D399", "818CF8", "FACC15"]
}

/// Loads and saves targets as JSON (by default `~/Library/Application Support/Sift/targets.json`).
public struct TargetStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = TargetStore.defaultURL) { self.fileURL = fileURL }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "Sift/targets.json")
    }

    private struct FileFormat: Codable {
        var version: Int
        var targets: [Target]
    }

    /// Returns the saved targets, or `defaults` if there is no file yet. Throws on a
    /// corrupt file rather than silently replacing the user's list.
    public func load(defaults: @autoclosure () -> [Target] = TargetStore.defaultTargets()) throws -> [Target] {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return defaults() }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(FileFormat.self, from: data).targets
    }

    public func save(_ targets: [Target]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(FileFormat(version: 1, targets: targets))
        try data.write(to: fileURL, options: .atomic)
    }

    public static func defaultTargets(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Target] {
        [
            Target(name: "Desktop", colorHex: "60A5FA", url: home.appending(path: "Desktop")),
            Target(name: "Documents", colorHex: "7C5CFC", url: home.appending(path: "Documents")),
            Target(name: "Pictures", colorHex: "F472B6", url: home.appending(path: "Pictures")),
        ]
    }
}

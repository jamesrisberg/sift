import Foundation

/// Finder tags, read and written through `URLResourceValues.tagNames` (the same store
/// Finder uses, the `com.apple.metadata:_kMDItemUserTags` extended attribute).
public enum FileTags {
    /// Finder's label colours by index, as stored after the newline in `_kMDItemUserTags`.
    public enum Color: Int, CaseIterable, Sendable {
        case none = 0, gray, green, purple, blue, yellow, red, orange

        /// "RRGGBB" close to Finder's tag dots.
        public var hex: String? {
            switch self {
            case .none: nil
            case .gray: "8E8E93"
            case .green: "34C759"
            case .purple: "AF52DE"
            case .blue: "0A84FF"
            case .yellow: "FFCC00"
            case .red: "FF3B30"
            case .orange: "FF9500"
            }
        }
    }

    /// The seven standard tags in Finder's order.
    public static let standard: [(name: String, color: Color)] = [
        ("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green),
        ("Blue", .blue), ("Purple", .purple), ("Gray", .gray),
    ]

    static let attributeName = "com.apple.metadata:_kMDItemUserTags"

    /// Tag names on the item, in Finder's order. Empty when untagged.
    public static func read(_ url: URL) throws -> [String] {
        var url = url
        url.removeCachedResourceValue(forKey: .tagNamesKey)
        return try url.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []
    }

    /// Replaces the item's tags. Duplicate names are dropped, order is kept.
    public static func write(_ tags: [String], to url: URL) throws {
        var seen = Set<String>()
        let unique = tags.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        // `setResourceValues` takes an NSURL for tag names (URLResourceValues.tagNames is get-only).
        try (url as NSURL).setResourceValue(unique as NSArray, forKey: .tagNamesKey)
    }

    /// Tag colours stored on the item, by name. Tags without a stored colour fall back to the
    /// standard tag of the same name, else `.none`.
    public static func colors(of url: URL) -> [String: Color] {
        var result: [String: Color] = [:]
        let path = url.path(percentEncoded: false)
        let size = getxattr(path, attributeName, nil, 0, 0, XATTR_NOFOLLOW)
        if size > 0 {
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, attributeName, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            if read == size,
               let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                for entry in list {
                    let parts = entry.split(separator: "\n", maxSplits: 1).map(String.init)
                    guard let name = parts.first else { continue }
                    result[name] = parts.count > 1 ? Color(rawValue: Int(parts[1]) ?? 0) ?? .none : .none
                }
            }
        }
        for (name, color) in result where color == .none {
            result[name] = standardColor(for: name)
        }
        return result
    }

    /// Colour of a standard tag name ("Red" -> .red), `.none` for custom names.
    public static func standardColor(for name: String) -> Color {
        standard.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.color ?? .none
    }
}

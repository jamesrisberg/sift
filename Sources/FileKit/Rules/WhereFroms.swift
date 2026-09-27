import Foundation

/// Reads the download source recorded by browsers in the `com.apple.metadata:kMDItemWhereFroms`
/// extended attribute (a binary plist array: usually the file URL, then the referring page).
public enum WhereFroms {
    static let attributeName = "com.apple.metadata:kMDItemWhereFroms"

    public static func read(_ url: URL) -> [String] {
        let path = url.path(percentEncoded: false)
        let size = getxattr(path, attributeName, nil, 0, 0, 0)
        guard size > 0 else { return [] }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, attributeName, $0.baseAddress, size, 0, 0) }
        guard read == size,
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String] else { return [] }
        return list
    }

    /// Writes the attribute (for tests and for tools that want to tag provenance).
    public static func write(_ sources: [String], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: sources, format: .binary, options: 0)
        let result = data.withUnsafeBytes {
            setxattr(url.path(percentEncoded: false), attributeName, $0.baseAddress, data.count, 0, 0)
        }
        if result != 0 { throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url]) }
    }

    /// Host names of the recorded sources, lowercased ("github.com", "objects.githubusercontent.com").
    public static func domains(_ sources: [String]) -> [String] {
        sources.compactMap { URL(string: $0)?.host()?.lowercased() }
    }

    /// True when `host` is `domain` or a subdomain of it.
    public static func host(_ host: String, matches domain: String) -> Bool {
        let host = host.lowercased(), domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == domain || host.hasSuffix("." + domain)
    }
}

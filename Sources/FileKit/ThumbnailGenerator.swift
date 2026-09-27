import Foundation
import CoreGraphics
import QuickLookThumbnailing

/// Quick Look thumbnails with an in-memory cache keyed by URL and modification date, so an
/// edited file gets a fresh thumbnail while unchanged files never regenerate.
public final class ThumbnailGenerator: @unchecked Sendable {
    private let cache = NSCache<NSString, CGImageBox>()
    public let size: CGSize
    public let scale: CGFloat

    public init(size: CGSize = CGSize(width: 128, height: 128), scale: CGFloat = 2, countLimit: Int = 800) {
        self.size = size
        self.scale = scale
        cache.countLimit = countLimit
    }

    public static func cacheKey(for url: URL, modified: Date?) -> String {
        "\(url.path(percentEncoded: false))|\(modified?.timeIntervalSinceReferenceDate ?? 0)"
    }

    public func cached(for url: URL, modified: Date?) -> CGImage? {
        cache.object(forKey: Self.cacheKey(for: url, modified: modified) as NSString)?.image
    }

    /// Returns nil when Quick Look cannot produce a thumbnail; callers fall back to the
    /// Finder icon (kept out of FileKit so it stays UI-free).
    public func thumbnail(for url: URL, modified: Date?) async -> CGImage? {
        let key = Self.cacheKey(for: url, modified: modified) as NSString
        if let hit = cache.object(forKey: key) { return hit.image }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: size, scale: scale, representationTypes: .thumbnail
        )
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = rep.cgImage
        cache.setObject(CGImageBox(image), forKey: key)
        return image
    }

    public func clearCache() { cache.removeAllObjects() }
}

final class CGImageBox {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

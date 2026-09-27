import Foundation

/// Filter and sort settings for a listing. A value type so it is trivially testable and
/// can be stored per pane.
public struct FilterCriteria: Equatable, Sendable {
    public var searchText: String = ""
    public var categories: Set<FileCategory> = []
    public var dateRange: DateRange = .all
    public var sizeRange: SizeRange = .all
    /// Finder tags; an item passes when it has any of them.
    public var tags: Set<String> = []
    public var sortBy: SortField = .name
    public var sortAscending: Bool = true
    public var foldersFirst: Bool = true

    public init() {}

    public enum DateRange: String, CaseIterable, Sendable {
        case all = "All Time"
        case today = "Today"
        case thisWeek = "This Week"
        case thisMonth = "This Month"
        case older = "Older"

        public func matches(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
            guard let date else { return self == .all }
            switch self {
            case .all: return true
            case .today: return calendar.isDate(date, inSameDayAs: now)
            case .thisWeek: return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
            case .thisMonth: return calendar.isDate(date, equalTo: now, toGranularity: .month)
            case .older: return !calendar.isDate(date, equalTo: now, toGranularity: .month)
            }
        }
    }

    public enum SizeRange: String, CaseIterable, Sendable {
        case all = "Any Size"
        case tiny = "< 1 MB"
        case small = "1-10 MB"
        case medium = "10-100 MB"
        case large = "100 MB-1 GB"
        case huge = "> 1 GB"

        public func matches(_ size: Int64) -> Bool {
            let mb: Int64 = 1_000_000, gb: Int64 = 1_000_000_000
            switch self {
            case .all: return true
            case .tiny: return size < mb
            case .small: return size >= mb && size < 10 * mb
            case .medium: return size >= 10 * mb && size < 100 * mb
            case .large: return size >= 100 * mb && size < gb
            case .huge: return size >= gb
            }
        }
    }

    public enum SortField: String, CaseIterable, Sendable {
        case name = "Name"
        case modificationDate = "Date Modified"
        case fileSize = "Size"
        case category = "Kind"
    }

    public var isActive: Bool {
        !searchText.isEmpty || !categories.isEmpty || dateRange != .all || sizeRange != .all || !tags.isEmpty
    }

    public mutating func reset() {
        searchText = ""
        categories = []
        dateRange = .all
        sizeRange = .all
        tags = []
    }

    public func matches(_ item: FileItem, now: Date = Date()) -> Bool {
        if !searchText.isEmpty,
           item.name.range(of: searchText, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        if !categories.isEmpty, !categories.contains(item.category) { return false }
        if !tags.isEmpty, !item.tagNames.contains(where: tags.contains) { return false }
        if dateRange != .all, !dateRange.matches(item.modificationDate ?? item.creationDate, now: now) { return false }
        // Size ranges only make sense for files; folders pass through.
        if sizeRange != .all, !item.isBrowsable, !sizeRange.matches(item.fileSize) { return false }
        return true
    }

    /// Filters then sorts. Sorting is stable with name as the tie-breaker so the order
    /// does not jump around between rescans.
    public func apply(to items: [FileItem], now: Date = Date()) -> [FileItem] {
        items.filter { matches($0, now: now) }.sorted(by: areInIncreasingOrder)
    }

    public func areInIncreasingOrder(_ a: FileItem, _ b: FileItem) -> Bool {
        if foldersFirst, a.isBrowsable != b.isBrowsable { return a.isBrowsable }
        let order: ComparisonResult
        switch sortBy {
        case .name:
            order = a.name.localizedStandardCompare(b.name)
        case .modificationDate:
            order = Self.compare(a.modificationDate ?? .distantPast, b.modificationDate ?? .distantPast)
        case .fileSize:
            order = Self.compare(a.fileSize, b.fileSize)
        case .category:
            order = a.category.displayName.localizedStandardCompare(b.category.displayName)
        }
        if order == .orderedSame {
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return sortAscending ? order == .orderedAscending : order == .orderedDescending
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
}

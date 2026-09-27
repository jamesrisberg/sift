import Foundation

/// Arrow-key movement over a row-major grid (a list is a grid with one column).
public enum GridNavigation {
    public enum Direction: Sendable { case up, down, left, right, home, end }

    /// New focus index, or nil if there are no items. With no current focus, any key
    /// selects the first item (or last for `.end`/`.up`).
    public static func move(from index: Int?, _ direction: Direction, columns: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let cols = max(1, columns)
        guard let i = index, i >= 0, i < count else {
            switch direction {
            case .end, .up: return count - 1
            default: return 0
            }
        }
        switch direction {
        case .left: return max(0, i - 1)
        case .right: return min(count - 1, i + 1)
        case .up: return i - cols >= 0 ? i - cols : i
        case .down: return i + cols < count ? i + cols : (i / cols < (count - 1) / cols ? count - 1 : i)
        case .home: return 0
        case .end: return count - 1
        }
    }
}

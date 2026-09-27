import AppKit
import HUDKit

/// The screen edge the dock strip runs along. The strip's place is a `HUDDockPosition`
/// (setting `dock.position`): the middle of an edge, or a corner, where Sift's strip runs
/// along the vertical edge starting at the corner (no L).
enum DockEdge: String, CaseIterable, Codable, Sendable {
    case bottom, top, left, right

    init(position: HUDDockPosition) {
        switch position {
        case .bottom: self = .bottom
        case .top: self = .top
        case .left, .topLeft, .bottomLeft: self = .left
        case .right, .topRight, .bottomRight: self = .right
        }
    }

    /// Tiles run left to right along a bottom or top strip, top to bottom along a side one.
    var isHorizontal: Bool { self == .bottom || self == .top }

    /// Unit vector pointing away from the edge, into the screen: where the drawer opens.
    var outward: CGVector {
        switch self {
        case .bottom: CGVector(dx: 0, dy: 1)
        case .top: CGVector(dx: 0, dy: -1)
        case .left: CGVector(dx: 1, dy: 0)
        case .right: CGVector(dx: -1, dy: 0)
        }
    }

    var hudEdge: HUDEdge {
        switch self {
        case .bottom: .bottom
        case .top: .top
        case .left: .left
        case .right: .right
        }
    }
}

extension HUDDockPosition {
    /// Menu title ("Top Left").
    var title: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .left: "Left"
        case .right: "Right"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    /// Menu order: the edges, then the corners.
    static let menuOrder: [HUDDockPosition] = [.bottom, .top, .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight]
}

/// Geometry of the dock strip and its drawer. Pure so it can be tested: tile frames are in
/// the strip's own AppKit coordinates (origin bottom-left); strip and drawer frames are AppKit
/// screen coordinates (origin bottom-left) inside a screen's visible frame.
///
/// The strip is the MacHUD tool dock's (`HUDDockStripView`, `HUDDockStyle.standard`): 64 pt
/// thick, 44 pt tiles, 10 pt padding, 6 pt spacing, dividers between the groups Trash |
/// Downloads, the targets | "+". When the run is longer than the edge the tiles shrink to fit,
/// as the tool dock's do.
///
/// Other docks (the MacHUD dock, from `HUDDockRegistry`) are passed in as `others`: the strip
/// slides along its edge to clear any that share its lane, and the drawer opens away from them.
struct DockLayout: Equatable {
    /// Space between the strip and the screen edge.
    static let screenMargin: CGFloat = 6
    /// Space kept between the strip (or drawer) and another dock along the edge.
    static let dockGap: CGFloat = 6
    /// Space between the strip and the drawer.
    static let drawerGap: CGFloat = 8
    /// Drawer size above a bottom strip and beside a side strip.
    static let horizontalDrawer = CGSize(width: 640, height: 400)
    static let verticalDrawer = CGSize(width: 372, height: 540)
    /// How far the drawer travels while sliding out from behind the strip.
    static let drawerSlide: CGFloat = 44

    var position: HUDDockPosition
    /// Tile counts per group; a divider sits between non-empty groups.
    var groups: [Int]
    /// The strip's look: the tool dock's, shrunk by `fitted(in:)` when it would not fit.
    var style: HUDDockStyle

    var edge: DockEdge { DockEdge(position: position) }

    init(position: HUDDockPosition, groups: [Int], style: HUDDockStyle = .standard) {
        self.position = position
        self.groups = groups.map { max(0, $0) }
        self.style = style
    }

    /// The standard strip: Trash | Downloads, targets | +.
    static func standard(position: HUDDockPosition, targetCount: Int) -> DockLayout {
        DockLayout(position: position, groups: [1, 1 + max(0, targetCount), 1])
    }

    var tileCount: Int { groups.reduce(0, +) }
    /// Across the edge: 64 pt with 44 pt tiles.
    var thickness: CGFloat { style.thickness }

    // MARK: - Tiles (strip coordinates)

    /// Tile frames and dividers in the strip's own coordinates (AppKit, origin bottom-left).
    var placement: HUDDockPlacement {
        style.run(groups: groups, in: CGRect(origin: .zero, size: contentSize), edge: edge.hudEdge)
    }

    var tileFrames: [CGRect] { placement.items }

    func tileFrame(_ index: Int) -> CGRect { tileFrames[index] }

    /// Length of the content along the strip.
    var contentLength: CGFloat { style.runLength(groups: groups) }

    /// Content size in strip coordinates.
    var contentSize: CGSize {
        edge.isHorizontal ? CGSize(width: contentLength, height: thickness)
            : CGSize(width: thickness, height: contentLength)
    }

    /// The index of the tile at `point` (strip coordinates), if any.
    func tile(at point: CGPoint) -> Int? {
        tileFrames.firstIndex { $0.contains(point) }
    }

    /// This layout with its tiles shrunk (never grown) so the strip fits along its edge of
    /// `visible`, as `HUDDockStripView` shrinks them in a strip that length.
    func fitted(in visible: CGRect) -> DockLayout {
        let m = 2 * Self.screenMargin
        var l = self
        l.style = style.fitted(groups: groups, position: HUDDockPosition(edge: edge.hudEdge),
                               span: CGSize(width: visible.width - m, height: visible.height - m))
        return l
    }

    // MARK: - Strip (screen coordinates)

    /// The strip on `visible` (a screen's visible frame) with no other docks around: centred
    /// on its edge, or starting at its corner, `screenMargin` in from the screen's edges, its
    /// tiles shrunk if the edge is too short for them (`fitted(in:)`).
    func stripFrame(in visible: CGRect) -> CGRect {
        let m = Self.screenMargin
        let fit = fitted(in: visible)
        var frame = HUDDockLayout.frame(for: HUDDockPosition(edge: edge.hudEdge), thickness: fit.thickness,
                                        length: fit.contentLength, insets: NSEdgeInsets(top: m, left: m, bottom: m, right: m),
                                        in: visible)
        switch position {
        case .topLeft, .topRight: frame.origin.y = max(visible.minY + m, visible.maxY - m - frame.height)
        case .bottomLeft, .bottomRight: frame.origin.y = visible.minY + m
        default: break
        }
        return frame
    }

    /// `stripFrame(in:)` slid along the edge so it keeps `dockGap` clear of every frame in
    /// `others` that shares its lane (`HUDDockLayout.avoiding`). Unchanged when nothing is in
    /// the way, or when there is no room to get clear.
    func stripFrame(in visible: CGRect, avoiding others: [CGRect]) -> CGRect {
        let ideal = stripFrame(in: visible)
        guard !others.isEmpty else { return ideal }
        return HUDDockLayout.avoiding(frame: ideal, others: padded(others), along: edge.hudEdge, in: lane(visible))
    }

    /// Where a strip dropped at `frame` snaps to (`HUDDockPosition.nearest` of its centre).
    static func snap(_ frame: CGRect, in visible: CGRect) -> HUDDockPosition {
        HUDDockPosition.nearest(to: CGPoint(x: frame.midX, y: frame.midY), in: visible)
    }

    // MARK: - Drawer (screen coordinates)

    /// The open drawer for a strip at `strip`: beside it on the screen side and kept inside
    /// `visible`. Along the edge it is centred on the strip, unless another dock in `others`
    /// sits in the strip's lane: then it lines up with the strip's far end from the nearest such
    /// dock, so it opens away from it. It never covers a frame in `others` if it can slide clear.
    func drawerFrame(strip: CGRect, in visible: CGRect, avoiding others: [CGRect] = []) -> CGRect {
        let margin = Self.screenMargin
        let gap = Self.drawerGap
        var frame: CGRect
        switch edge {
        case .bottom, .top:
            let width = min(Self.horizontalDrawer.width, visible.width - 2 * margin)
            let room = edge == .bottom ? visible.maxY - margin - (strip.maxY + gap) : (strip.minY - gap) - (visible.minY + margin)
            let height = max(0, min(Self.horizontalDrawer.height, room))
            let y = edge == .bottom ? strip.maxY + gap : strip.minY - gap - height
            frame = CGRect(x: strip.midX - width / 2, y: y, width: width, height: height)
        case .left, .right:
            let height = min(Self.verticalDrawer.height, visible.height - 2 * margin)
            let room = edge == .left ? visible.maxX - margin - (strip.maxX + gap) : (strip.minX - gap) - (visible.minX + margin)
            let width = max(0, min(Self.verticalDrawer.width, room))
            let x = edge == .left ? strip.maxX + gap : strip.minX - gap - width
            frame = CGRect(x: x, y: strip.midY - height / 2, width: width, height: height)
        }
        let horizontal = edge.isHorizontal
        if let side = neighbourSide(of: strip, among: others) {
            // Line the drawer up with the strip's end away from the neighbouring dock.
            if horizontal {
                frame.origin.x = side < 0 ? strip.minX : strip.maxX - frame.width
            } else {
                frame.origin.y = side < 0 ? strip.minY : strip.maxY - frame.height
            }
        }
        if horizontal {
            frame.origin.x = clamp(frame.minX, visible.minX + margin, visible.maxX - margin - frame.width)
        } else {
            frame.origin.y = clamp(frame.minY, visible.minY + margin, visible.maxY - margin - frame.height)
        }
        guard !others.isEmpty else { return frame }
        return HUDDockLayout.avoiding(frame: frame, others: padded(others), along: edge.hudEdge, in: lane(visible))
    }

    /// Which side of `strip` (along the edge) the nearest other dock in its lane is on: -1 for
    /// the low side (left, or below), +1 for the high side; nil when none shares the lane.
    func neighbourSide(of strip: CGRect, among others: [CGRect]) -> CGFloat? {
        let horizontal = edge.isHorizontal
        let lane = others.filter { o in
            guard !o.isNull, !o.isEmpty else { return false }
            return horizontal ? min(o.maxY, strip.maxY) - max(o.minY, strip.minY) > 0
                : min(o.maxX, strip.maxX) - max(o.minX, strip.minX) > 0
        }
        let mid = horizontal ? strip.midX : strip.midY
        let nearest = lane.min { a, b in
            abs((horizontal ? a.midX : a.midY) - mid) < abs((horizontal ? b.midX : b.midY) - mid)
        }
        return nearest.map { ((horizontal ? $0.midX : $0.midY) < mid) ? -1 : 1 }
    }

    /// Where the drawer starts (and returns to): tucked toward the strip, so opening slides
    /// it out perpendicular to the edge.
    func drawerTuckedFrame(for open: CGRect) -> CGRect {
        let v = edge.outward
        return open.offsetBy(dx: -v.dx * Self.drawerSlide, dy: -v.dy * Self.drawerSlide)
    }

    /// `others` grown by `dockGap` along the edge, so avoiding them leaves a gap.
    private func padded(_ others: [CGRect]) -> [CGRect] {
        others.map { edge.isHorizontal ? $0.insetBy(dx: -Self.dockGap, dy: 0) : $0.insetBy(dx: 0, dy: -Self.dockGap) }
    }

    /// The space a strip or drawer may use: the visible frame less the screen margin.
    private func lane(_ visible: CGRect) -> CGRect {
        visible.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        high < low ? low : min(max(value, low), high)
    }
}

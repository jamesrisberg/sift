import HUDKit
import SwiftUI

/// Sift's line and type scale: hairlines rather than borders, one card radius, small
/// secondary text. Everything sits on HUD glass, so lines are white at low alpha.
enum Theme {
    /// Hairline colour: white at 12 %.
    static let hairline = Color.white.opacity(0.12)
    static let hairlineAlpha: CGFloat = 0.12
    /// Cards, cells, tiles in the drawer.
    static let cardRadius: CGFloat = 8
    /// Toolbar buttons and fields.
    static let controlHeight: CGFloat = 28
    /// Secondary text (sizes, counts, footers).
    static let secondaryFont = Font.system(size: 11)
    /// The purple DownloadDetox used for Downloads.
    static let downloadsHex = "7C5CFC"
    static let trashHex = "EF4444"

    /// The browser: square-ish glass with a 1 px hairline.
    static let fullGlass = HUDGlassView.Style(cornerRadius: 14, borderWidth: 0.5, borderAlpha: hairlineAlpha, gloss: false)
    /// The dock drawer (the strip itself is HUDKit's `HUDDockStripView`): HUDKit's strip glass
    /// with a 12 pt corner.
    static let stripGlass: HUDGlassView.Style = {
        var style = HUDGlassView.Style.strip
        style.cornerRadius = 12
        style.borderAlpha = hairlineAlpha
        return style
    }()
}

/// A 1 px line (half a point on Retina) in the hairline colour.
struct Hairline: View {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: axis == .vertical ? 1 / scale : nil, height: axis == .horizontal ? 1 / scale : nil)
    }
}

extension View {
    /// A hairline rounded-rect border drawn inside the shape.
    func hairlineBorder(cornerRadius: CGFloat, color: Color = Theme.hairline) -> some View {
        modifier(HairlineBorder(cornerRadius: cornerRadius, color: color))
    }
}

private struct HairlineBorder: ViewModifier {
    let cornerRadius: CGFloat
    let color: Color
    @Environment(\.displayScale) private var scale

    func body(content: Content) -> some View {
        content.overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(color, lineWidth: 1 / scale))
    }
}

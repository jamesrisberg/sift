import Foundation
import HUDKit

/// How the panel appears or goes away, from the options MacHUD's dock sends with
/// `panel show` / `panel hide` (`HUDPanelTransition`). Pure, so the choice is testable.
///
/// | options | show | hide |
/// |---|---|---|
/// | `reason=hover` | fade in where it rests, 0.08 s, no keyboard focus | fade out in 0.1 s (drifting toward `to=` if given) |
/// | `from=` / `to=` | slide out of that edge, 0.22 s (`HUDAnimation.slide(in:)`) | slide back toward it, 0.18 s |
/// | neither | fade in, 0.22 s | fade out, 0.18 s |
struct PanelMotion: Equatable {
    /// The dock edge the panel slides out of (show) or back toward (hide); nil: fade in place.
    var edge: HUDEdge?
    var duration: TimeInterval

    /// Hover shows must feel instant: MacHUD cross-fades between hover panels as the pointer
    /// moves along its dock.
    static let hoverFadeIn: TimeInterval = 0.08
    static let hoverFadeOut: TimeInterval = 0.1

    static func show(_ t: HUDPanelTransition) -> PanelMotion {
        if t.reason == .hover { return PanelMotion(edge: nil, duration: hoverFadeIn) }
        return PanelMotion(edge: t.from, duration: HUDAnimation.revealDuration)
    }

    static func hide(_ t: HUDPanelTransition) -> PanelMotion {
        PanelMotion(edge: t.to, duration: t.reason == .hover ? hoverFadeOut : HUDAnimation.concealDuration)
    }

    /// Hover shows never take keyboard focus (the pointer is only passing over the dock);
    /// clicks, summons and plain shows do.
    static func takesFocus(_ t: HUDPanelTransition) -> Bool { HUDPanelWindow.takesFocus(t) }
}

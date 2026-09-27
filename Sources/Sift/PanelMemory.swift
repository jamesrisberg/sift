import AppKit
import HUDKit

/// Setting `launchMode`: open as the dock strip, as the full browser, or as it was last.
enum LaunchMode: String, CaseIterable, Sendable {
    case dock, full, last

    func mode(last: HUDPanelMode) -> HUDPanelMode {
        switch self {
        case .dock: .compact
        case .full: .full
        case .last: last == .parked ? .full : last
        }
    }
}

/// What the panel remembers between dismissals and launches: the browser's frame, the mode
/// it was last in, how it opens at launch, and where the dock strip sits. Backed by UserDefaults (injectable for tests).
struct PanelMemory {
    static let fullFrameKey = "SiftFullFrame"
    static let modeKey = "SiftPanelMode"
    static let dockPositionKey = "dock.position"
    static let launchModeKey = "launchMode"

    let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
    }

    /// The browser's last frame (full mode).
    var fullFrame: CGRect? {
        get {
            guard let string = defaults.string(forKey: Self.fullFrameKey) else { return nil }
            let rect = NSRectFromString(string)
            return rect.width > 0 && rect.height > 0 ? rect : nil
        }
        nonmutating set {
            if let newValue { defaults.set(NSStringFromRect(newValue), forKey: Self.fullFrameKey) }
            else { defaults.removeObject(forKey: Self.fullFrameKey) }
        }
    }

    /// Full or compact: parking is transient and never remembered.
    var mode: HUDPanelMode {
        get { defaults.string(forKey: Self.modeKey).flatMap(HUDPanelMode.init(rawValue:)).flatMap { $0 == .parked ? nil : $0 } ?? .full }
        nonmutating set { if newValue != .parked { defaults.set(newValue.rawValue, forKey: Self.modeKey) } }
    }

    /// How Sift opens at launch (setting `launchMode`); dock mode unless changed.
    var launchMode: LaunchMode {
        get { defaults.string(forKey: Self.launchModeKey).flatMap(LaunchMode.init(rawValue:)) ?? .dock }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.launchModeKey) }
    }

    /// The mode the panel starts in: `launchMode`, with `last` meaning the remembered `mode`.
    var initialMode: HUDPanelMode { launchMode.mode(last: mode) }

    /// Where the dock strip sits (setting `dock.position`, one of the eight `HUDDockPosition`s).
    var dockPosition: HUDDockPosition {
        get { defaults.string(forKey: Self.dockPositionKey).flatMap(HUDDockPosition.init(rawValue:)) ?? .bottom }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.dockPositionKey) }
    }

    /// Where a summoned browser appears: its remembered frame (or the frame it was dismissed
    /// at) when that is still on one of `screens`, else nil (the caller centres it).
    static func summonFrame(remembered: CGRect?, dismissedAt: CGRect, screens: [CGRect]) -> CGRect? {
        for candidate in [remembered, dismissedAt].compactMap({ $0 }) where candidate.width > 0 && candidate.height > 0 {
            if screens.contains(where: { $0.intersects(candidate) }) { return candidate }
        }
        return nil
    }
}

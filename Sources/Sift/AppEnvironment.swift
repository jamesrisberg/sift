import FileKit
import Foundation
import HUDKit

/// Isolation switches for tests and parallel instances (so a trial run never touches the
/// real Sift's files, preferences or socket):
///
/// - `SIFT_HOME`: base directory for an isolated instance: rules in `<home>/rules.json`,
///   targets in `<home>/targets.json` (unless `SIFT_TARGETS_FILE`), the dock registry in
///   `<home>/docks.json` (unless `SIFT_DOCKS_FILE`) and preferences in a separate defaults suite.
///   The `menuBar.consumed` opt-out is kept in `<home>/menubar.json` (`dataDirectory`).
/// - `SIFT_TARGETS_FILE`: another targets.json.
/// - `SIFT_DOCKS_FILE`: another `docks.json` (`HUDDockRegistry`), e.g. a fake MacHUD dock.
/// - `SIFT_SOCKET`: socket name under MacHUD's sockets directory; default `sift` (the `sift`
///   CLI honours it too).
/// - `SIFT_NO_HOTKEYS`: set to skip registering the global hotkey.
enum AppEnvironment {
    static let environment = ProcessInfo.processInfo.environment

    private static func value(_ key: String) -> String? {
        environment[key].flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
    }

    static var home: URL? { value("SIFT_HOME").map { URL(filePath: $0, directoryHint: .isDirectory) } }

    static var targetsURL: URL {
        value("SIFT_TARGETS_FILE").map { URL(filePath: $0) }
            ?? home?.appending(path: "targets.json") ?? TargetStore.defaultURL
    }

    static var rulesURL: URL { home?.appending(path: "rules.json") ?? RuleStore.defaultURL }

    /// Where Sift keeps its files: `SIFT_HOME`, else `~/Library/Application Support/Sift`.
    static var dataDirectory: URL { home ?? TargetStore.defaultURL.deletingLastPathComponent() }

    static var docksURL: URL {
        value("SIFT_DOCKS_FILE").map { URL(filePath: $0) }
            ?? home?.appending(path: "docks.json") ?? HUDDockRegistry.defaultURL
    }

    /// The app's defaults, or a separate suite when `SIFT_HOME` isolates this instance.
    static let defaults: UserDefaults = home == nil
        ? .standard
        : UserDefaults(suiteName: "xyz.machud.sift.isolated") ?? .standard

    static var socketName: String { environment["SIFT_SOCKET"].flatMap { $0.isEmpty ? nil : $0 } ?? "sift" }

    static var hotKeysEnabled: Bool { environment["SIFT_NO_HOTKEYS"] == nil }
}

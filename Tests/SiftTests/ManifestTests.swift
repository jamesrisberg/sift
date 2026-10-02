import Foundation
import HUDKit
import XCTest
@testable import Sift

/// The shipped machud.json, settings.json and Info.plist are what MacHUD reads without launching
/// Sift; keep them valid and in step with the code.
final class ManifestTests: XCTestCase {
    private var resources: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/Sift/Resources")
    }

    func testManifestDecodes() throws {
        let manifest = try HUDManifest.decode(Data(contentsOf: resources.appending(path: HUDManifest.fileName)))
        XCTAssertEqual(manifest.id, "xyz.machud.sift")
        XCTAssertEqual(manifest.socket, "sift")
        let panel = try XCTUnwrap(manifest.panel(id: "browser"))
        XCTAssertEqual(panel.defaultSize, HUDSize(width: 900, height: 560))
        XCTAssertEqual(panel.compactSize, HUDSize(width: 340, height: 64), "the dock strip along the bottom with three targets")
        XCTAssertEqual(panel.kind, .windowed, "MacHUD places, parks, dismisses and summons the browser")
        XCTAssertEqual(panel.capabilities, ["acceptsFileDrop"])
        for verb in ["show", "hide", "toggle", "frame", "mode", "navigate", "reveal", "send"] { XCTAssertTrue(panel.verbs.contains(verb), verb) }
        let schema = try XCTUnwrap(panel.settingsSchema)
        let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: resources.appending(path: schema))) as? [String: Any]
        let keys = (settings?["settings"] as? [[String: Any]])?.compactMap { $0["key"] as? String }
        // HUDKit's router serves `settings schema` from this file (HUDSettingsSchema.main), so it must decode.
        XCTAssertNoThrow(try HUDSettingsSchema.decode(Data(contentsOf: resources.appending(path: schema))))
        XCTAssertEqual(Set(keys ?? []), ["defaultFolder", "collisionPolicy", "showHidden", "rulesAutoApply", "launchMode", "dock.position"])
    }

    func testPanelKindDecodes() throws {
        func kind(_ json: String) throws -> HUDManifest.Panel.Kind {
            try JSONDecoder().decode(HUDManifest.Panel.self, from: Data(json.utf8)).kind
        }
        XCTAssertEqual(try kind(#"{"id": "browser", "kind": "windowed"}"#), .windowed)
        XCTAssertEqual(try kind(#"{"id": "peek", "kind": "hover"}"#), .hover)
        XCTAssertEqual(try kind(#"{"id": "old"}"#), .windowed, "manifests from before 0.3 are windowed")
        XCTAssertEqual(try kind(#"{"id": "x", "kind": "floating"}"#), .unknown("floating"), "HUDKit 0.3 keeps an unknown kind, never reads it as windowed")
        XCTAssertEqual(try kind(#"{"id": "w", "kind": "widget"}"#), .widget)
        let unknown = try JSONDecoder().decode(HUDManifest.Panel.self, from: Data(#"{"id": "x", "kind": "floating"}"#.utf8))
        XCTAssertFalse(unknown.kind.isKnown)
        XCTAssertTrue(HUDManifest.dockSorted([unknown]).isEmpty, "an unknown kind is not a dock panel")

        let manifest = try HUDManifest.decode(Data(contentsOf: resources.appending(path: HUDManifest.fileName)))
        let roundTrip = try HUDManifest.decode(manifest.encoded())
        XCTAssertEqual(roundTrip.panel(id: "browser")?.kind, .windowed, "kind survives encoding (the hello reply)")
        XCTAssertEqual(manifest.panel(id: "browser")?.order, 1, "first windowed button in the MacHUD dock")
        XCTAssertEqual(roundTrip.panel(id: "browser")?.order, 1)
    }

    @MainActor
    func testBuiltinManifestMirrorsTheFile() throws {
        XCTAssertEqual(ControlHost.builtinManifest, try HUDManifest.decode(Data(contentsOf: resources.appending(path: HUDManifest.fileName))))
    }

    func testInfoPlist() throws {
        let data = try Data(contentsOf: resources.appending(path: "Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, try HUDManifest.decode(Data(contentsOf: resources.appending(path: HUDManifest.fileName))).id)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "Sift")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertNotNil(plist["NSHumanReadableCopyright"])
    }
}

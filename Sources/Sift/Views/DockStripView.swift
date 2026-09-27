import AppKit
import FileKit
import HUDKit
import SwiftUI

/// Dock mode: a strip against a screen edge (DownloadDetox's dock, reborn) that is the
/// MacHUD tool dock's strip (`HUDDockStrip`): Trash | Downloads, the targets | "+", each a
/// 44 pt tile (targets: a folder in the target's colour) named by a hover label, the open
/// drawer's tile marked by the accent dot on the edge side. Drop files on a tile to move
/// them there (Option copies); click a tile to slide its drawer out. Drag the strip by its
/// background to one of the eight positions.
struct DockStripView: View {
    @Bindable var model: AppModel

    enum Tile {
        case trash, downloads, target(Target, index: Int), add

        var id: String {
            switch self {
            case .trash: "trash"
            case .downloads: "downloads"
            case let .target(target, _): target.id.uuidString
            case .add: "add"
            }
        }
    }

    private var tiles: [Tile] {
        [.trash, .downloads] + model.targets.enumerated().map { Tile.target($1, index: $0) } + [.add]
    }

    var body: some View {
        let layout = DockLayout.standard(position: model.dockPosition, targetCount: model.targets.count)
        let tiles = tiles
        HUDDockStrip(items: tiles.map(item), groups: layout.groups, edge: layout.edge.hudEdge,
                     onClick: { item, _ in tile(item, in: tiles).map(click) },
                     menu: { item in item.map { tile($0, in: tiles).flatMap(menu) } ?? stripMenu() },
                     validateDrop: { urls, item in
                         guard case .add? = tile(item, in: tiles) else { return true }
                         return urls.contains(where: Self.isFolder)
                     },
                     onDrop: { urls, item, copy in tile(item, in: tiles).map { drop(urls, on: $0, copy: copy) } },
                     onDragEnd: { position, _, _ in model.dock?.moveDock(to: position) })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                // Errors only: success is visible in the counts, and a toast would cover the tiles.
                if let status = model.status, status.isError {
                    Text(status.text)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundStyle(.red)
                        .allowsHitTesting(false)
                }
            }
    }

    private func tile(_ item: HUDDockItem, in tiles: [Tile]) -> Tile? { tiles.first { $0.id == item.id } }

    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func color(_ hex: String) -> NSColor {
        Color(hex: hex).map { NSColor($0) } ?? .controlAccentColor
    }

    /// The strip item for a tile: a symbol tile like the tool dock's, the glyph in the tile's
    /// colour. Its name shows as the strip's hover label (the title's first segment, a
    /// target's name); labelled tiles have no native tooltip.
    private func item(_ tile: Tile) -> HUDDockItem {
        switch tile {
        case .trash:
            return HUDDockItem(id: tile.id, title: "Trash: drop files to move them to the Trash; click to open it in Finder",
                               content: .glyph("trash.fill", color: Self.color(Theme.trashHex)), acceptsDrop: true)
        case .downloads:
            let url = FileScanner.downloadsURL
            return HUDDockItem(id: tile.id, title: "Downloads: click to open the drawer; drop files to move them here (Option copies)",
                               content: .glyph("arrow.down", color: Self.color(Theme.downloadsHex)),
                               indicator: model.drawer.isShowing(url) ? .visible : .none, acceptsDrop: true)
        case let .target(target, index):
            return HUDDockItem(id: tile.id,
                               title: "\(target.name)\(index < 9 ? " (\(index + 1))" : ""): click to open the drawer; drop files to move them here (Option copies)",
                               content: .glyph("folder.fill", color: Self.color(target.colorHex)),
                               indicator: model.drawer.isShowing(target.url) ? .visible : .none,
                               dimmed: !target.exists, acceptsDrop: true, label: .text(target.name))
        case .add:
            return HUDDockItem(id: tile.id, title: "Add a target: click to choose a folder, or drop folders here",
                               content: .glyph("plus", color: .white), acceptsDrop: true)
        }
    }

    private func click(_ tile: Tile) {
        switch tile {
        case .trash:
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash"))
        case .downloads:
            model.dock?.dockTileClicked(FileScanner.downloadsURL)
        case let .target(target, _):
            if target.exists { model.dock?.dockTileClicked(target.url) } else { model.flash("\(target.name) no longer exists", error: true) }
        case .add:
            model.chooseTarget()
        }
    }

    private func drop(_ urls: [URL], on tile: Tile, copy: Bool) {
        switch tile {
        case .trash: model.trash(urls)
        case .downloads: model.drop(urls, into: FileScanner.downloadsURL, copy: copy)
        case let .target(target, _): model.drop(urls, into: target.url, copy: copy)
        case .add: for url in urls where Self.isFolder(url) { model.addTarget(url) }
        }
    }

    /// Right click on a tile.
    private func menu(_ tile: Tile) -> NSMenu? {
        switch tile {
        case .downloads:
            return folderMenu(FileScanner.downloadsURL)
        case let .target(target, _):
            let menu = folderMenu(target.url)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Change Colour") { model.cycleColor(target) })
            menu.addItem(ClosureMenuItem("Remove Target") { model.removeTarget(target) })
            return menu
        case .trash, .add:
            return stripMenu()
        }
    }

    /// Right click on the strip's background.
    private func stripMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open Full Sift") { model.dock?.openInFullSift(nil) })
        let edges = NSMenu()
        for place in HUDDockPosition.menuOrder {
            if place == .topLeft { edges.addItem(.separator()) }
            let item = ClosureMenuItem(place.title) { model.dock?.moveDock(to: place) }
            item.state = model.dockPosition == place ? .on : .off
            edges.addItem(item)
        }
        let position = NSMenuItem(title: "Dock Position", action: nil, keyEquivalent: "")
        position.submenu = edges
        menu.addItem(position)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Add Target…") { model.chooseTarget() })
        menu.addItem(ClosureMenuItem("Hide Sift") { model.dock?.dismissPanel() })
        return menu
    }

    private func folderMenu(_ url: URL) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(model.drawer.isShowing(url) ? "Close Drawer" : "Show in Drawer") { model.dock?.dockTileClicked(url) })
        menu.addItem(ClosureMenuItem("Open in Full Sift") { model.dock?.openInFullSift(url) })
        menu.addItem(ClosureMenuItem("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        return menu
    }
}

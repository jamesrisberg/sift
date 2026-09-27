import AppKit
import FileKit
import SwiftUI

/// AppKit overlay for one cell: selection clicks, double-click to open, multi-item drag
/// out, drops onto folders, and the context menu. SwiftUI's `.onDrag` only carries one
/// item provider, which is why DownloadDetox could drag a single file at a time.
struct CellInteraction: NSViewRepresentable {
    let model: AppModel
    let pane: BrowserModel
    let item: FileItem

    func makeNSView(context: Context) -> CellInteractionView {
        let view = CellInteractionView()
        view.configure(model: model, pane: pane, item: item)
        return view
    }

    func updateNSView(_ view: CellInteractionView, context: Context) {
        view.configure(model: model, pane: pane, item: item)
    }
}

@MainActor
final class CellInteractionView: NSView, NSDraggingSource {
    private weak var model: AppModel?
    private weak var pane: BrowserModel?
    private var item: FileItem?
    private var mouseDownEvent: NSEvent?
    private var deferredSelectOnly = false

    func configure(model: AppModel, pane: BrowserModel, item: FileItem) {
        self.model = model
        self.pane = pane
        let changed = self.item?.url != item.url || self.item?.isBrowsable != item.isBrowsable
        self.item = item
        if changed {
            if item.isBrowsable { registerForDraggedTypes([.fileURL]) } else { unregisterDraggedTypes() }
            // The drawer's cards carry their details as a hover tooltip.
            toolTip = pane.isDrawer ? Self.tooltip(for: item) : nil
        }
    }

    private static func tooltip(for item: FileItem) -> String {
        var lines = [item.name, "\(item.category.kindName) · \(item.formattedSize)", "Modified \(item.formattedDate)"]
        if !item.isBrowsable, let host = WhereFroms.read(item.url).compactMap({ URL(string: $0)?.host() }).first {
            lines.append("From \(host)")
        }
        return lines.joined(separator: "\n")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Clicks

    override func mouseDown(with event: NSEvent) {
        guard let item, let pane else { return }
        // Take keyboard focus from the search or rename field so arrows and Space work.
        if window?.firstResponder is NSTextView { window?.makeFirstResponder(nil) }
        mouseDownEvent = event
        deferredSelectOnly = false
        let flags = event.modifierFlags
        if event.clickCount == 2 {
            pane.open(item)
            return
        }
        if !flags.contains(.command), !flags.contains(.shift), pane.selection.contains(item.url), pane.selection.count > 1 {
            // Keep the multi-selection so it can be dragged; collapse on mouse up instead.
            deferredSelectOnly = true
            pane.focus = item.url
            model?.activate(pane)
        } else {
            pane.click(item, command: flags.contains(.command), shift: flags.contains(.shift))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if deferredSelectOnly, let item, let pane {
            pane.click(item, command: false, shift: false)
        }
        deferredSelectOnly = false
        mouseDownEvent = nil
    }

    // MARK: - Drag out

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let item, let pane else { return }
        let dx = event.locationInWindow.x - down.locationInWindow.x
        let dy = event.locationInWindow.y - down.locationInWindow.y
        guard dx * dx + dy * dy > 16 else { return }
        mouseDownEvent = nil
        deferredSelectOnly = false

        if !pane.selection.contains(item.url) { pane.click(item, command: false, shift: false) }
        let urls = DragDrop.dragURLs(startingAt: item.url, selection: pane.selection, displayOrder: pane.visible.map(\.url))
        let origin = convert(down.locationInWindow, from: nil)
        let draggingItems: [NSDraggingItem] = urls.prefix(64).enumerated().map { index, url in
            let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            let image = IconCache.icon(for: url)
            let side: CGFloat = 48
            let offset = CGFloat(min(index, 6)) * 5
            dragItem.setDraggingFrame(
                NSRect(x: origin.x - side / 2 + offset, y: origin.y - side / 2 - offset, width: side, height: side),
                contents: image
            )
            return dragItem
        }
        // Items beyond the preview cap still travel on the pasteboard.
        let extra: [NSDraggingItem] = urls.dropFirst(64).map { url in
            let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            dragItem.setDraggingFrame(NSRect(x: origin.x, y: origin.y, width: 1, height: 1), contents: nil)
            return dragItem
        }
        let session = beginDraggingSession(with: draggingItems + extra, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Finder and other apps choose move vs copy (Option) themselves.
        [.copy, .move, .generic, .link]
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // Dragged somewhere that moved the files (e.g. Finder): the watcher refreshes, but
        // refresh now so the grid does not lag.
        MainActor.assumeIsolated {
            if operation != [] { pane?.reload() }
        }
    }

    // MARK: - Drop onto a folder cell

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func operation(for info: NSDraggingInfo) -> NSDragOperation {
        guard let item, item.isBrowsable else { return [] }
        let copy = NSEvent.modifierFlags.contains(.option)
        let plan = DragDrop.plan(dropping: droppedURLs(info), into: item.url, mode: copy ? .copy : .move)
        guard !plan.isEmpty else { return [] }
        return copy ? .copy : .move
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = operation(for: sender)
        pane?.dropHighlight = op == [] ? nil : item?.url
        return op
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let op = operation(for: sender)
        pane?.dropHighlight = op == [] ? nil : item?.url
        return op
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if pane?.dropHighlight == item?.url { pane?.dropHighlight = nil }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        pane?.dropHighlight = nil
        guard let item, let model else { return false }
        let urls = droppedURLs(sender)
        let copy = NSEvent.modifierFlags.contains(.option)
        // Run after the drag transaction finishes.
        DispatchQueue.main.async { model.drop(urls, into: item.url, copy: copy) }
        return true
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let item, let pane, let model else { return nil }
        if !pane.selection.contains(item.url) { pane.click(item, command: false, shift: false) }
        let urls = pane.selectedURLs
        let single = urls.count == 1
        if pane.isDrawer { return drawerMenu(item: item, urls: urls, pane: pane, model: model) }
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(ClosureMenuItem("Open") { pane.openSelection() })
        if single, item.isBrowsable {
            menu.addItem(ClosureMenuItem("Open in Other Pane") {
                if !model.twoPane { model.twoPane = true }
                model.otherPane?.navigate(to: item.url)
            })
        }
        if pane.isVirtual, single {
            menu.addItem(ClosureMenuItem("Show in Enclosing Folder") { pane.reveal(item.url) })
        }
        menu.addItem(ClosureMenuItem("Reveal in Finder") { pane.revealInFinder(urls) })
        menu.addItem(.separator())
        if single { menu.addItem(ClosureMenuItem("Rename") { pane.renaming = item.url }) }
        menu.addItem(ClosureMenuItem(single ? "Batch Rename…" : "Rename \(urls.count) Items…") { model.beginBatchRename(urls) })
        menu.addItem(ClosureMenuItem("Duplicate") { model.duplicate(urls) })
        menu.addItem(ClosureMenuItem("Copy") { model.copyToPasteboard(urls) })

        if !model.targets.isEmpty {
            let send = NSMenu()
            for (index, target) in model.targets.enumerated() {
                let entry = ClosureMenuItem(target.name) { model.move(urls, into: target.url) }
                if index < 9 { entry.keyEquivalent = "\(index + 1)"; entry.keyEquivalentModifierMask = [] }
                send.addItem(entry)
            }
            let sendItem = NSMenuItem(title: "Send To", action: nil, keyEquivalent: "")
            sendItem.submenu = send
            menu.addItem(sendItem)
        }
        if single, item.isBrowsable {
            menu.addItem(ClosureMenuItem("Add as Target") { model.addTarget(item.url) })
        }
        menu.addItem(tagsItem(urls: urls, model: model, pane: pane))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Move to Trash") { model.trash(urls) })
        return menu
    }
}

extension CellInteractionView {
    /// The drawer's shorter menu: Reveal, Open, Rename, Tags, Move To, Trash.
    fileprivate func drawerMenu(item: FileItem, urls: [URL], pane: BrowserModel, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("Reveal in Finder") { pane.revealInFinder(urls) })
        menu.addItem(ClosureMenuItem("Open") { pane.openSelection() })
        if urls.count == 1 { menu.addItem(ClosureMenuItem("Rename") { pane.renaming = item.url }) }
        menu.addItem(tagsItem(urls: urls, model: model, pane: pane))
        let destinations = [(FileScanner.downloadsURL, "Downloads")] + model.targets.filter(\.exists).map { ($0.url, $0.name) }
        let move = NSMenu()
        for (url, name) in destinations where url.normalizedFileURL != pane.current {
            move.addItem(ClosureMenuItem(name) { model.move(urls, into: url) })
        }
        if !move.items.isEmpty {
            let moveItem = NSMenuItem(title: "Move To", action: nil, keyEquivalent: "")
            moveItem.submenu = move
            menu.addItem(moveItem)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Move to Trash") { model.trash(urls) })
        return menu
    }

    /// "Tags" submenu: tick = every selected item has the tag, dash = some do.
    fileprivate func tagsItem(urls: [URL], model: AppModel, pane: BrowserModel) -> NSMenuItem {
        let items = pane.items.filter { urls.contains($0.url) }
        let sub = NSMenu()
        for tag in model.knownTags {
            let have = items.filter { $0.tagNames.contains(tag) }.count
            let entry = ClosureMenuItem(tag) { model.toggleTag(tag, on: urls) }
            entry.state = have == 0 ? .off : (have == items.count ? .on : .mixed)
            entry.image = Self.dot(for: tag)
            sub.addItem(entry)
        }
        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem("New Tag…") {
            let alert = NSAlert()
            alert.messageText = "New Tag"
            alert.informativeText = "Adds the tag to \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items")."
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn {
                let name = field.stringValue.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.toggleTag(name, on: urls.filter { url in !(items.first { $0.url == url }?.tagNames.contains(name) ?? false) }) }
            }
        })
        if items.contains(where: { !$0.tagNames.isEmpty }) {
            sub.addItem(ClosureMenuItem("Remove All Tags") { model.clearTags(urls) })
        }
        let item = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private static func dot(for tag: String) -> NSImage {
        let color = FileTags.standardColor(for: tag)
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if let hex = color.hex, let c = NSColor(hexString: hex) {
                c.setFill()
                circle.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                circle.lineWidth = 1
                circle.stroke()
            }
            return true
        }
    }
}

extension NSColor {
    convenience init?(hexString: String) {
        guard let v = UInt32(hexString, radix: 16), hexString.count == 6 else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

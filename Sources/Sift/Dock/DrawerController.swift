import AppKit
import Carbon
import FileKit
import HUDKit
import QuickLookUI
import SwiftUI

/// What the strip and drawer views ask of the panel controller.
@MainActor
protocol DockActions: AnyObject {
    /// A strip tile was clicked: open, swap or close the drawer.
    func dockTileClicked(_ url: URL)
    /// Leave dock mode for the browser, showing `url` if given.
    func openInFullSift(_ url: URL?)
    /// Leave the browser for dock mode.
    func enterDockMode()
    func moveDock(to position: HUDDockPosition)
    /// Hide the panel (dismiss, never quit).
    func dismissPanel()
    func closeDrawer()
}

/// What the drawer needs to know about the strip to place itself.
struct DockGeometry {
    var layout: DockLayout
    var visible: CGRect
    var others: [CGRect] = []
}

/// The dock drawer: a second HUD panel that slides out from the strip, perpendicular to its
/// edge (0.22 s out, 0.18 s in), showing one folder. Clicking outside closes it.
@MainActor
final class DrawerController {
    let model: AppModel
    /// The strip the drawer belongs to.
    private let strip: NSWindow
    /// The strip's layout, the visible frame of its screen and the other docks' frames
    /// (`HUDDockRegistry`), at the time of asking.
    private let geometry: () -> DockGeometry

    private(set) var window: SiftPanel?
    private var host: NSView?
    private let preview: PreviewSource
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// Bumped on every open/close so a finishing animation knows whether it is stale.
    private var generation = 0

    /// Called when the drawer opens, closes or moves (the dock registry lists its frame).
    var onFrameChange: (() -> Void)?

    init(model: AppModel, strip: NSWindow, geometry: @escaping () -> DockGeometry) {
        self.model = model
        self.strip = strip
        self.geometry = geometry
        preview = PreviewSource(pane: { [weak model] in model?.drawerPane })
        preview.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
    }

    var isOpen: Bool { model.drawer.isOpen }

    // MARK: - Transitions

    func toggle(_ url: URL) { run(model.drawer.toggle(url)) }
    func show(_ url: URL) { run(model.drawer.show(url)) }
    func close(animated: Bool = true) { run(model.drawer.close(), animated: animated) }

    private func run(_ transition: DrawerState.Transition, animated: Bool = true) {
        switch transition {
        case let .open(url):
            model.showInDrawer(url)
            open()
        case let .swap(url):
            model.showInDrawer(url)
            reposition()
            window?.makeKey()
        case .close:
            conceal(animated: animated)
        case .none:
            break
        }
    }

    /// The open frame for the strip as it is now.
    var openFrame: CGRect {
        let g = geometry()
        return g.layout.drawerFrame(strip: strip.frame, in: g.visible, avoiding: g.others)
    }

    private func open() {
        let window = self.window ?? makeWindow()
        generation += 1
        let target = openFrame
        let layout = geometry().layout
        window.alphaValue = 0
        window.setFrame(layout.drawerTuckedFrame(for: target), display: false)
        // Behind the strip, so it slides out from under it.
        window.order(.below, relativeTo: strip.windowNumber)
        window.makeKey()
        HUDAnimation.reveal(window, to: target)
        installMonitors()
        onFrameChange?()
        DispatchQueue.main.async { [window] in
            if window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
        }
    }

    private func conceal(animated: Bool) {
        removeMonitors()
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        guard let window, window.isVisible else { return model.releaseDrawerPane() }
        generation += 1
        let gen = generation
        let finish = { [weak self] in
            guard let self, gen == self.generation else { return }
            window.orderOut(nil)
            window.alphaValue = 1
            self.model.releaseDrawerPane()
            self.onFrameChange?()
        }
        if animated {
            HUDAnimation.conceal(window, to: geometry().layout.drawerTuckedFrame(for: window.frame), completion: finish)
        } else {
            finish()
        }
    }

    /// Keeps the drawer against the strip after the strip relays out.
    func reposition() {
        guard isOpen, let window, window.isVisible else { return }
        let frame = openFrame
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true)
        onFrameChange?()
    }

    private func makeWindow() -> SiftPanel {
        let window = SiftPanel(contentRect: CGRect(origin: .zero, size: DockLayout.horizontalDrawer),
                               styleMask: HUDPanelWindow.recipeStyleMask, backing: .buffered, defer: false)
        window.keyable = true
        window.applyHUDRecipe()
        window.becomesKeyOnlyIfNeeded = false
        window.title = "Sift Drawer"
        window.identifier = NSUserInterfaceItemIdentifier("xyz.machud.sift.drawer")
        window.previewSource = preview
        // Moving the drawer on its own would detach it from the strip.
        window.isMovableByWindowBackground = false
        window.isMovable = false

        let glass = HUDGlassView(style: Theme.stripGlass)
        let host = NSHostingView(rootView: DrawerView(model: model))
        host.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            host.topAnchor.constraint(equalTo: glass.topAnchor),
            host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        window.contentView = glass
        self.window = window
        self.host = host
        return window
    }

    /// The drawer's content view, for snapshots.
    var contentView: NSView? { host }

    // MARK: - Monitors

    private func installMonitors() {
        if clickMonitor == nil {
            // Clicks in other apps or on the desktop close the drawer. Clicks in Sift's own
            // windows (the strip, Quick Look, alerts) do not.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            }
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return self.handleKey(event) ? nil : event
            }
        }
    }

    private func removeMonitors() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        clickMonitor = nil
        keyMonitor = nil
    }

    // MARK: - Keys

    private var isEditingText: Bool {
        guard let responder = window?.firstResponder as? NSTextView else { return false }
        return responder.isFieldEditor || responder.isEditable
    }

    /// Space previews, Delete trashes, Cmd-Z undoes, arrows move, Return opens, 1-9 send to
    /// a target, Esc clears the search, then the selection, then closes the drawer.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let pane = model.drawerPane else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command), shift = flags.contains(.shift)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = Int(event.keyCode)

        if cmd, key == "f" { model.focusDrawerSearchRequest += 1; return true }
        if isEditingText { return false }
        if cmd {
            switch (key, shift) {
            case ("z", false): model.undo(); return true
            case ("z", true): model.redo(); return true
            case ("a", false): pane.selectAll(); return true
            case ("c", false): model.copyToPasteboard(pane.selectedURLs); return true
            default: break
            }
            switch code {
            case kVK_Delete, kVK_ForwardDelete: model.trash(pane.selectedURLs); return true
            case kVK_UpArrow: pane.goUp(); return true
            default: return false
            }
        }
        switch code {
        case kVK_Space: togglePreview(); return true
        case kVK_UpArrow: pane.moveFocus(.up, extend: shift); return true
        case kVK_DownArrow: pane.moveFocus(.down, extend: shift); return true
        case kVK_LeftArrow: pane.moveFocus(.left, extend: shift); return true
        case kVK_RightArrow: pane.moveFocus(.right, extend: shift); return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if shift, let url = pane.selectedURLs.first { pane.renaming = url } else { pane.openSelection() }
            return true
        case kVK_Delete, kVK_ForwardDelete: model.trash(pane.selectedURLs); return true
        case kVK_Escape:
            if pane.filter.isActive { pane.filter.reset() }
            else if !pane.selection.isEmpty { pane.clearSelection() }
            else { close() }
            return true
        default: break
        }
        if flags.subtracting([.numericPad, .function, .capsLock]).isEmpty, let digit = Int(key), (1...9).contains(digit) {
            let urls = pane.selectedURLs
            guard model.targets.indices.contains(digit - 1), !urls.isEmpty else { return true }
            model.move(urls, into: model.targets[digit - 1].url)
            return true
        }
        return false
    }

    // MARK: - Quick Look

    func togglePreview() {
        let ql = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists(), ql.isVisible {
            ql.orderOut(nil)
        } else if let pane = model.drawerPane, !pane.selection.isEmpty {
            ql.makeKeyAndOrderFront(nil)
            ql.reloadData()
        }
    }

    func reloadPreview() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible,
              let pane = model.drawerPane, window?.isKeyWindow == true || QLPreviewPanel.shared().dataSource === preview
        else { return }
        let ql = QLPreviewPanel.shared()!
        ql.reloadData()
        let urls = pane.selectedURLs
        if let focus = pane.focus, let i = urls.firstIndex(of: focus) { ql.currentPreviewItemIndex = i }
    }
}

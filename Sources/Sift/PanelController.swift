import AppKit
import Carbon
import Combine
import FileKit
import HUDKit
import QuickLookUI
import SwiftUI

/// HUDKit's panel window plus Quick Look control. The browser is `.windowed` (a normal
/// window: activates Sift, other windows can cover it); the dock strip and its drawer are
/// `.hover` (floating, every Space, non-activating; the drawer keyable so its fields work
/// without activating the app).
final class SiftPanel: HUDPanelWindow {
    weak var previewSource: PreviewSource?

    // Quick Look finds its controller by walking the responder chain from the key window.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = previewSource
        panel.delegate = previewSource
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }
}

/// Supplies a pane's selection to Quick Look and forwards arrow keys back. The browser's
/// panel previews the active pane; the drawer previews its own listing.
@MainActor
final class PreviewSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let pane: () -> BrowserModel?
    /// Handles arrow keys pressed while the preview is key.
    var keyHandler: ((NSEvent) -> Bool)?
    init(pane: @escaping () -> BrowserModel?) { self.pane = pane }

    private var urls: [URL] { pane()?.selectedURLs ?? [] }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            let list = urls
            let focusIndex = pane()?.focus.flatMap { list.firstIndex(of: $0) } ?? 0
            // Single selection: preview the focused item; multi: Quick Look pages through.
            return (list.indices.contains(index) ? list[index] : list[focusIndex]) as NSURL
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        MainActor.assumeIsolated {
            // Arrow keys in the preview move the grid selection, like Finder.
            guard event.type == .keyDown, let handler = keyHandler else { return false }
            switch Int(event.keyCode) {
            case kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow:
                return handler(event)
            default:
                return false
            }
        }
    }
}

/// Owns the panel window: visibility, the full / compact (dock) / parked modes, frames
/// (including frames MacHUD assigns over the socket), the dock drawer, Quick Look and snapshots.
///
/// The one panel is either the browser (full) or the dock strip (compact). Hiding it is a
/// dismissal: the app keeps running and `show` (menu bar, hotkey, `panel show`) summons it
/// back at its last frame in its last mode.
@MainActor
final class PanelController: NSObject, NSWindowDelegate, DockActions {
    static let fullSize = CGSize(width: 900, height: 560)
    /// The strip along the bottom with three targets (Trash | Downloads, 3 targets | +).
    static let compactSize = DockLayout.standard(position: .bottom, targetCount: 3).contentSize

    let model: AppModel
    let panel: SiftPanel
    private let glass: HUDGlassView
    private let host: NSView
    private let preview: PreviewSource
    private let router: KeyRouter
    private var keyMonitor: Any?
    private let memory: PanelMemory
    private(set) var drawer: DrawerController!

    /// The mode shown (or returned to when unparking).
    private(set) var mode: HUDPanelMode = .full
    /// What the panel was before it parked.
    private var modeBeforeParking: HUDPanelMode = .full
    private var restFrame: CGRect?
    /// The edge and peek to park at (MacHUD's, once it has named them).
    private(set) var parking = ParkingSpot(peek: 14)
    /// Whether the panel is meant to be on screen (true during the fade-out's first frames
    /// is wrong for `state`, so this is tracked separately from `isVisible`).
    private(set) var isShown = false
    /// Frame changes made by us (mode switches, parking, snapping) are not user moves.
    private var isAdjustingFrame = false

    /// Called whenever visibility, mode or frame changes (for `state` events).
    var onStateChange: (() -> Void)?

    /// Where the strip (and its open drawer) is published for sibling docks, and where the
    /// MacHUD dock's frames are read from.
    let docks: HUDDockRegistry
    /// This app's key in the registry.
    let dockID: String
    /// The other docks' frames (the MacHUD dock), kept current by `docksWatch`.
    private(set) var otherDocks: [CGRect] = []
    private var docksWatch: AnyCancellable?
    private var screenObserver: Any?

    init(model: AppModel, memory: PanelMemory = PanelMemory(),
         docks: HUDDockRegistry = HUDDockRegistry(url: AppEnvironment.docksURL),
         dockID: String = Bundle.main.bundleIdentifier ?? "xyz.machud.sift") {
        self.model = model
        self.memory = memory
        self.docks = docks
        self.dockID = dockID
        panel = SiftPanel(contentRect: CGRect(origin: .zero, size: Self.fullSize),
                          styleMask: HUDPanelWindow.recipeStyleMask.union(.resizable), backing: .buffered, defer: false)
        glass = HUDGlassView(style: Theme.fullGlass)
        host = NSHostingView(rootView: RootView(model: model))
        preview = PreviewSource(pane: { [weak model] in model?.activePane })
        router = KeyRouter(model: model)
        super.init()

        panel.keyable = true
        panel.applyHUDRecipe(behavior: .windowed)
        panel.title = "Sift"
        panel.identifier = NSUserInterfaceItemIdentifier("xyz.machud.sift.browser")
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 560, height: 360)
        panel.delegate = self
        panel.previewSource = preview

        embedHost(inGlass: true)

        if let saved = memory.fullFrame {
            panel.setFrame(saved, display: false)
        } else if panel.setFrameUsingName("SiftPanel") {
            // 0.1 used NSWindow frame autosave; carry that frame over once.
            AppEnvironment.defaults.removeObject(forKey: "NSWindow Frame SiftPanel")
        } else {
            panel.setFrame(mouseScreenCenteredFrame(), display: false)
        }

        model.dockPosition = memory.dockPosition
        model.dock = self
        drawer = DrawerController(model: model, strip: panel) { [weak self] in
            guard let self else { return DockGeometry(layout: .standard(position: .bottom, targetCount: 0), visible: .zero) }
            return DockGeometry(layout: self.stripLayout, visible: self.visibleFrame(for: self.panel.frame), others: self.otherDocks)
        }
        drawer.onFrameChange = { [weak self] in self?.publishDock() }
        model.onTargetsChange = { [weak self] in self?.relayoutStrip() }
        watchDocks()

        router.panel = panel
        router.preview = self
        preview.keyHandler = { [router] event in router.handle(event) }
        model.onSelectionChange = { [weak self] in
            self?.reloadPreview()
            self?.drawer.reloadPreview()
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel, self.router.handle(event) { return nil }
            return event
        }

        // Open in the launch mode: the dock strip unless `launchMode` says otherwise.
        if memory.initialMode == .compact { apply(.compact) }
    }

    var isVisible: Bool { isShown }

    /// The browser on the panel's glass, or (dock mode) the SwiftUI content straight in the
    /// window, where `HUDDockStripView` draws the strip's own glass.
    private func embedHost(inGlass: Bool) {
        if inGlass {
            guard host.superview !== glass else { return }
            host.removeFromSuperview()
            host.translatesAutoresizingMaskIntoConstraints = false
            glass.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                host.topAnchor.constraint(equalTo: glass.topAnchor),
                host.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ])
            panel.contentView = glass
        } else {
            guard panel.contentView !== host else { return }
            host.removeFromSuperview()
            host.translatesAutoresizingMaskIntoConstraints = true
            host.autoresizingMask = [.width, .height]
            panel.contentView = host
        }
    }

    /// The strip view while in dock mode.
    var stripView: HUDDockStripView? {
        guard mode == .compact else { return nil }
        func find(_ view: NSView) -> HUDDockStripView? {
            if let strip = view as? HUDDockStripView { return strip }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return find(host)
    }

    /// Setting `launchMode` (read at the next launch).
    var launchMode: LaunchMode {
        get { memory.launchMode }
        set { memory.launchMode = newValue }
    }

    // MARK: - Visibility

    /// Shows the panel in its current mode. `transition` carries MacHUD's `panel show`
    /// options: `from=` slides it out of that dock edge, `reason=hover` fades it in quickly
    /// without taking keyboard focus (see `PanelMotion`).
    func show(_ transition: HUDPanelTransition = HUDPanelTransition()) {
        if mode == .parked { return unpark() }
        if mode == .full { fitToPaneCount() }
        let target = showFrame()
        let wasShown = isShown
        isShown = true
        let gen = beginMotion(toward: target)
        let finish: @MainActor () -> Void = { [weak self] in self?.endMotion(gen) }
        let motion = PanelMotion.show(transition)
        if let edge = motion.edge {
            HUDAnimation.slide(in: panel, from: edge, to: target, completion: finish)
        } else {
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.setFrame(target, display: false)
                panel.orderFrontRegardless()
            }
            // Mid-hide the panel may be part-way toward the dock: bring it back as it fades in.
            HUDAnimation.animate(panel, to: panel.frame == target ? nil : target, alpha: 1, duration: motion.duration,
                                 timing: HUDAnimation.revealTiming, completion: finish)
        }
        // Click/summon shows bring the browser (a normal window) forward and activate Sift;
        // hover shows only order it in.
        if panel.activateOnShow(transition) {
            // SwiftUI focuses the first text field (search) by default, which would swallow
            // arrow keys and Space. Start with keyboard focus on the listing instead.
            DispatchQueue.main.async { [panel] in
                if panel.firstResponder is NSTextView { panel.makeFirstResponder(nil) }
            }
        }
        publishDock()
        if !wasShown { onStateChange?() }
    }

    /// Dismisses the panel (and its drawer). Sift keeps running in the menu bar.
    /// `transition` carries MacHUD's `panel hide` options: `to=` slides it back toward that
    /// dock edge, `reason=hover` fades it out almost at once.
    func hide(_ transition: HUDPanelTransition = HUDPanelTransition()) {
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        }
        drawer.close()
        guard isShown else { return }
        isShown = false
        var rest = restingFrame
        if mode == .full { memory.fullFrame = rest }
        if mode == .parked, let restFrame {
            // Hiding a parked panel returns it to its rest frame for the next show.
            mode = modeBeforeParking
            rest = restFrame
            self.restFrame = nil
        }
        publishDock()
        let gen = beginMotion(toward: rest)
        let motion = PanelMotion.hide(transition)
        // Like HUDAnimation.slideOut, with the hover speed when the pointer just left the dock.
        let away = motion.edge.map { HUDAnimation.offset(rest, toward: $0) } ?? (panel.frame == rest ? nil : rest)
        HUDAnimation.animate(panel, to: away, alpha: 0, duration: motion.duration, timing: HUDAnimation.concealTiming) { [weak self] in
            // A show() during the hide wins: it started a newer motion.
            guard let self, self.motionGeneration == gen else { return }
            self.panel.orderOut(nil)
            self.setFrameQuietly(rest)
            self.panel.alphaValue = 1
            self.endMotion(gen)
        }
        onStateChange?()
    }

    // MARK: - Show/hide motion

    /// Bumped by every show and hide so a finishing animation knows whether it is stale.
    private(set) var motionGeneration = 0
    /// A show or hide animation is moving the window (not the user, not a drag).
    private var inMotion = false
    /// Where the running show/hide leaves the panel when it is on screen.
    private var motionTarget: CGRect?

    private func beginMotion(toward target: CGRect) -> Int {
        motionGeneration += 1
        inMotion = true
        motionTarget = target
        return motionGeneration
    }

    private func endMotion(_ gen: Int) {
        guard gen == motionGeneration else { return }
        inMotion = false
        motionTarget = nil
    }

    /// The panel's frame at rest: mid show/hide, the frame it belongs at, not where the
    /// animation has got to.
    private var restingFrame: CGRect { inMotion ? (motionTarget ?? panel.frame) : panel.frame }

    /// Where `show` puts the panel: the strip's place, or the browser's last frame (which is
    /// MacHUD's `panel frame` when it set one) while that is still on a screen.
    private func showFrame() -> CGRect {
        if mode == .compact { return stripFrame() }
        return PanelMemory.summonFrame(remembered: nil, dismissedAt: restingFrame,
                                       screens: NSScreen.screens.map(\.visibleFrame)) ?? mouseScreenCenteredFrame()
    }

    func toggle() {
        if mode == .parked { return unpark() }
        // The strip never takes key status, so for it "shown" is enough to hide.
        isShown && (panel.isKeyWindow || mode == .compact) ? hide() : show()
    }

    // MARK: - Modes

    /// `options` carry the edge/peek MacHUD parks at; they only matter for `.parked`.
    func setMode(_ newMode: HUDPanelMode, options: HUDPanelModeOptions = HUDPanelModeOptions()) {
        switch newMode {
        case .parked:
            park(options)
        case .full, .compact:
            if mode == .parked { unpark(to: newMode) } else { apply(newMode) }
            if !isShown { show() }
        }
        onStateChange?()
    }

    private func apply(_ newMode: HUDPanelMode) {
        guard newMode != mode, newMode != .parked else { return }
        if mode == .full { memory.fullFrame = panel.frame }
        if mode == .compact { drawer.close(animated: false) }
        mode = newMode
        memory.mode = newMode
        model.isCompact = newMode == .compact
        // The strip brings its own glass (the tool dock's); the browser sits on the panel's.
        embedHost(inGlass: newMode != .compact)
        if newMode == .compact {
            panel.styleMask.remove(.resizable)
            panel.minSize = NSSize(width: 16, height: 16)
            // Click-only: tapping a tile must not take focus from the app in front. The
            // strip is a dock, so it floats on every Space like MacHUD's.
            if panel.isKeyWindow { panel.resignKey() }
            panel.keyable = false
            panel.applyHUDRecipe(behavior: .hover)
            setFrameQuietly(stripFrame(), animate: isShown)
        } else {
            panel.keyable = true
            panel.applyHUDRecipe(behavior: .windowed)
            panel.styleMask.insert(.resizable)
            panel.minSize = NSSize(width: 560, height: 360)
            setFrameQuietly(memory.fullFrame ?? defaultFullFrame(), animate: isShown)
                if isShown { panel.activateOnShow() }
        }
        panel.invalidateShadow()
        publishDock()
    }

    private func park(_ options: HUDPanelModeOptions) {
        let moved = parking.update(with: options)
        if mode == .parked {
            // Already parked: move to the newly requested edge or peek.
            if moved, let restFrame { setFrameQuietly(parking.offScreenFrame(for: restFrame)) }
            return
        }
        drawer.close(animated: false)
        if !isShown { show() }
        modeBeforeParking = mode
        restFrame = panel.frame
        mode = .parked
        let edge = parking.edge(for: panel.frame, in: HUDParking.screenFrame(for: panel.frame))
        isAdjustingFrame = true
        HUDParking.slideOut(panel, edge: edge, peek: parking.peek) { [weak self] in self?.isAdjustingFrame = false }
    }

    private func unpark(to target: HUDPanelMode? = nil) {
        guard mode == .parked else { return }
        let rest = restFrame ?? panel.frame
        mode = modeBeforeParking
        restFrame = nil
        isShown = true
        isAdjustingFrame = true
        HUDParking.slideIn(panel, to: rest) { [weak self] in
            guard let self else { return }
            self.isAdjustingFrame = false
            if let target, target != self.mode { self.apply(target) }
            self.panel.activateOnShow()
            self.onStateChange?()
        }
    }

    /// Cooperative placement from MacHUD (`panel frame`). In full mode the frame is kept as
    /// the browser's frame; the strip snaps to the edge nearest it.
    func setFrame(_ frame: CGRect) {
        switch mode {
        case .parked:
            restFrame = frame
            setFrameQuietly(parking.offScreenFrame(for: frame))
            return
        case .compact:
            placeDock(DockLayout.snap(frame, in: visibleFrame(for: frame)), animate: false)
        case .full:
            setFrameQuietly(frame)
            memory.fullFrame = frame
        }
        onStateChange?()
    }

    private func setFrameQuietly(_ frame: CGRect, animate: Bool = false) {
        isAdjustingFrame = true
        panel.setFrame(frame, display: true, animate: animate)
        isAdjustingFrame = false
    }

    // MARK: - Dock strip

    var stripLayout: DockLayout { DockLayout.standard(position: model.dockPosition, targetCount: model.targets.count) }

    /// The strip's frame at its position, slid clear of the other docks on its edge.
    func stripFrame() -> CGRect {
        stripLayout.stripFrame(in: visibleFrame(for: panel.frame), avoiding: otherDocks)
    }

    /// The visible frame of the screen holding most of `frame` (else the main screen).
    private func visibleFrame(for frame: CGRect) -> CGRect {
        let best = NSScreen.screens.max { a, b in
            area(a.frame.intersection(frame)) < area(b.frame.intersection(frame))
        }
        if let best, area(best.frame.intersection(frame)) > 0 { return best.visibleFrame }
        return (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    /// Puts the strip at `position`, remembering it.
    private func placeDock(_ position: HUDDockPosition, animate: Bool) {
        memory.dockPosition = position
        model.dockPosition = position
        guard mode == .compact else { return }
        moveStrip(to: stripFrame(), animate: animate)
    }

    private func moveStrip(to target: CGRect, animate: Bool) {
        if animate, target != panel.frame {
            isAdjustingFrame = true
            HUDAnimation.animate(panel, to: target, duration: HUDAnimation.revealDuration, timing: HUDAnimation.revealTiming) { [weak self] in
                self?.isAdjustingFrame = false
                self?.panel.invalidateShadow()
                self?.drawer.reposition()
                self?.publishDock()
            }
        } else {
            setFrameQuietly(target)
            panel.invalidateShadow()
            drawer.reposition()
        }
        publishDock()
    }

    /// Targets changed: the strip grows or shrinks and the badges follow.
    private func relayoutStrip(animate: Bool = false) {
        guard mode == .compact else { return }
        moveStrip(to: stripFrame(), animate: animate && isShown)
    }

    // MARK: - Sibling docks (HUDDockRegistry)

    /// Reads the other docks now and whenever `docks.json` or the screens change.
    private func watchDocks() {
        otherDocks = Self.frames(of: docks.others(than: dockID))
        docksWatch = docks.watch { [weak self] _ in
            MainActor.assumeIsolated { self?.docksDidChange() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.relayoutStrip() }
        }
    }

    /// Another dock moved (or appeared, or went away): step out of its way.
    func docksDidChange() {
        let frames = Self.frames(of: docks.others(than: dockID))
        guard frames != otherDocks else { return }
        otherDocks = frames
        relayoutStrip(animate: true)
    }

    nonisolated static func frames(of entries: [String: HUDDockRegistry.Entry]) -> [CGRect] {
        entries.keys.sorted().flatMap { entries[$0]!.frames }
    }

    /// Publishes the strip (and the open drawer) while the strip is on screen, and withdraws
    /// it otherwise, so the MacHUD dock can keep out of its way. Writes only on change.
    func publishDock() {
        do {
            if mode == .compact, isShown {
                var frames = [stripFrame()]
                if drawer.isOpen, let window = drawer.window, window.isVisible { frames.append(drawer.openFrame) }
                try docks.publish(appID: dockID, position: model.dockPosition, frames: frames)
            } else if docks.entry(for: dockID) != nil {
                try docks.remove(appID: dockID)
            }
        } catch {
            NSLog("Sift: could not update %@: %@", docks.url.path, error.localizedDescription)
        }
    }

    /// Takes the strip out of the registry (at quit).
    func withdrawDock() {
        try? docks.remove(appID: dockID)
    }


    // MARK: DockActions

    func dockTileClicked(_ url: URL) { drawer.toggle(url) }

    func openInFullSift(_ url: URL?) {
        drawer.close(animated: false)
        setMode(.full)
        if let url { model.navigateActivePane(to: url) }
        show()
    }

    func enterDockMode() { setMode(.compact) }

    func moveDock(to position: HUDDockPosition) {
        drawer.close(animated: false)
        placeDock(position, animate: isShown)
        onStateChange?()
    }

    func dismissPanel() { hide() }

    func closeDrawer() { drawer.close() }

    // MARK: - Frames

    private func defaultFullFrame() -> CGRect {
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? CGRect(origin: .zero, size: Self.fullSize)
        return CGRect(x: visible.midX - Self.fullSize.width / 2, y: visible.midY - Self.fullSize.height / 2,
                      width: Self.fullSize.width, height: Self.fullSize.height)
    }

    func windowWillMove(_ notification: Notification) {
        // Dragging the strip takes the drawer in; it would be left behind otherwise.
        if mode == .compact, !isAdjustingFrame, !inMotion { drawer.close() }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isAdjustingFrame, !inMotion, !panel.inLiveResize else { return }
        switch mode {
        case .full: memory.fullFrame = panel.frame
        case .compact: break  // the strip reports where a drag ends (HUDDockStripDelegate)
        case .parked: break
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if mode == .full { memory.fullFrame = panel.frame }
    }

    /// Two panes need more room; widen (within the screen) when two-pane mode is on.
    func fitToPaneCount() {
        guard mode == .full, model.twoPane, panel.frame.width < 1240,
              let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = panel.frame
        let width = min(1320, visible.width - 40)
        frame.origin.x = max(visible.minX + 20, frame.midX - width / 2)
        frame.size.width = width
        panel.setFrame(frame, display: true, animate: panel.isVisible)
        memory.fullFrame = frame
    }

    /// The panel's current size, centred on the screen with the mouse.
    private func mouseScreenCenteredFrame() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let size = panel.frame.size
        guard let visible = screen?.visibleFrame else { return panel.frame }
        return CGRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: - Quick Look

    func togglePreview() {
        let ql = QLPreviewPanel.shared()!
        if QLPreviewPanel.sharedPreviewPanelExists(), ql.isVisible {
            ql.orderOut(nil)
        } else if !model.activePane.selection.isEmpty {
            ql.makeKeyAndOrderFront(nil)
            ql.reloadData()
        }
    }

    func reloadPreview() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible,
              QLPreviewPanel.shared().dataSource === preview else { return }
        let ql = QLPreviewPanel.shared()!
        ql.reloadData()
        let urls = model.activePane.selectedURLs
        if let focus = model.activePane.focus, let i = urls.firstIndex(of: focus) { ql.currentPreviewItemIndex = i }
    }

    // MARK: - Snapshot

    /// Writes a PNG of the panel, and of the drawer beside the strip when it is out. The
    /// glass backdrop blurs what is behind the window, which a view cache cannot capture (it
    /// comes out opaque white), so each window is composited on a dark stand-in with its
    /// corners and hairline border, at its place on screen (the strip by
    /// `HUDDockStripView.snapshot`, the same drawing as MacHUD's tool dock snapshot).
    func writeSnapshot(to url: URL) {
        let scale = panel.backingScaleFactor
        var layers: [(rep: NSBitmapImageRep?, frame: CGRect)] = []
        if let strip = stripView {
            // The strip draws itself, as MacHUD's `tooldock snapshot` does.
            layers.append((strip.snapshot(scale: scale), panel.frame))
        } else {
            layers.append((Self.render(host, radius: Theme.fullGlass.cornerRadius, scale: scale), panel.frame))
        }
        if mode == .compact, drawer.isOpen, let window = drawer.window, let view = drawer.contentView {
            layers.append((Self.render(view, radius: Theme.stripGlass.cornerRadius, scale: scale), window.frame))
        }
        let bounds = layers.reduce(CGRect.null) { $0.union($1.frame) }
        guard let canvas = Self.bitmap(size: bounds.size, scale: scale),
              let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
        for layer in layers {
            guard let rep = layer.rep else { continue }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            rep.draw(in: layer.frame.offsetBy(dx: -bounds.minX, dy: -bounds.minY))
            NSGraphicsContext.restoreGraphicsState()
        }
        do {
            try canvas.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            NSLog("Sift: snapshot failed: %@", error.localizedDescription)
        }
    }

    /// An explicit RGBA bitmap: the one bitmapImageRepForCachingDisplay returns is opaque,
    /// which turns every transparent pixel white.
    private static func bitmap(size: CGSize, scale: CGFloat) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                   pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = size  // before making a context, so it draws in points
        return rep
    }

    private static func render(_ view: NSView, radius: CGFloat, scale: CGFloat) -> NSBitmapImageRep? {
        let size = view.bounds.size
        guard let rep = bitmap(size: size, scale: scale), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor(calibratedWhite: 0.13, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
        view.cacheDisplay(in: view.bounds, to: rep)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.white.withAlphaComponent(Theme.hairlineAlpha).setStroke()
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
        border.lineWidth = 0.5
        border.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

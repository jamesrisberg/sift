import AppKit
import FileKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.isCompact {
                DockStripView(model: model)
            } else {
                browser
            }
        }
        .ignoresSafeArea()
    }

    private var browser: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: 190)
            Hairline(axis: .vertical)
            HStack(spacing: 0) {
                ForEach(Array(model.panes.enumerated()), id: \.element.id) { index, pane in
                    if index > 0 { Hairline(axis: .vertical) }
                    PaneView(model: model, pane: pane, isActive: index == model.activePaneIndex || model.panes.count == 1)
                }
            }
        }
        .overlay(alignment: .bottom) { StatusToast(model: model) }
        .overlay { SheetHost(model: model) }
        .frame(minWidth: 560, minHeight: 360)
    }
}

/// Presents `model.sheet` over the browser. Drawn in the panel itself (not an AppKit sheet)
/// so it works on the borderless, non-activating panel and shows up in snapshots.
struct SheetHost: View {
    @Bindable var model: AppModel

    var body: some View {
        if let sheet = model.sheet {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.35)
                        .contentShape(Rectangle())
                        .onTapGesture {}
                    Group {
                        switch sheet {
                        case .rules: RulesSheet(model: model, rules: model.rules)
                        case let .rename(urls): RenameSheet(model: model, urls: urls)
                        }
                    }
                    .frame(width: min(820, geo.size.width - 32), height: min(520, geo.size.height - 32))
                    .background(Color(white: 0.13).opacity(0.97), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .hairlineBorder(cornerRadius: 12)
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
                }
            }
            .transition(.opacity)
        }
    }
}

struct StatusToast: View {
    let model: AppModel

    var body: some View {
        if let status = model.status {
            Label(status.text, systemImage: status.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                .foregroundStyle(status.isError ? Color.red : Color.primary)
                .padding(.bottom, 34)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeOut(duration: 0.2), value: status)
                .allowsHitTesting(false)
        }
    }
}

/// Drags the (borderless) window from wherever this sits behind other content, and shows
/// `menu` on a right click.
struct WindowDragHandle: NSViewRepresentable {
    var menu: (() -> NSMenu)? = nil

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) { nsView.menuProvider = menu }

    final class DragView: NSView {
        var menuProvider: (() -> NSMenu)?
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { return }
            window?.performDrag(with: event)
        }
        override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    }
}

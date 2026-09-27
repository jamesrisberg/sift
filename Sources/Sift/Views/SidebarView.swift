import FileKit
import SwiftUI
import UniformTypeIdentifiers

/// Targets: favourite folders that accept drops and respond to number keys 1-9.
struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var addHighlighted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The top strip doubles as the window's drag handle (the panel is borderless).
            Color.clear.frame(height: 12).frame(maxWidth: .infinity).background(WindowDragHandle())
            sectionTitle("VIEWS")
            VStack(spacing: 2) {
                SmartViewRow(model: model, title: "Recents", symbol: "clock", kind: .recents)
                SmartViewRow(model: model, title: "Downloads", symbol: "arrow.down.circle", folder: FileScanner.downloadsURL)
                SmartViewRow(model: model, title: "Large Files", symbol: "externaldrive", kind: .largeFiles)
            }
            .padding(.horizontal, 8)
            sectionTitle("TARGETS").padding(.top, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(model.targets.enumerated()), id: \.element.id) { index, target in
                        TargetRow(model: model, target: target, index: index)
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            addRow
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WindowDragHandle())
    }

    /// Click to add the current folder, or drop folders here to add them.
    private var addRow: some View {
        Button {
            model.addTarget(model.activePane.current)
        } label: {
            Label("Add Current Folder", systemImage: "plus.circle")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(addHighlighted ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add the current folder as a target, or drop folders here")
        .padding(8)
        .onDrop(of: [.fileURL], isTargeted: $addHighlighted) { providers in
            loadFileURLs(providers) { urls in
                for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    model.addTarget(url)
                }
            }
            return true
        }
    }
}

/// A smart view (Spotlight-backed results) or a well-known folder.
struct SmartViewRow: View {
    let model: AppModel
    let title: String
    let symbol: String
    var kind: VirtualView.Kind? = nil
    var folder: URL? = nil

    private var isCurrent: Bool {
        let pane = model.activePane
        if let kind { return pane.virtualView?.kind == kind }
        return !pane.isVirtual && pane.current == folder?.normalizedFileURL
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(isCurrent ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture {
            if let kind { model.activePane.showSmartView(kind) } else if let folder { model.activePane.navigate(to: folder) }
        }
    }
}

struct TargetRow: View {
    let model: AppModel
    let target: Target
    let index: Int
    @State private var isTargeted = false

    private var color: Color { Color(hex: target.colorHex) ?? .accentColor }
    private var isCurrent: Bool { !model.activePane.isVirtual && model.activePane.current == target.url.normalizedFileURL }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(color.gradient)
                .frame(width: 18, height: 18)
                .overlay(Image(systemName: "folder.fill").font(.system(size: 9)).foregroundStyle(.white))
            Text(target.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(target.exists ? .primary : .secondary)
            Spacer(minLength: 4)
            if index < 9 {
                Text("\(index + 1)")
                    .font(Theme.secondaryFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .hairlineBorder(cornerRadius: 4)
            }
        }
        .font(.callout)
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(background, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture { model.activePane.navigate(to: target.url) }
        .help(target.url.path(percentEncoded: false))
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            let copy = NSEvent.modifierFlags.contains(.option)
            loadFileURLs(providers) { urls in model.drop(urls, into: target.url, copy: copy) }
            return true
        }
        .contextMenu {
            Button("Send Selection Here") { model.send(toTarget: index) }
            Button("Open in Other Pane") {
                if !model.twoPane { model.twoPane = true }
                model.otherPane?.navigate(to: target.url)
            }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([target.url]) }
            Divider()
            Button("Change Color") { model.cycleColor(target) }
            if index > 0 { Button("Move Up") { model.moveTargets(from: [index], to: index - 1) } }
            if index < model.targets.count - 1 { Button("Move Down") { model.moveTargets(from: [index], to: index + 2) } }
            Divider()
            Button("Remove Target") { model.removeTarget(target) }
        }
    }

    private var background: Color {
        if isTargeted { return color.opacity(0.35) }
        if isCurrent { return Color.primary.opacity(0.08) }
        return .clear
    }
}

/// Resolves dropped item providers to file URLs and calls back on the main actor.
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    let lock = NSLock()
    var urls: [(Int, URL)] = []
    for (i, provider) in providers.enumerated() where provider.canLoadObject(ofClass: URL.self) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url, url.isFileURL { lock.lock(); urls.append((i, url)); lock.unlock() }
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let ordered = urls.sorted { $0.0 < $1.0 }.map(\.1)
        MainActor.assumeIsolated { completion(ordered) }
    }
}

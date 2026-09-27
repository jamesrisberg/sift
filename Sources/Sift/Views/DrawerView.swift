import AppKit
import FileKit
import SwiftUI

/// The dock drawer's content: one folder with search, sort, category pills, a grid of
/// file cards and a footer (Open in Full Sift, Trash All).
struct DrawerView: View {
    @Bindable var model: AppModel

    var body: some View {
        if let pane = model.drawerPane {
            DrawerContent(model: model, pane: pane)
        } else {
            Color.clear
        }
    }
}

private struct DrawerContent: View {
    let model: AppModel
    @Bindable var pane: BrowserModel
    @FocusState private var searchFocused: Bool

    /// The tile's folder (the listing may have gone deeper).
    private var root: URL { model.drawer.folder ?? pane.current }
    private var color: Color { Color(hex: model.dockColorHex(for: root)) ?? .accentColor }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            controls
            Hairline()
            DrawerGrid(model: model, pane: pane, color: color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            DrawerFooter(model: model, pane: pane)
        }
        .onChange(of: model.focusDrawerSearchRequest) { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if pane.current != root.normalizedFileURL {
                Button { pane.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .frame(width: 20, height: 20)
                    .help("Back")
            }
            Circle().fill(color).frame(width: 8, height: 8)
            Text(pane.current == root.normalizedFileURL ? model.dockTitle(for: root) : pane.current.lastPathComponent)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Text(summary)
                .font(Theme.secondaryFont)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if pane.isLoading { ProgressView().controlSize(.mini) }
            Button { model.dock?.closeDrawer() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
    }

    private var summary: String {
        let items = pane.visible
        let bytes = items.filter { !$0.isBrowsable }.reduce(Int64(0)) { $0 + $1.fileSize }
        let count = "\(items.count) item\(items.count == 1 ? "" : "s")"
        return bytes > 0 ? "\(count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : count
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("Search", text: $pane.filter.searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($searchFocused)
                        .onExitCommand {
                            pane.filter.searchText = ""
                            searchFocused = false
                        }
                        .onSubmit { searchFocused = false }
                    if !pane.filter.searchText.isEmpty {
                        Button { pane.filter.searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: 260)
                .frame(height: 24)
                .background(.white.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                Spacer(minLength: 0)
                sortMenu
            }
            CategoryPills(pane: pane, color: color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $pane.filter.sortBy) {
                ForEach(FilterCriteria.SortField.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("Ascending", isOn: $pane.filter.sortAscending)
            Toggle("Folders First", isOn: $pane.filter.foldersFirst)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 10))
                Text(pane.filter.sortBy.rawValue).font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
    }
}

/// "All" plus a pill for each kind present in the folder.
private struct CategoryPills: View {
    @Bindable var pane: BrowserModel
    let color: Color

    private var present: [FileCategory] {
        let kinds = Set(pane.items.map(\.category)).union(pane.filter.categories)
        return FileCategory.allCases.filter(kinds.contains)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                pill("All", symbol: nil, selected: pane.filter.categories.isEmpty) { pane.filter.categories = [] }
                ForEach(present) { category in
                    let selected = pane.filter.categories.contains(category)
                    pill(category.displayName, symbol: category.systemImage, selected: selected) {
                        if selected { pane.filter.categories.remove(category) } else { pane.filter.categories.insert(category) }
                    }
                }
            }
        }
    }

    private func pill(_ title: String, symbol: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 9)) }
                Text(title).font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.85))
            .background(selected ? color.opacity(0.85) : Color.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

/// File cards with Quick Look thumbnails. Selection, drag out, drops onto folders and the
/// context menu come from CellInteraction, as in the browser.
private struct DrawerGrid: View {
    let model: AppModel
    @Bindable var pane: BrowserModel
    let color: Color

    static let minCard: CGFloat = 100
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let usable = geo.size.width - 2 * Self.padding
            let columns = max(1, Int((usable + Self.spacing) / (Self.minCard + Self.spacing)))
            let width = floor((usable - CGFloat(columns - 1) * Self.spacing) / CGFloat(columns))
            Group {
                if let error = pane.loadError {
                    placeholder(error, symbol: "exclamationmark.triangle")
                } else if pane.visible.isEmpty && !pane.isLoading {
                    placeholder(pane.filter.isActive ? "No matches" : "Empty folder",
                                symbol: pane.filter.isActive ? "line.3.horizontal.decrease.circle" : "tray")
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: Self.spacing), count: columns),
                                      alignment: .leading, spacing: Self.spacing) {
                                ForEach(pane.visible) { item in
                                    DrawerCard(model: model, pane: pane, item: item, color: color, width: width).id(item.url)
                                }
                            }
                            .padding(Self.padding)
                            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                            .background(
                                Color.clear.contentShape(Rectangle()).onTapGesture { pane.clearSelection() }
                            )
                        }
                        .onChange(of: pane.focus) {
                            if let focus = pane.focus { proxy.scrollTo(focus) }
                        }
                    }
                }
            }
            .onChange(of: columns, initial: true) { pane.columns = columns }
        }
        .modifier(FolderDropTarget(model: model, pane: pane))
    }

    private func placeholder(_ text: String, symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light))
            Text(text).font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DrawerCard: View {
    let model: AppModel
    @Bindable var pane: BrowserModel
    let item: FileItem
    let color: Color
    let width: CGFloat
    @State private var hovering = false

    private var isSelected: Bool { pane.selection.contains(item.url) }
    private var isRenaming: Bool { pane.renaming == item.url }

    var body: some View {
        VStack(spacing: 4) {
            FileIcon(item: item, size: 60, thumbnails: model.thumbnails)
                .frame(height: 62)
            if isRenaming {
                RenameField(model: model, pane: pane, item: item)
            } else {
                Text(item.name)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 4) {
                    if !item.tagNames.isEmpty { TagDots(tags: item.tagNames) }
                    Text(item.formattedSize).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(width: width, height: 128, alignment: .top)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .hairlineBorder(cornerRadius: Theme.cardRadius, color: isSelected ? color.opacity(0.9) : Theme.hairline.opacity(hovering ? 1.6 : 0.6))
        .overlay {
            if !isRenaming { CellInteraction(model: model, pane: pane, item: item) }
        }
        .onHover { hovering = $0 }
        .task(id: item.folderItemCount == nil) {
            if item.isBrowsable { await item.loadFolderItemCount() }
        }
    }

    private var background: Color {
        if pane.dropHighlight == item.url { return color.opacity(0.35) }
        if isSelected { return color.opacity(0.2) }
        return .white.opacity(hovering ? 0.08 : 0.03)
    }
}

private struct DrawerFooter: View {
    let model: AppModel
    let pane: BrowserModel

    var body: some View {
        HStack(spacing: 8) {
            Button { model.dock?.openInFullSift(pane.current) } label: {
                Label("Open in Full Sift", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Switch to the full browser at this folder")
            Spacer(minLength: 6)
            Text(statusText)
                .foregroundStyle(model.status?.isError == true ? Color.red : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Button(role: .destructive) { confirmTrashAll() } label: {
                Label("Trash All", systemImage: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(pane.visible.isEmpty ? Color.secondary : Color.red)
            .disabled(pane.visible.isEmpty || pane.isVirtual)
            .help("Move everything shown here to the Trash (Cmd-Z undoes)")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 30)
    }

    private var statusText: String {
        if let status = model.status { return status.text }
        let selected = pane.selection.count
        return selected > 0 ? "\(selected) selected" : ""
    }

    private func confirmTrashAll() {
        let urls = pane.visible.map(\.url)
        guard !urls.isEmpty else { return }
        let alert = NSAlert()
        let what = urls.count == 1 ? "1 item" : "\(urls.count) items"
        alert.messageText = "Move \(what) in \u{201C}\(pane.current.lastPathComponent)\u{201D} to the Trash?"
        alert.informativeText = pane.filter.isActive
            ? "Only the items matching the current search and filters. Cmd-Z puts them back."
            : "Cmd-Z puts them back."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { model.trash(urls) }
    }
}

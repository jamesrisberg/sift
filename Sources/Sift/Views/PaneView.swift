import FileKit
import SwiftUI

/// One browser pane: toolbar (history, path bar, search, sort/filter, view mode), the
/// listing, and a footer with counts.
struct PaneView: View {
    let model: AppModel
    @Bindable var pane: BrowserModel
    let isActive: Bool

    var body: some View {
        VStack(spacing: 0) {
            PaneToolbar(model: model, pane: pane, isActive: isActive)
            Hairline()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Hairline()
            footer
        }
        .frame(minWidth: 300, maxWidth: .infinity)
        .simultaneousGesture(TapGesture().onEnded { model.activate(pane) })
    }

    @ViewBuilder
    private var content: some View {
        if let error = pane.loadError {
            ContentUnavailableView("Can't open this folder", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if pane.isVirtual && pane.visible.isEmpty {
            if pane.isSearching {
                ProgressView("Searching…").controlSize(.small).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView(pane.virtualView?.isSearch == true ? "No results" : "Nothing here",
                                       systemImage: pane.virtualView?.symbol ?? "magnifyingglass")
            }
        } else if pane.visible.isEmpty && !pane.isLoading {
            ContentUnavailableView(pane.filter.isActive ? "No matches" : "Empty folder",
                                   systemImage: pane.filter.isActive ? "line.3.horizontal.decrease.circle" : "folder")
                .modifier(FolderDropTarget(model: model, pane: pane))
        } else {
            FileCollectionView(model: model, pane: pane)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            let selected = pane.selectedItems
            if selected.isEmpty {
                Text("\(pane.visible.count) \(pane.isVirtual ? "result" : "item")\(pane.visible.count == 1 ? "" : "s")")
                if pane.resultsTruncated { Text("(limit reached)") }
                if pane.isSearching && !pane.visible.isEmpty { ProgressView().controlSize(.mini) }
            } else {
                let bytes = selected.filter { !$0.isBrowsable }.reduce(Int64(0)) { $0 + $1.fileSize }
                Text("\(selected.count) of \(pane.visible.count) selected")
                if bytes > 0 { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
            }
            if pane.filter.isActive, pane.visible.count != pane.items.count {
                Text("(\(pane.items.count - pane.visible.count) hidden by filter)")
            }
            Spacer()
            if model.panes.count > 1, !isActive { Text("Tab to switch pane") }
        }
        .font(Theme.secondaryFont)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

struct PaneToolbar: View {
    let model: AppModel
    @Bindable var pane: BrowserModel
    let isActive: Bool
    @FocusState private var searchFocused: Bool

    private var isLast: Bool { model.panes.last === pane }

    var body: some View {
        HStack(spacing: 2) {
            Group {
                Button { pane.goBack() } label: { ToolbarIcon("chevron.left") }
                    .disabled(!pane.history.canGoBack)
                    .help("Back (Cmd-[)")
                Button { pane.goForward() } label: { ToolbarIcon("chevron.right") }
                    .disabled(!pane.history.canGoForward)
                    .help("Forward (Cmd-])")
                Button { pane.goUp() } label: { ToolbarIcon("arrow.up") }
                    .help("Enclosing folder (Cmd-Up)")
            }
            .buttonStyle(.borderless)

            Group {
                if let view = pane.virtualView {
                    VirtualTitle(pane: pane, view: view)
                } else {
                    PathBar(model: model, pane: pane)
                }
            }
                .padding(.horizontal, 4)
                .frame(minWidth: 40, maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    if isActive && model.panes.count > 1 {
                        Rectangle().fill(Color.accentColor).frame(height: 1.5).offset(y: 8)
                    }
                }

            HStack(spacing: 4) {
                searchScopeMenu
                TextField(searchPrompt, text: $pane.filter.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onExitCommand { pane.filter.searchText = ""; searchFocused = false }
                    .onSubmit { searchFocused = false }
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .frame(minWidth: 90, idealWidth: 170, maxWidth: 170)
            .frame(height: 24)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .hairlineBorder(cornerRadius: 6)
            .padding(.horizontal, 4)

            Group {
                filterMenu
                sortMenu

                Button {
                    pane.viewMode = pane.viewMode == .grid ? .list : .grid
                } label: {
                    ToolbarIcon(pane.viewMode == .grid ? "list.bullet" : "square.grid.2x2")
                }
                .help(pane.viewMode == .grid ? "Show as List (Cmd-2)" : "Show as Grid (Cmd-1)")

                Button { model.newFolder(in: pane) } label: { ToolbarIcon("folder.badge.plus") }
                    .disabled(pane.isVirtual)
                    .help("New Folder (Cmd-Shift-N)")
                Button { model.sheet = .rules } label: { ToolbarIcon("wand.and.stars") }
                    .help("Rules (Cmd-Shift-R)")
                Button { model.undo() } label: { ToolbarIcon("arrow.uturn.backward") }
                    .disabled(!model.canUndo)
                    .help("Undo (Cmd-Z)")
                if isLast {
                    Hairline(axis: .vertical).frame(height: 16).padding(.horizontal, 3)
                    Button { model.dock?.enterDockMode() } label: { ToolbarIcon("dock.rectangle") }
                        .help("Dock mode: a slim strip of targets at the screen edge")
                    Button { model.dock?.dismissPanel() } label: { ToolbarIcon("xmark") }
                        .help("Close (Esc). Sift stays in the menu bar; Option-/ brings it back")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, model.panes.first === pane ? 8 : 6)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(WindowDragHandle())
        .onChange(of: model.focusSearchRequest) {
            if isActive { searchFocused = true }
        }
    }

    private var searchPrompt: String {
        if pane.virtualView != nil, pane.virtualView?.isSearch == false { return "Filter" }
        switch pane.searchScope {
        case .folder: return "Search"
        case .subfolders: return "Search subfolders"
        case .spotlight: return "Spotlight"
        }
    }

    private var searchScopeMenu: some View {
        Menu {
            Picker("Search", selection: $pane.searchScope) {
                ForEach(SearchScope.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: pane.searchScope == .folder ? "magnifyingglass" : pane.searchScope.symbol)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Search in: \(pane.searchScope.rawValue)")
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
            ToolbarIcon("arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort")
    }

    private var filterMenu: some View {
        Menu {
            Section("Kind") {
                ForEach(FileCategory.allCases) { category in
                    Toggle(isOn: Binding(
                        get: { pane.filter.categories.contains(category) },
                        set: { on in
                            if on { pane.filter.categories.insert(category) } else { pane.filter.categories.remove(category) }
                        }
                    )) { Label(category.displayName, systemImage: category.systemImage) }
                }
            }
            Picker("Date Modified", selection: $pane.filter.dateRange) {
                ForEach(FilterCriteria.DateRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Picker("Size", selection: $pane.filter.sizeRange) {
                ForEach(FilterCriteria.SizeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Section("Tags") {
                ForEach(tagChoices, id: \.self) { tag in
                    Toggle(isOn: Binding(
                        get: { pane.filter.tags.contains(tag) },
                        set: { on in if on { pane.filter.tags.insert(tag) } else { pane.filter.tags.remove(tag) } }
                    )) { Label { Text(tag) } icon: { TagDot(name: tag, size: 9) } }
                }
            }
            Divider()
            Button("Clear Filters") { pane.filter.reset() }.disabled(!pane.filter.isActive)
        } label: {
            ToolbarIcon(pane.filter.isActive
                        ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter")
    }

    /// Tags used in this listing (plus any already filtered on), else the standard ones.
    private var tagChoices: [String] {
        var seen = Set<String>()
        var used: [String] = []
        for item in pane.items { for tag in item.tagNames where seen.insert(tag).inserted { used.append(tag) } }
        for tag in pane.filter.tags.sorted() where seen.insert(tag).inserted { used.append(tag) }
        return used.isEmpty ? FileTags.standard.map(\.name) : used
    }
}

/// A toolbar symbol in a 28 pt square hit area.
struct ToolbarIcon: View {
    let symbol: String
    init(_ symbol: String) { self.symbol = symbol }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
    }
}

/// Replaces the path bar while a search or smart view is showing.
struct VirtualTitle: View {
    let pane: BrowserModel
    let view: VirtualView

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: view.symbol).foregroundStyle(Color.accentColor)
            Text(view.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Button { pane.closeVirtualView() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Back to \(pane.current.lastPathComponent) (Cmd-[)")
        }
    }
}

/// Breadcrumbs from the volume root to the current folder. Each crumb navigates on click
/// and accepts drops.
struct PathBar: View {
    let model: AppModel
    let pane: BrowserModel

    var body: some View {
        let crumbs = pane.history.breadcrumbs
        let home = FileManager.default.homeDirectoryForCurrentUser.normalizedFileURL
        // Collapse everything above home into "~".
        let startIndex = crumbs.firstIndex(of: home) ?? 0
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(crumbs[startIndex...].enumerated()), id: \.element) { offset, url in
                        if offset > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        }
                        Crumb(model: model, pane: pane, url: url,
                              title: url == home ? "~" : (url.path(percentEncoded: false) == "/" ? "/" : url.lastPathComponent),
                              isLast: url == pane.current)
                            .id(url)
                    }
                }
            }
            .onAppear { proxy.scrollTo(pane.current, anchor: .trailing) }
            .onChange(of: pane.current) { proxy.scrollTo(pane.current, anchor: .trailing) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Crumb: View {
    let model: AppModel
    let pane: BrowserModel
    let url: URL
    let title: String
    let isLast: Bool
    @State private var targeted = false

    var body: some View {
        Text(title)
            .font(.callout.weight(isLast ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(targeted ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .onTapGesture { pane.navigate(to: url) }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                let copy = NSEvent.modifierFlags.contains(.option)
                loadFileURLs(providers) { model.drop($0, into: url, copy: copy) }
                return true
            }
    }
}

import FileKit
import SwiftUI

/// The listing as a grid or list. Cells get an AppKit overlay (CellInteraction) for
/// click-selection, multi-item drag out, drops onto folders and the context menu.
struct FileCollectionView: View {
    let model: AppModel
    @Bindable var pane: BrowserModel

    static let cellWidth: CGFloat = 104
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let columns = max(1, Int((geo.size.width - 2 * Self.padding + Self.spacing) / (Self.cellWidth + Self.spacing)))
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if pane.viewMode == .grid {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Self.cellWidth), spacing: Self.spacing), count: columns),
                                      alignment: .leading, spacing: Self.spacing) {
                                ForEach(pane.visible) { item in
                                    GridCell(model: model, pane: pane, item: item).id(item.url)
                                }
                            }
                            .padding(Self.padding)
                        } else {
                            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                                let showKind = geo.size.width > 560
                                Section(header: ListHeader(pane: pane, showKind: showKind)) {
                                    ForEach(Array(pane.visible.enumerated()), id: \.element.id) { index, item in
                                        ListRow(model: model, pane: pane, item: item, striped: index % 2 == 1, showKind: showKind)
                                            .id(item.url)
                                    }
                                }
                            }
                            .padding(.bottom, Self.padding)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .topLeading)
                    .background(
                        // Clicking empty space clears the selection.
                        Color.clear.contentShape(Rectangle()).onTapGesture {
                            model.activate(pane)
                            pane.clearSelection()
                        }
                    )
                }
                .onChange(of: pane.focus) {
                    if let focus = pane.focus { proxy.scrollTo(focus) }
                }
            }
            .onChange(of: columns, initial: true) { pane.columns = columns }
        }
        .modifier(FolderDropTarget(model: model, pane: pane))
    }
}

/// Dropping onto the listing background moves into the current folder (Option copies).
struct FolderDropTarget: ViewModifier {
    let model: AppModel
    let pane: BrowserModel
    @State private var targeted = false

    func body(content: Content) -> some View {
        if pane.isVirtual {
            // Results come from many folders; there is no single folder to drop into.
            content
        } else {
            droppable(content)
        }
    }

    private func droppable(_ content: Content) -> some View {
        content
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Color.accentColor, lineWidth: 1.5).padding(3)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                let copy = NSEvent.modifierFlags.contains(.option)
                let dir = pane.current
                loadFileURLs(providers) { model.drop($0, into: dir, copy: copy) }
                return true
            }
    }
}

struct GridCell: View {
    let model: AppModel
    @Bindable var pane: BrowserModel
    let item: FileItem

    private var isSelected: Bool { pane.selection.contains(item.url) }
    private var isRenaming: Bool { pane.renaming == item.url }

    var body: some View {
        VStack(spacing: 4) {
            FileIcon(item: item, size: 64, thumbnails: model.thumbnails)
                .padding(4)
                .background(isSelected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            if isRenaming {
                RenameField(model: model, pane: pane, item: item)
            } else {
                Text(item.name)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 4) {
                    if !item.tagNames.isEmpty { TagDots(tags: item.tagNames) }
                    Text(item.formattedSize)
                        .font(Theme.secondaryFont)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: FileCollectionView.cellWidth, height: 124, alignment: .top)
        .padding(.vertical, 2)
        .background(highlight, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            if !isRenaming { CellInteraction(model: model, pane: pane, item: item) }
        }
        .task(id: item.folderItemCount == nil) {
            if item.isBrowsable { await item.loadFolderItemCount() }
        }
    }

    private var highlight: Color {
        if pane.dropHighlight == item.url { return Color.accentColor.opacity(0.3) }
        if pane.focus == item.url && isSelected { return Color.primary.opacity(0.04) }
        return .clear
    }
}

struct ListHeader: View {
    @Bindable var pane: BrowserModel
    let showKind: Bool

    var body: some View {
        HStack(spacing: 8) {
            header("Name", .name).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
            header("Date Modified", .modificationDate).frame(width: 96, alignment: .leading)
            header("Size", .fileSize).frame(width: 68, alignment: .trailing)
            if showKind { header("Kind", .category).frame(width: 84, alignment: .leading) }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(.bar)
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func header(_ title: String, _ field: FilterCriteria.SortField) -> some View {
        Button {
            if pane.filter.sortBy == field { pane.filter.sortAscending.toggle() } else { pane.filter.sortBy = field }
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if pane.filter.sortBy == field {
                    Image(systemName: pane.filter.sortAscending ? "chevron.up" : "chevron.down").font(.system(size: 8))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct ListRow: View {
    let model: AppModel
    @Bindable var pane: BrowserModel
    let item: FileItem
    let striped: Bool
    let showKind: Bool

    private var isSelected: Bool { pane.selection.contains(item.url) }
    private var isRenaming: Bool { pane.renaming == item.url }

    var body: some View {
        HStack(spacing: 8) {
            FileIcon(item: item, size: 20, thumbnails: model.thumbnails)
            if isRenaming {
                RenameField(model: model, pane: pane, item: item).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    if !item.tagNames.isEmpty { TagDots(tags: item.tagNames) }
                    if pane.isVirtual {
                        Text(RulePaths.string(item.url.parentFolder))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(item.formattedDate).frame(width: 96, alignment: .leading)
                .foregroundStyle(isSelected ? .primary : .secondary)
            Text(item.formattedSize).frame(width: 68, alignment: .trailing).monospacedDigit()
                .foregroundStyle(isSelected ? .primary : .secondary)
            if showKind {
                Text(item.category.kindName)
                    .frame(width: 84, alignment: .leading)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(background)
        .overlay {
            if !isRenaming { CellInteraction(model: model, pane: pane, item: item) }
        }
        .task(id: item.folderItemCount == nil) {
            if item.isBrowsable { await item.loadFolderItemCount() }
        }
    }

    private var background: Color {
        if pane.dropHighlight == item.url { return Color.accentColor.opacity(0.35) }
        if isSelected { return Color.accentColor.opacity(0.35) }
        return striped ? Color.primary.opacity(0.03) : .clear
    }
}

struct RenameField: View {
    let model: AppModel
    let pane: BrowserModel
    let item: FileItem
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            .focused($focused)
            .onAppear {
                text = item.name
                focused = true
            }
            .onSubmit { commit() }
            .onExitCommand { pane.renaming = nil }
            .onChange(of: focused) { if !focused && pane.renaming == item.url { commit() } }
    }

    private func commit() {
        guard pane.renaming == item.url else { return }
        pane.renaming = nil
        if text != item.name { model.rename(item.url, to: text) }
    }
}

/// Quick Look thumbnail with the Finder icon as placeholder and fallback.
struct FileIcon: View {
    let item: FileItem
    let size: CGFloat
    let thumbnails: ThumbnailGenerator

    var body: some View {
        Group {
            if let cg = item.thumbnail {
                Image(decorative: cg, scale: 2).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: IconCache.icon(for: item.url)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.modificationDate) {
            // Folders and tiny list icons use the Finder icon; thumbnails are generated only
            // for visible cells (LazyVGrid), not the whole folder up front.
            guard size >= 32, !item.isBrowsable, item.thumbnail == nil else { return }
            item.thumbnail = await thumbnails.thumbnail(for: item.url, modified: item.modificationDate)
        }
    }
}

enum IconCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 1000
        return c
    }()

    static func icon(for url: URL) -> NSImage {
        let key = url.path(percentEncoded: false) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        cache.setObject(icon, forKey: key)
        return icon
    }
}

extension FileCategory {
    /// Singular label for the Kind column.
    var kindName: String {
        switch self {
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .pdf: "PDF"
        case .document: "Document"
        case .archive: "Archive"
        case .app: "Application"
        case .code: "Code"
        case .folder: "Folder"
        case .other: "Document"
        }
    }
}

/// Finder-style overlapping tag dots (at most three).
struct TagDots: View {
    let tags: [String]

    var body: some View {
        HStack(spacing: -3) {
            ForEach(tags.prefix(3), id: \.self) { TagDot(name: $0, size: 8) }
        }
        .help(tags.joined(separator: ", "))
    }
}

struct TagDot: View {
    let name: String
    let size: CGFloat

    var body: some View {
        let color = FileTags.standardColor(for: name)
        Circle()
            .fill(color.hex.flatMap { Color(hex: $0) } ?? Color.clear)
            .overlay(Circle().strokeBorder(color == .none ? Color.secondary : Color.black.opacity(0.35), lineWidth: color == .none ? 1 : 0.5))
            .frame(width: size, height: size)
    }
}

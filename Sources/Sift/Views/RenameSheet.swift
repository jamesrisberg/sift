import FileKit
import SwiftUI

/// Batch rename: a pattern with tokens plus find/replace, previewed live, applied as one
/// undoable group.
struct RenameSheet: View {
    let model: AppModel
    let urls: [URL]

    @State private var template = RenameTemplate()
    /// The last pattern used, offered again next time.
    @AppStorage("renamePattern") private var lastPattern = "{name}"
    @State private var inputs: [RenameTemplate.Input] = []
    @State private var rows: [BatchRename.Row] = []
    @State private var error: String?

    private static let tokens: [(String, String)] = [
        ("{name}", "Original name"), ("{ext}", "Extension"), ("{n}", "Counter"), ("{n:3}", "Counter, 3 digits"),
        ("{date}", "Date modified (yyyy-MM-dd)"), ("{date:yyyyMMdd}", "Date modified, compact"),
    ]

    private var changing: Int { rows.filter { !$0.isUnchanged }.count }
    private var problems: Int { rows.filter { $0.problem != nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "Rename \(urls.count == 1 ? "1 Item" : "\(urls.count) Items")",
                        symbol: "character.cursor.ibeam") { model.sheet = nil }
            form
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            Hairline()
            preview
            Hairline()
            footer
        }
        .onAppear(perform: load)
        .onChange(of: template) {
            lastPattern = template.pattern
            recompute()
        }
    }

    private var form: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 9) {
            GridRow {
                Text("Pattern").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("{name}", text: $template.pattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                    Menu {
                        ForEach(Self.tokens, id: \.0) { token, title in
                            Button("\(token)  \(title)") { template.pattern += token }
                        }
                    } label: { Label("Token", systemImage: "curlybraces") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                }
            }
            GridRow {
                Text("Find").foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("text or pattern", text: $template.find).textFieldStyle(.roundedBorder)
                    Text("Replace").foregroundStyle(.secondary)
                    TextField(template.useRegex ? "$1 for groups" : "replacement", text: $template.replace)
                        .textFieldStyle(.roundedBorder)
                }
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                HStack(spacing: 14) {
                    Toggle("Regular expression", isOn: $template.useRegex)
                    Toggle("Match case", isOn: $template.caseSensitive)
                    Toggle("Keep extension", isOn: $template.keepExtension)
                    Spacer()
                    Stepper("Start at \(template.startNumber)", value: $template.startNumber, in: 0...99_999)
                        .fixedSize()
                }
                .toggleStyle(.checkbox)
                .font(.callout)
            }
        }
    }

    private var preview: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 10) {
                        Text(row.source.lastPathComponent)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                        Text(row.newName)
                            .fontWeight(row.isUnchanged ? .regular : .medium)
                            .foregroundStyle(row.problem != nil ? Color.red : (row.isUnchanged ? .secondary : .primary))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.problem?.message ?? "")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(width: 104, alignment: .trailing)
                    }
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.callout)
                    .padding(.horizontal, 18)
                    .frame(height: 24)
                    .background(index % 2 == 1 ? Color.white.opacity(0.03) : .clear)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var footer: some View {
        HStack {
            Text(problems > 0 ? "\(problems) problem\(problems == 1 ? "" : "s") to fix"
                 : changing == 0 ? "No names change" : "\(changing) of \(rows.count) will be renamed")
                .font(.callout)
                .foregroundStyle(problems > 0 ? Color.red : .secondary)
            Spacer()
            Button("Cancel") { model.sheet = nil }
            Button("Rename") {
                model.batchRename(rows.map { ($0.source, $0.newName) })
                model.sheet = nil
            }
            .buttonStyle(.borderedProminent)
            .disabled(problems > 0 || changing == 0 || error != nil)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func load() {
        template.pattern = lastPattern
        inputs = urls.map { url in
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey])
            return RenameTemplate.Input(url: url, isDirectory: (v?.isDirectory ?? false) && !(v?.isPackage ?? false),
                                        date: v?.contentModificationDate)
        }
        recompute()
    }

    private func recompute() {
        do {
            rows = try BatchRename.plan(inputs, template: template)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Title row shared by the sheets.
struct SheetHeader: View {
    let title: String
    let symbol: String
    var trailing: AnyView? = nil
    let close: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Spacer()
            if let trailing { trailing }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(WindowDragHandle())
    }
}

import AppKit
import FileKit
import SwiftUI

/// Create and edit rules (saved to rules.json as you type), with a live preview of what
/// they would do in the current folder. Ticked steps apply as one undoable group.
struct RulesSheet: View {
    let model: AppModel
    @Bindable var rules: RulesController
    @State private var selection: UUID?

    private var folder: URL { model.activePane.current }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Rules", symbol: "wand.and.stars",
                        trailing: AnyView(Button("Open rules.json") { revealFile() }.buttonStyle(.link).font(.callout))) {
                rules.saveNow()
                model.sheet = nil
            }
            if let error = rules.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
            }
            Hairline()
            HStack(spacing: 0) {
                sidebar.frame(width: 220)
                Hairline(axis: .vertical)
                VStack(spacing: 0) {
                    editor
                    Hairline()
                    RulePreview(model: model, rules: rules)
                        .frame(height: 190)
                }
            }
        }
        .onAppear {
            rules.reload()
            selection = rules.ruleSet.rules.first?.id
            rules.refreshPreview(in: folder)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(rules.ruleSet.rules.enumerated()), id: \.element.id) { index, rule in
                        RuleRow(rule: rule, index: index, selected: selection == rule.id) {
                            rules.updateRule(rule.id) { $0.enabled.toggle() }
                        }
                        .onTapGesture { selection = rule.id }
                    }
                    if rules.ruleSet.rules.isEmpty {
                        Text("No rules yet. Rules run top to bottom; the first match wins.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(10)
                    }
                }
                .padding(8)
            }
            HStack(spacing: 4) {
                Button { selection = rules.addRule() } label: { Image(systemName: "plus") }
                    .help("Add a rule")
                Button {
                    if let id = selection {
                        let index = rules.ruleSet.rules.firstIndex { $0.id == id } ?? 0
                        rules.removeRule(id)
                        let remaining = rules.ruleSet.rules
                        selection = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
                    }
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Delete the selected rule")
                Spacer()
                Button { if let id = selection { rules.moveRule(id, by: -1) } } label: { Image(systemName: "chevron.up") }
                    .disabled(selection == nil).help("Earlier (runs first)")
                Button { if let id = selection { rules.moveRule(id, by: 1) } } label: { Image(systemName: "chevron.down") }
                    .disabled(selection == nil).help("Later")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Hairline()
            watchSection
        }
    }

    private var watchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Apply automatically", isOn: Binding(get: { rules.ruleSet.autoApply }, set: { rules.setAutoApply($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.callout)
            Text("New files in watched folders are sorted as they arrive (Cmd-Z undoes).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rules.ruleSet.watch, id: \.self) { path in
                HStack(spacing: 4) {
                    Image(systemName: "eye").font(.caption2).foregroundStyle(.secondary)
                    Text(path).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { rules.removeWatchFolder(path) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
            Button("Watch \(folder.lastPathComponent)") { rules.addWatchFolder(folder) }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(rules.ruleSet.watch.contains(RulePaths.string(folder)))
        }
        .padding(12)
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if let id = selection, let rule = rules.ruleSet.rules.first(where: { $0.id == id }) {
            RuleEditor(model: model, rules: rules, rule: rule)
                .id(rule.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "wand.and.stars").font(.largeTitle).foregroundStyle(.tertiary)
                Text("Rules sort files for you: match by type, name, age, size or download source, then move, tag, rename or trash.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
                Button("Add Rule") { selection = rules.addRule() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func revealFile() {
        if !FileManager.default.fileExists(atPath: rules.store.fileURL.path(percentEncoded: false)) { rules.saveNow() }
        NSWorkspace.shared.activateFileViewerSelecting([rules.store.fileURL])
    }
}

private struct RuleRow: View {
    let rule: Rule
    let index: Int
    let selected: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { _ in toggle() }))
                .toggleStyle(.checkbox)
                .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text(rule.name).lineLimit(1)
                Text(rule.action.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.accentColor.opacity(0.3) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .opacity(rule.enabled ? 1 : 0.55)
    }
}

/// Edits one rule. Fields keep what you type (so "pdf, " can become "pdf, png") and push the
/// parsed value to the controller on every change.
private struct RuleEditor: View {
    enum ActionKind: String, CaseIterable { case move = "Move to", trash = "Move to Trash", tag = "Add tags", rename = "Rename" }

    let model: AppModel
    let rules: RulesController
    let rule: Rule

    @State private var name = ""
    @State private var extensions = ""
    @State private var types = ""
    @State private var nameRegex = ""
    @State private var minAge = ""
    @State private var domains = ""
    @State private var minSizeMB = ""
    @State private var maxSizeMB = ""
    @State private var folders = ""
    @State private var includeFolders = false
    @State private var kind: ActionKind = .trash
    @State private var moveTo = ""
    @State private var tags = ""
    @State private var template = "{date} {name}"
    @State private var loaded = false

    var body: some View {
        ScrollView {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                row("Name") { TextField("Rule name", text: $name) }
                GridRow {
                    Text("IF").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("all of these hold (empty fields are ignored)").font(.caption).foregroundStyle(.secondary)
                }
                row("Extensions") { TextField("pdf, jpg", text: $extensions) }
                row("Types") { TextField("public.image, public.movie", text: $types) }
                row("Name matches") {
                    HStack {
                        TextField("regular expression, e.g. ^Screenshot", text: $nameRegex)
                        if regexError { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).help("Invalid regular expression") }
                    }
                }
                row("Older than") { HStack { TextField("", text: $minAge).frame(width: 60); Text("days").foregroundStyle(.secondary); Spacer() } }
                row("Downloaded from") { TextField("github.com, arxiv.org", text: $domains) }
                row("Size") {
                    HStack {
                        TextField("min", text: $minSizeMB).frame(width: 60)
                        Text("to").foregroundStyle(.secondary)
                        TextField("max", text: $maxSizeMB).frame(width: 60)
                        Text("MB").foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                row("In folders") {
                    HStack {
                        TextField("~/Downloads (and subfolders)", text: $folders)
                        Button("Current") { folders = RulePaths.string(model.activePane.current) }.controlSize(.small)
                    }
                }
                row("") { Toggle("Match folders too", isOn: $includeFolders).toggleStyle(.checkbox) }
                GridRow {
                    Text("THEN").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("", selection: $kind) {
                        ForEach(ActionKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                switch kind {
                case .move:
                    row("Destination") {
                        HStack {
                            TextField("~/Pictures/Screenshots or target:Name", text: $moveTo)
                            Menu("Target") {
                                ForEach(model.targets) { t in Button(t.name) { moveTo = "target:\(t.name)" } }
                            }
                            .fixedSize()
                            Button("Choose…") { choose() }.controlSize(.small)
                        }
                    }
                case .tag:
                    row("Tags") { TextField("Red, Work", text: $tags) }
                case .rename:
                    row("Pattern") { TextField("{date} {name}", text: $template).font(.body.monospaced()) }
                case .trash:
                    EmptyView()
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .padding(16)
        }
        .onAppear(perform: load)
        .onChange(of: snapshot) { if loaded { push() } }
    }

    private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content()
        }
    }

    private var regexError: Bool {
        !nameRegex.isEmpty && (try? NSRegularExpression(pattern: nameRegex)) == nil
    }

    /// Everything editable, so one onChange covers all fields.
    private var snapshot: [String] {
        [name, extensions, types, nameRegex, minAge, domains, minSizeMB, maxSizeMB, folders,
         "\(includeFolders)", kind.rawValue, moveTo, tags, template]
    }

    private func load() {
        name = rule.name
        let m = rule.match
        extensions = (m.extensions ?? []).joined(separator: ", ")
        types = (m.types ?? []).joined(separator: ", ")
        nameRegex = m.nameRegex ?? ""
        minAge = m.minAgeDays.map { Self.number($0) } ?? ""
        domains = (m.sourceDomains ?? []).joined(separator: ", ")
        minSizeMB = m.minSize.map { Self.number(Double($0) / 1_000_000) } ?? ""
        maxSizeMB = m.maxSize.map { Self.number(Double($0) / 1_000_000) } ?? ""
        folders = (m.folders ?? []).joined(separator: ", ")
        includeFolders = m.includeFolders ?? false
        switch rule.action {
        case let .move(to): kind = .move; moveTo = to
        case .trash: kind = .trash
        case let .tag(t): kind = .tag; tags = t.joined(separator: ", ")
        case let .rename(t): kind = .rename; template = t
        }
        DispatchQueue.main.async { loaded = true }
    }

    private func push() {
        let match = RuleMatch(
            extensions: Self.list(extensions), types: Self.list(types),
            nameRegex: nameRegex.isEmpty ? nil : nameRegex,
            minAgeDays: Double(minAge.trimmingCharacters(in: .whitespaces)),
            sourceDomains: Self.list(domains),
            minSize: Double(minSizeMB.trimmingCharacters(in: .whitespaces)).map { Int64($0 * 1_000_000) },
            maxSize: Double(maxSizeMB.trimmingCharacters(in: .whitespaces)).map { Int64($0 * 1_000_000) },
            folders: Self.list(folders), includeFolders: includeFolders ? true : nil)
        let action: RuleAction
        switch kind {
        case .move: action = .move(to: moveTo.trimmingCharacters(in: .whitespaces))
        case .trash: action = .trash
        case .tag: action = .tag(Self.list(tags) ?? [])
        case .rename: action = .rename(template: template)
        }
        rules.updateRule(rule.id) {
            $0.name = name.isEmpty ? "Untitled Rule" : name
            $0.match = match
            $0.action = action
        }
    }

    private func choose() {
        let open = NSOpenPanel()
        open.canChooseDirectories = true
        open.canChooseFiles = false
        open.canCreateDirectories = true
        open.prompt = "Choose"
        if open.runModal() == .OK, let url = open.url { moveTo = RulePaths.string(url) }
    }

    static func list(_ text: String) -> [String]? {
        let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return items.isEmpty ? nil : items
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// What the rules would do in the current folder, with a checkbox per step.
private struct RulePreview: View {
    let model: AppModel
    @Bindable var rules: RulesController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Preview in \(rules.previewFolder?.lastPathComponent ?? "folder")").font(.callout.weight(.semibold))
                if rules.isEvaluating { ProgressView().controlSize(.small) }
                Spacer()
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Button { rules.refreshPreview(in: model.activePane.current) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Re-evaluate")
                Button("Apply \(rules.selectedPlans.count)") { rules.applySelected() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(rules.selectedPlans.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if rules.plans.isEmpty && !rules.isEvaluating {
                        Text("Nothing here matches an enabled rule.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 20)
                    }
                    ForEach(Array(rules.plans.enumerated()), id: \.element.id) { index, plan in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { plan.problem == nil && !rules.excluded.contains(plan.id) },
                                set: { on in if on { rules.excluded.remove(plan.id) } else { rules.excluded.insert(plan.id) } }
                            ))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(plan.problem != nil)
                            Image(nsImage: IconCache.icon(for: plan.source)).resizable().frame(width: 16, height: 16)
                            Text(plan.source.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(plan.problem ?? plan.summary)
                                .foregroundStyle(plan.problem == nil ? Color.secondary : Color.red)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(plan.ruleName).font(.caption).foregroundStyle(.tertiary).lineLimit(1).frame(width: 90, alignment: .trailing)
                        }
                        .font(.callout)
                        .padding(.horizontal, 14)
                        .frame(height: 22)
                        .background(index % 2 == 1 ? Color.white.opacity(0.03) : .clear)
                    }
                }
            }
        }
    }

    private var summary: String {
        let problems = rules.plans.filter { $0.problem != nil }.count
        var text = "\(rules.plans.count) planned"
        if problems > 0 { text += ", \(problems) blocked" }
        return text
    }
}

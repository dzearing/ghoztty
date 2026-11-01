import SwiftUI

/// Editing hooks for `ShortcutListView`. The keyboard shortcut guide passes
/// none (read-only); the Settings window's Keyboard page passes one to record,
/// add, remove and reset bindings. Every hook has a default, so an editor
/// implements only what it needs.
protocol ShortcutEditing: AnyObject {
    /// Whether `action` differs from the defaults. Defaults to the catalog's answer.
    func isCustomized(action: String, row: ShortcutRow) -> Bool
    /// A keycap group was clicked (e.g. to re-record it).
    func tapKeycap(action: String, binding: ShortcutBinding)
    /// The row's add button: bind another trigger to `action`.
    func add(action: String)
    /// Remove one binding of `action`.
    func remove(action: String, binding: ShortcutBinding)
    /// Restore `action`'s default bindings.
    func reset(action: String)
    /// Extra controls drawn at the trailing edge of a row (a recorder,
    /// a conflict warning…). Nil draws nothing.
    func accessory(for row: ShortcutRow) -> AnyView?
}

extension ShortcutEditing {
    func isCustomized(action: String, row: ShortcutRow) -> Bool { row.isCustomized }
    func tapKeycap(action: String, binding: ShortcutBinding) {}
    func add(action: String) {}
    func remove(action: String, binding: ShortcutBinding) {}
    func reset(action: String) {}
    func accessory(for row: ShortcutRow) -> AnyView? { nil }
}

/// The categorized, searchable list of shortcuts. Shared by the shortcut guide
/// (read-only) and the Settings window (with an `editor`).
struct ShortcutListView: View {
    let catalog: KeybindCatalog
    var query: String = ""
    /// Show only this category; nil shows all.
    var category: ShortcutCategory?
    var includeUnbound: Bool = false
    var editor: ShortcutEditing?
    /// Keyboard-selected row id (highlighted, scrolled into view).
    var selection: Binding<String?> = .constant(nil)
    /// Runs a row's action; nil hides the run buttons.
    var onRun: ((ShortcutRow) -> Void)?

    /// The rows this list shows, in order — also what keyboard navigation walks.
    static func visibleRows(
        catalog: KeybindCatalog, query: String, category: ShortcutCategory?,
        includeUnbound: Bool, editing: Bool
    ) -> [ShortcutRow] {
        // Families stay expanded while editing: each action is edited on its own.
        catalog.rows(groupingFamilies: !editing, includeUnbound: includeUnbound || editing)
            .filter { category == nil || $0.category == category || !query.isEmpty }
            .filter { KeybindCatalog.matches($0, query: query) }
    }

    private var rows: [ShortcutRow] {
        Self.visibleRows(catalog: catalog, query: query, category: category,
                         includeUnbound: includeUnbound, editing: editor != nil)
    }

    var body: some View {
        let rows = self.rows
        let sections = ShortcutCategory.allCases.compactMap { cat -> (ShortcutCategory, [ShortcutRow])? in
            let inCat = rows.filter { $0.category == cat }
            return inCat.isEmpty ? nil : (cat, inCat)
        }
        ScrollViewReader { proxy in
            ScrollView {
                if sections.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections, id: \.0) { cat, rows in
                            Section {
                                card(rows)
                            } header: {
                                sectionHeader(cat)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
            .onChange(of: selection.wrappedValue) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: nil) }
            }
        }
    }

    private func sectionHeader(_ cat: ShortcutCategory) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(cat.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            if let sub = cat.subtitle {
                Text(sub).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityAddTraits(.isHeader)
    }

    private func card(_ rows: [ShortcutRow]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { Divider().padding(.leading, 12) }
                ShortcutRowView(
                    row: row, query: query, editor: editor,
                    isSelected: selection.wrappedValue == row.id,
                    onRun: onRun,
                    onSelect: { selection.wrappedValue = row.id })
                .id(row.id)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "keyboard").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text("No shortcuts match “\(query)”").font(.headline)
            Text("Try an action (“split”), a key (“⌘D”, “cmd shift p”), or show unbound actions.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
        .padding(.horizontal, 20)
    }
}

/// One shortcut: title + badges, description, keycaps, optional run button.
struct ShortcutRowView: View {
    let row: ShortcutRow
    let query: String
    let editor: ShortcutEditing?
    let isSelected: Bool
    let onRun: ((ShortcutRow) -> Void)?
    let onSelect: () -> Void

    @State private var hovering = false

    private var customized: Bool {
        guard let editor, let action = row.actions.first else { return row.isCustomized }
        return editor.isCustomized(action: action, row: row)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(highlighted(row.title)).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(row.isBound || row.kind == .builtIn ? .primary : .secondary)
                    badges
                }
                Text(highlighted(row.detail)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if row.isUncurated || editor != nil {
                    Text(row.actions.joined(separator: ", "))
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            keys
            if let accessory = editor?.accessory(for: row) { accessory }
            if let editor, let action = row.actions.first, row.kind == .keybind {
                editButtons(editor: editor, action: action)
            }
            if let onRun, editor == nil {
                Button { onRun(row) } label: {
                    Image(systemName: "play.fill").font(.system(size: 9))
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.accentColor.opacity(0.14)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("Run now")
                .accessibilityLabel("Run \(row.title)")
                .opacity(row.isRunnable && (hovering || isSelected) ? 1 : 0)
                .disabled(!row.isRunnable)
                .accessibilityHidden(!row.isRunnable)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.14) : hovering ? Color.primary.opacity(0.035) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var badges: some View {
        if customized { Badge(text: "CUSTOM", tint: .orange) }
        if row.isGlobal { Badge(text: "GLOBAL", tint: .purple) }
        ForEach(row.tables, id: \.self) { Badge(text: "TABLE: \($0.uppercased())", tint: .teal) }
        if row.kind == .builtIn { Badge(text: "BUILT-IN", tint: .gray) }
    }

    @ViewBuilder private var keys: some View {
        if row.bindings.isEmpty {
            Text(row.isUnboundByUser ? "Unbound in your config" : "Not bound")
                .font(.system(size: 12)).italic().foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(row.bindings.enumerated()), id: \.element.id) { index, binding in
                    HStack(spacing: 3) {
                        if index > 0 { Text("or").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.trailing, 2) }
                        KeyComboView(binding: binding)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if let editor, let action = row.actions.first { editor.tapKeycap(action: action, binding: binding) }
                        else { onSelect() }
                    }
                    .contextMenu {
                        if let editor, let action = row.actions.first {
                            Button("Remove \(binding.trigger.display)") { editor.remove(action: action, binding: binding) }
                        }
                    }
                }
            }
        }
    }

    private func editButtons(editor: ShortcutEditing, action: String) -> some View {
        HStack(spacing: 4) {
            Button { editor.add(action: action) } label: { Image(systemName: "plus") }
                .help("Add a shortcut for \(row.title)")
            if customized {
                Button { editor.reset(action: action) } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Restore the default shortcut")
            }
        }
        .buttonStyle(.borderless)
    }

    private var accessibilityText: String {
        var parts = [row.title, row.detail]
        if row.bindings.isEmpty {
            parts.append(row.isUnboundByUser ? "Unbound in your config" : "Not bound")
        } else {
            parts.append(row.bindings.map { b in
                if let keys = b.familyKeys {
                    let mods = b.trigger.steps.first?.modifiers.map(\.spokenName).joined(separator: " ") ?? ""
                    return "\(mods) plus \(keys.map(KeyTrigger.spokenName(forKey:)).joined(separator: ", "))"
                }
                return b.trigger.spoken
            }.joined(separator: ", or "))
        }
        if customized { parts.append("customized") }
        if row.isGlobal { parts.append("global") }
        return parts.joined(separator: ". ")
    }

    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let range = attributed.range(of: q, options: .caseInsensitive) else { return attributed }
        attributed[range].backgroundColor = Color.yellow.opacity(0.35)
        return attributed
    }
}

/// A small capsule label.
struct Badge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.3)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.15)))
    }
}

/// One binding drawn as keycaps: `⇧ ⌘ D`, `⌃ A then N`, or a family
/// `⌥ ⌘ + ↑ ↓ ← →` / `⌘ + 1 … 8`.
struct KeyComboView: View {
    let binding: ShortcutBinding

    var body: some View {
        HStack(spacing: 3) {
            if let keys = binding.familyKeys, let step = binding.trigger.steps.first {
                ForEach(step.modifiers, id: \.self) { Keycap(label: $0.glyph, isModifier: true) }
                Text("+").font(.system(size: 11)).foregroundStyle(.tertiary)
                if keys.count > 3, keys.allSatisfy({ Int($0) != nil }), let first = keys.first, let last = keys.last {
                    Keycap(label: KeyTrigger.displayName(forKey: first))
                    Text("…").font(.system(size: 11)).foregroundStyle(.tertiary)
                    Keycap(label: KeyTrigger.displayName(forKey: last))
                } else {
                    ForEach(keys, id: \.self) { Keycap(label: KeyTrigger.displayName(forKey: $0)) }
                }
            } else {
                ForEach(Array(binding.trigger.steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 { Text("then").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 2) }
                    ForEach(step.modifiers, id: \.self) { Keycap(label: $0.glyph, isModifier: true) }
                    Keycap(label: KeyTrigger.displayName(forKey: step.key))
                }
            }
        }
        .help(binding.trigger.canonical)
    }
}

/// A single keycap.
struct Keycap: View {
    let label: String
    var isModifier: Bool = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(label)
            .font(.system(size: isModifier ? 13 : (label.count > 2 ? 11 : 12), weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, label.count > 1 && !isModifier ? 6 : 4)
            .frame(minWidth: 22, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(LinearGradient(
                        colors: scheme == .dark
                            ? [Color(white: 0.30), Color(white: 0.24)]
                            : [Color.white, Color(white: 0.945)],
                        startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 0, x: 0, y: 1))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(scheme == .dark ? 0.10 : 0.16), lineWidth: 0.5))
    }
}

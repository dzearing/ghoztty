import AppKit
import SwiftUI

// MARK: - Live preview

/// A small terminal drawn with the current font, theme, cursor, opacity,
/// padding and pane style — the effective config, so it follows every change
/// (and slider drags preview here before they're written).
struct SettingsPreview: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = currentTheme
        let family = model.values("font-family").first { !$0.isEmpty }
        let size = CGFloat(Double(model.value("font-size")) ?? 13)
        let opacity = Double(model.value("background-opacity")) ?? 1
        let padX = CGFloat(Double(model.value("window-padding-x").split(separator: ",").first ?? "2") ?? 2)
        let padY = CGFloat(Double(model.value("window-padding-y").split(separator: ",").first ?? "2") ?? 2)
        let elevated = model.value("macos-pane-style") == "elevated"
        let ligatures = !model.values("font-feature").contains("-calt")
        let font: Font = family.flatMap { NSFont(name: $0, size: size) != nil || FontLookup.exists($0) ? Font.custom($0, size: size * 0.9) : nil }
            ?? .system(size: size * 0.9, design: .monospaced)

        ZStack {
            if elevated {
                LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 0.84), Color(red: 0.25, green: 0.71, blue: 0.69)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                line(theme) { t in
                    Text("❯ ").foregroundColor(t.ansi(2)) + Text("git status ").foregroundColor(Color(nsColor: t.foreground))
                        + Text("-sb").foregroundColor(t.ansi(4))
                }
                line(theme) { t in Text("## users/dzearing/settings-ui").foregroundColor(t.ansi(2)) }
                line(theme) { t in
                    Text(" M ").foregroundColor(t.ansi(1)) + Text("SettingsView.swift  ").foregroundColor(Color(nsColor: t.foreground))
                        + Text(ligatures ? "=> != ->" : "=> != ->").foregroundColor(t.ansi(5))
                }
                HStack(spacing: 0) {
                    (Text("~/git/ghoztty ").foregroundColor(theme.ansi(3)) + Text("❯ ").foregroundColor(theme.ansi(2)))
                    PreviewCursor(model: model, theme: theme, size: size * 0.9)
                }
                Spacer(minLength: 0)
            }
            .font(font)
            .environment(\.font, font)
            .ligatures(ligatures)
            .padding(.horizontal, padX + 10)
            .padding(.vertical, padY + 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: theme.background).opacity(opacity))
            .clipShape(RoundedRectangle(cornerRadius: elevated ? 11 : 0))
            .shadow(color: .black.opacity(elevated ? 0.28 : 0), radius: 12, y: 6)
            .padding(elevated ? 22 : 0)
            .overlay(alignment: .bottomTrailing) {
                Text("\(family ?? "JetBrains Mono") \(NumberControlFormat.trim(Double(size)))pt · \(theme.name)\(opacity < 1 ? " · \(Int(opacity * 100))% opaque" : "")")
                    .font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(elevated ? 30 : 8)
            }
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the terminal with the current settings")
    }

    private func line(_ theme: ThemeInfo, @ViewBuilder _ content: (ThemeInfo) -> Text) -> some View {
        content(theme).lineLimit(1)
    }

    private var currentTheme: ThemeInfo {
        let selection = ThemeSelection(configValue: model.value("theme"))
        let name = selection.map { colorScheme == .dark ? $0.dark : $0.light }
        if let name, let theme = ThemeCatalog.shared.theme(named: name) { return theme }
        // No theme: the configured (or default) colors.
        let bg = NSColor(hex: model.value("background")) ?? NSColor(hex: "#282c34")!
        let fg = NSColor(hex: model.value("foreground")) ?? .white
        let palette = (0..<16).map { i in
            model.values("palette").first { $0.hasPrefix("\(i)=") }
                .flatMap { NSColor(hex: String($0.dropFirst("\(i)=".count))) } ?? fg
        }
        return ThemeInfo(name: name ?? "Default colors", background: bg, foreground: fg, cursor: NSColor(hex: model.value("cursor-color")),
                         palette: palette, isUserTheme: false)
    }
}

enum FontLookup {
    static func exists(_ family: String) -> Bool {
        NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
    }
}

private struct PreviewCursor: View {
    @ObservedObject var model: SettingsModel
    let theme: ThemeInfo
    let size: CGFloat
    @State private var visible = true

    var body: some View {
        let style = model.value("cursor-style")
        let blink = model.value("cursor-style-blink") != "false"
        let color = Color(nsColor: NSColor(hex: model.value("cursor-color")) ?? theme.cursor ?? theme.foreground)
        let opacity = Double(model.value("cursor-opacity")) ?? 1
        let width: CGFloat = style == "bar" ? 2 : size * 0.6
        let height: CGFloat = style == "underline" ? 2 : size * 1.15
        Group {
            if style == "block_hollow" {
                Rectangle().strokeBorder(color, lineWidth: 1.5)
            } else {
                Rectangle().fill(color)
            }
        }
        .frame(width: width, height: height)
        .frame(height: size * 1.15, alignment: .bottom)
        .opacity(opacity * (visible || !blink ? 1 : 0))
        .task(id: blink) {
            visible = true
            guard blink else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 530_000_000)
                visible.toggle()
            }
        }
    }
}

private extension View {
    @ViewBuilder func ligatures(_ on: Bool) -> some View {
        if on { self } else { self.kerning(0.01) }
    }
}

// MARK: - Theme

/// Pick a theme. "Light & dark themes" stores `light:A,dark:B`; the two tabs
/// each list ONLY themes of that kind, so a dark theme can't end up in the
/// light slot. "One theme" stores a single name; the tabs are then a filter.
struct ThemeSection: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: Tab?
    @State private var filter = ""
    @State private var showAll = false
    @State private var showingDoc = false
    @State private var hovering = false

    enum Tab: String { case light, dark }

    var body: some View {
        let selection = ThemeSelection(configValue: model.value("theme"))
        let follows = selection?.followsSystem ?? false
        let tab = self.tab ?? (colorScheme == .dark ? .dark : .light)
        let themes = ThemeCatalog.shared.themes.filter { $0.isLight == (tab == .light) }
        let filtered = filter.isEmpty ? themes : themes.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        let current = selection.map { follows ? (tab == .light ? $0.light : $0.dark) : $0.light }
        // Put the selected theme first among the collapsed few.
        let ordered = current.flatMap { name in filtered.first { $0.name == name } }.map { [$0] + filtered.filter { $0.name != current } } ?? filtered
        let shown = showAll || !filter.isEmpty ? ordered : Array(ordered.prefix(11))

        VStack(alignment: .leading, spacing: 10) {
            LabeledContent {
                Picker("", selection: Binding(
                    get: { follows },
                    set: { switchMode(toFollow: $0, selection: selection) })) {
                    Text("Light & dark themes").tag(true)
                    Text("One theme").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("Use")
                        SettingRowAccessories(model: model, key: "theme", hovering: hovering, showingDoc: $showingDoc)
                    }
                    Text(follows ? "Switches between a light and a dark theme with the system appearance."
                                 : "One theme, whatever the system appearance.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onHover { hovering = $0 }

            Picker("", selection: Binding(get: { tab }, set: { self.tab = $0; showAll = false })) {
                Label(follows ? (selection?.light ?? "") : "Light themes", systemImage: "sun.max").tag(Tab.light)
                    .help(follows ? "The theme used in light mode" : "Show light themes")
                Label(follows ? (selection?.dark ?? "") : "Dark themes", systemImage: "moon").tag(Tab.dark)
                    .help(follows ? "The theme used in dark mode" : "Show dark themes")
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 440, alignment: .leading)
            .accessibilityLabel(follows ? "Theme for light or dark mode" : "Light or dark themes")
            HStack(spacing: 10) {
                Text(follows ? "Showing \(tab.rawValue) themes — your pick is used in \(tab.rawValue) mode."
                             : "Filter only — the theme you pick is used all the time.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                TextField("", text: $filter, prompt: Text("Filter \(themes.count) \(tab.rawValue) themes"))
                    .settingsField()
                    .frame(width: 190)
            }

            if follows, let selection, let mismatch = mismatchedSlot(selection) {
                SettingNotice(symbol: "exclamationmark.triangle.fill",
                              text: "\(mismatch == .light ? selection.light : selection.dark) is a \(mismatch == .light ? "dark" : "light") theme but is set for \(mismatch.rawValue) mode. Pick a \(mismatch.rawValue) theme to fix it.")
            }
            if let problem = model.problems["theme"] {
                SettingNotice(symbol: "exclamationmark.triangle.fill", text: problem + " — not saved.", tint: .red)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 10)], spacing: 10) {
                ForEach(shown) { theme in
                    ThemeTile(theme: theme, selected: theme.name == current) {
                        pick(theme.name, tab: tab, selection: selection)
                    }
                }
                if !showAll && filter.isEmpty && ordered.count > shown.count {
                    Button { showAll = true } label: {
                        Text("All \(ordered.count) \(tab.rawValue) themes…")
                            .frame(maxWidth: .infinity, minHeight: 74)
                    }
                    .buttonStyle(.borderless)
                    .background(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                }
            }
            if filtered.isEmpty {
                Text("No \(tab.rawValue) themes match “\(filter)”.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func mismatchedSlot(_ selection: ThemeSelection) -> Tab? {
        if let light = ThemeCatalog.shared.theme(named: selection.light), !light.isLight { return .light }
        if let dark = ThemeCatalog.shared.theme(named: selection.dark), dark.isLight { return .dark }
        return nil
    }

    private func pick(_ name: String, tab: Tab, selection: ThemeSelection?) {
        guard var selection, selection.followsSystem else {
            model.set("theme", ThemeSelection(single: name).configValue)
            return
        }
        if tab == .light { selection.light = name } else { selection.dark = name }
        model.set("theme", selection.configValue)
    }

    /// Switching modes keeps the current theme in its own slot and seeds the
    /// other slot with a theme of that kind (preferring the same family:
    /// "Catppuccin Latte" ↔ "Catppuccin Mocha" share "Catppuccin").
    private func switchMode(toFollow: Bool, selection: ThemeSelection?) {
        let themes = ThemeCatalog.shared.themes
        if !toFollow {
            let keep = selection.map { colorScheme == .dark ? $0.dark : $0.light }
            if let keep { model.set("theme", ThemeSelection(single: keep).configValue) } else { model.reset("theme") }
            return
        }
        let currentName = selection?.light ?? (colorScheme == .dark ? "Ghostty Default Style Dark" : "")
        let current = themes.first { $0.name == currentName }
        let family = currentName.split(separator: " ").first.map(String.init) ?? ""
        func counterpart(light: Bool) -> String? {
            themes.first { $0.isLight == light && $0.name.hasPrefix(family + " ") }?.name
                ?? themes.first { $0.isLight == light }?.name
        }
        let light = current?.isLight == true ? currentName : counterpart(light: true)
        let dark = current?.isLight == false ? currentName : counterpart(light: false)
        guard let light, let dark else { return }
        model.set("theme", ThemeSelection(light: light, dark: dark).configValue)
    }
}

private struct ThemeTile: View {
    let theme: ThemeInfo
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    (Text("❯ ").foregroundColor(theme.ansi(2)) + Text("ls").foregroundColor(Color(nsColor: theme.foreground)))
                    (Text("src ").foregroundColor(theme.ansi(4)) + Text("docs ").foregroundColor(theme.ansi(5)) + Text("err").foregroundColor(theme.ansi(1)))
                    (Text("~/git ").foregroundColor(theme.ansi(3)) + Text("$").foregroundColor(Color(nsColor: theme.foreground)))
                }
                .font(.system(size: 9.5, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .topLeading)
                .padding(7)
                .background(Color(nsColor: theme.background))
                Text(theme.name)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12),
                                                                    lineWidth: selected ? 2.5 : 0.5))
        }
        .buttonStyle(.plain)
        .help(theme.name + (theme.isUserTheme ? " (your theme)" : ""))
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Pane style

struct PaneStyleSection: View {
    @ObservedObject var model: SettingsModel
    @State private var hovering = false
    @State private var showingDoc = false

    var body: some View {
        let style = model.value("macos-pane-style")
        LabeledContent {
            HStack(spacing: 14) {
                ForEach(["elevated", "flat"], id: \.self) { option in
                    Button { model.set("macos-pane-style", option) } label: {
                        VStack(spacing: 4) {
                            thumbnail(option)
                                .frame(width: 108, height: 66)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(style == option ? Color.accentColor : Color.primary.opacity(0.15),
                                                  lineWidth: style == option ? 2.5 : 0.5))
                            Text(option.capitalized)
                                .font(.caption)
                                .fontWeight(style == option ? .semibold : .regular)
                                .foregroundStyle(style == option ? Color.accentColor : .primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(option.capitalized) pane style")
                    .accessibilityAddTraits(style == option ? .isSelected : [])
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("Pane style")
                    SettingRowAccessories(model: model, key: "macos-pane-style", hovering: hovering, showingDoc: $showingDoc)
                }
                Text("Elevated: raised cards on a gradient. Flat: classic edge-to-edge panes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private func thumbnail(_ option: String) -> some View {
        if option == "elevated" {
            ZStack {
                LinearGradient(colors: [Color(red: 0.36, green: 0.55, blue: 0.84), Color(red: 0.25, green: 0.71, blue: 0.69)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.13).opacity(0.85))
                    RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.13).opacity(0.75))
                }
                .padding(6)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
            }
        } else {
            ZStack {
                Color(red: 0.16, green: 0.17, blue: 0.2)
                Rectangle().fill(Color(white: 0.35)).frame(width: 1)
            }
        }
    }
}

// MARK: - Config file

struct ConfigFileSection: View {
    @ObservedObject var model: SettingsModel
    var openInEditor: () -> Void
    @State private var confirmingRestore: URL?

    var body: some View {
        let target = model.store.targetURL
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent {
                HStack {
                    Button("Open in Editor", action: openInEditor)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([target]) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(target.lastPathComponent)
                        Text("loaded").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule()).foregroundStyle(Color.accentColor)
                    }
                    Text(model.store.url.path.replacingOccurrences(of: home, with: "~"))
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if model.store.url.resolvingSymlinksInPath() != model.store.url {
                        Text("A link to \(target.path.replacingOccurrences(of: home, with: "~")) — Settings writes through it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.fileError {
                SettingNotice(symbol: "exclamationmark.triangle.fill", text: error, tint: .red)
            }

            ForEach(model.sources.filter { $0.url.standardizedFileURL != target.standardizedFileURL && $0.url.standardizedFileURL != model.store.url.standardizedFileURL }, id: \.url) { source in
                LabeledContent {
                    Button("Open") { NSWorkspace.shared.open(source.url) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(source.url.lastPathComponent)
                            Text(source.included ? "included" : "also loaded").font(.caption2)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        Text(source.included
                             ? "Loaded after your config through config-file, so the keys it sets win. Settings shows those keys read-only."
                             : "Loaded before your config; your settings override it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            LabeledContent {
                Menu("Restore…") {
                    let backups = model.store.backups()
                    if backups.isEmpty { Text("No backups yet") }
                    ForEach(backups, id: \.self) { url in
                        Button(Self.backupLabel(url)) { confirmingRestore = url }
                    }
                    if !backups.isEmpty {
                        Divider()
                        Button("Show Backups in Finder") { NSWorkspace.shared.open(model.store.backupDirectory) }
                    }
                }
                .fixedSize()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Backups")
                    Text(model.store.backupURL != nil
                         ? "Saved a copy before this session’s first change."
                         : "A copy is saved before the first change in each session (the newest 10 are kept).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .confirmationDialog("Restore this backup?", isPresented: Binding(
                get: { confirmingRestore != nil }, set: { if !$0 { confirmingRestore = nil } })) {
                Button("Restore") { if let url = confirmingRestore { model.restoreBackup(url) } }
            } message: {
                Text("Your config file will be replaced with the copy from \(confirmingRestore.map(Self.backupLabel) ?? ""). The current file is backed up first.")
            }

            DisclosureGroup("Current file") {
                ScrollView([.vertical, .horizontal]) {
                    Text(model.file.string.isEmpty ? "(empty)" : model.file.string)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 220)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    static func backupLabel(_ url: URL) -> String {
        // config.ghostty.20261031-131409 → Oct 31, 2026 at 1:14 PM
        let stamp = url.lastPathComponent.split(separator: ".").last.map(String.init) ?? ""
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyyMMdd-HHmmss"
        guard let date = parser.date(from: String(stamp.prefix(15))) else { return url.lastPathComponent }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - All settings

/// Every key in the schema. Plain keys get a text field (validated by
/// Ghostty before writing), repeatable keys their list of values; curated
/// keys link to their page.
struct AllSettingsSection: View {
    @ObservedObject var model: SettingsModel
    var query: String
    var reveal: (SettingsPageID, String) -> Void
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable { case all = "All", changed = "Changed", uncovered = "Not on other pages" }

    var body: some View {
        let keys = model.catalog.entries.map(\.key).filter { key in
            switch filter {
            case .all: return true
            case .changed: return model.isModified(key)
            case .uncovered: return !SettingsPages.curatedKeys.contains(key)
            }
        }.filter { query.isEmpty || AllSettingsSection.matches(model, $0, query) }

        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { f in
                    Text(f == .all ? "All \(model.catalog.entries.count)" : f.rawValue).tag(f)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            ForEach(keys, id: \.self) { key in
                RawSettingRow(model: model, key: key, query: query, reveal: reveal)
                Divider()
            }
            if keys.isEmpty {
                Text("No settings match.").foregroundStyle(.secondary)
            }
        }
    }

    static func matches(_ model: SettingsModel, _ key: String, _ query: String) -> Bool {
        key.localizedCaseInsensitiveContains(query)
            || (model.doc(key)?.doc ?? "").localizedCaseInsensitiveContains(query)
            || model.values(key).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

struct RawSettingRow: View {
    @ObservedObject var model: SettingsModel
    let key: String
    var query: String = ""
    var reveal: (SettingsPageID, String) -> Void
    @State private var hovering = false
    @State private var showingDoc = false

    var body: some View {
        let entry = model.doc(key)
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 8) {
                    if entry?.repeatable == true {
                        ScrollView(.horizontal, showsIndicators: false) {
                            ListControl(model: model, key: key, placeholder: "add a value")
                        }
                        .frame(maxWidth: 360)
                    } else {
                        CommitTextField(model: model, key: key, placeholder: model.defaultValue(key).isEmpty ? "unset" : model.defaultValue(key), width: 220)
                            .font(.system(.body, design: .monospaced))
                            .disabled(model.overridingSource(key) != nil)
                    }
                    if let page = SettingsPages.pageID(for: key), page != .advanced {
                        Button("\(SettingsPages.page(page).title) ›") { reveal(page, key) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    highlightedText(key, query).font(.system(.callout, design: .monospaced))
                    SettingRowAccessories(model: model, key: key, hovering: hovering, showingDoc: $showingDoc)
                }
            }
            if entry?.repeatable == true, !model.values(key).isEmpty {
                Text("In effect: " + model.values(key).prefix(4).joined(separator: "  ·  ") + (model.values(key).count > 4 ? "  ·  … (\(model.values(key).count))" : ""))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let override = model.overridingSource(key) {
                SettingNotice(symbol: "arrow.turn.down.right",
                              text: "Set in \(override.url.lastPathComponent), which loads after your config.",
                              action: ("Open", { NSWorkspace.shared.open(override.url) }))
            }
            if let problem = model.problems[key] {
                SettingNotice(symbol: "exclamationmark.triangle.fill", text: problem + " — not saved.", tint: .red)
            }
        }
        .onHover { hovering = $0 }
        .id(key)
    }
}

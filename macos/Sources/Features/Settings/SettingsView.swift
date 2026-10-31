import AppKit
import SwiftUI

/// The Settings window (⌘, / Preferences… / `open_config`): a System
/// Settings–style sidebar of pages with search, over grouped forms. Every
/// control writes the user's config file surgically through `SettingsModel`
/// and the change applies live through the normal config reload.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    var openInEditor: () -> Void

    @State private var selection: SettingsPageID?
    @State private var query = ""
    @State private var highlighted: String?
    @State private var pendingScroll: String?

    init(model: SettingsModel, openInEditor: @escaping () -> Void, initialPage: SettingsPageID = .appearance) {
        self.model = model
        self.openInEditor = openInEditor
        _selection = State(initialValue: initialPage)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsPages.all) { page in
                    NavigationLink(value: page.id) {
                        HStack(spacing: 8) {
                            Image(systemName: page.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(page.tint.gradient, in: RoundedRectangle(cornerRadius: 5))
                            Text(page.title)
                            Spacer(minLength: 4)
                            let count = changedCount(page)
                            if count > 0 {
                                Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    .help("\(count) setting\(count == 1 ? "" : "s") changed from the default")
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search")
            .navigationSplitViewColumnWidth(min: 200, ideal: 215, max: 260)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            ScrollViewReader { proxy in
                Form {
                    if query.isEmpty {
                        pageContent(SettingsPages.page(selection ?? .appearance))
                    } else {
                        searchResults
                    }
                }
                .formStyle(.grouped)
                .onChange(of: pendingScroll) { key in
                    guard let key else { return }
                    DispatchQueue.main.async {
                        withAnimation { proxy.scrollTo(key, anchor: .center) }
                        pendingScroll = nil
                    }
                }
            }
            .navigationTitle(query.isEmpty ? SettingsPages.page(selection ?? .appearance).title : "Search")
            .overlay(alignment: .bottom) { SettingsToast(model: model) }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: selection) { _ in if !query.isEmpty { query = "" } }
    }

    // MARK: Pages

    @ViewBuilder private func pageContent(_ page: SettingsPage) -> some View {
        ForEach(page.sections) { section in
            Section {
                sectionBody(section)
            } header: {
                if let title = section.title { Text(title) }
            } footer: {
                if let footer = section.footer { Text(footer).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private func sectionBody(_ section: SettingsSection, rows filter: ((SettingRow) -> Bool)? = nil) -> some View {
        switch section.content {
        case .rows(let rows):
            ForEach(rows.filter { filter?($0) ?? true }) { row in
                SettingsRowView(model: model, row: row, highlighted: highlighted == row.key, query: query)
            }
        case .custom(let custom):
            customView(custom)
        }
    }

    @ViewBuilder private func customView(_ custom: SettingsCustomSection) -> some View {
        switch custom {
        case .preview: SettingsPreview(model: model).listRowInsets(EdgeInsets())
        case .theme: ThemeSection(model: model).id("theme")
        case .paneStyle: PaneStyleSection(model: model).id("macos-pane-style")
        case .shortcutGuide: ShortcutGuideCard()
        case .agentStatus: AgentStatusSection()
        case .remoteMachines: RemoteMachinesSection()
        case .version: VersionSection()
        case .configFile: ConfigFileSection(model: model, openInEditor: openInEditor)
        case .allSettings: AllSettingsSection(model: model, query: query, reveal: reveal)
        }
    }

    // MARK: Search

    /// Matches a row's label, key, documentation, current value, or option
    /// labels; custom sections match their own words. Keys no page shows are
    /// listed from the schema at the end.
    @ViewBuilder private var searchResults: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let hits = SettingsPages.all.compactMap { page -> (SettingsPage, [SettingsSection])? in
            let sections = page.sections.compactMap { section -> SettingsSection? in
                switch section.content {
                case .rows(let rows):
                    let matching = rows.filter { rowMatches($0, q) }
                    return matching.isEmpty ? nil : SettingsSection(section.title, footer: nil, matching)
                case .custom(let custom):
                    guard custom != .allSettings, custom != .preview else { return nil }
                    let words = custom.searchText + " " + (section.title ?? "")
                    let docMatch = custom.keys.contains { (model.doc($0)?.doc ?? "").localizedCaseInsensitiveContains(q) }
                    return words.localizedCaseInsensitiveContains(q) || docMatch ? section : nil
                }
            }
            return sections.isEmpty ? nil : (page, sections)
        }
        let uncurated = model.catalog.entries.map(\.key)
            .filter { !SettingsPages.curatedKeys.contains($0) && AllSettingsSection.matches(model, $0, q) }

        if hits.isEmpty && uncurated.isEmpty {
            Section { Text("No settings match “\(q)”.").foregroundStyle(.secondary) }
        }
        ForEach(hits, id: \.0.id) { page, sections in
            ForEach(sections) { section in
                Section {
                    sectionBody(section)
                } header: {
                    Label(page.title + (section.title.map { " › \($0)" } ?? ""), systemImage: page.symbol)
                }
            }
        }
        if !uncurated.isEmpty {
            Section {
                ForEach(uncurated.prefix(40), id: \.self) { key in
                    RawSettingRow(model: model, key: key, query: q, reveal: reveal)
                }
                if uncurated.count > 40 {
                    Text("\(uncurated.count - 40) more — keep typing to narrow.").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Label("Advanced › All settings (\(uncurated.count))", systemImage: "ellipsis.circle")
            }
        }
    }

    private func rowMatches(_ row: SettingRow, _ q: String) -> Bool {
        let options: String = {
            switch row.control {
            case .picker(let o), .segmented(let o): return o.map { "\($0.0) \($0.1)" }.joined(separator: " ")
            default: return ""
            }
        }()
        let haystack = [row.label, row.key, row.hint ?? "", model.doc(row.key)?.doc ?? "",
                        model.values(row.key).joined(separator: " "), options].joined(separator: "\n")
        return haystack.localizedCaseInsensitiveContains(q)
    }

    /// Jump to a key on its page, flash it, and scroll it into view.
    private func reveal(_ page: SettingsPageID, _ key: String) {
        query = ""
        selection = page
        highlighted = key
        pendingScroll = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if highlighted == key { withAnimation { highlighted = nil } }
        }
    }

    private func changedCount(_ page: SettingsPage) -> Int {
        if page.id == .advanced {
            return model.file.entries.map(\.key).filter { !SettingsPages.curatedKeys.contains($0) }.uniqueCount
        }
        return Set(page.sections.flatMap(\.keys)).filter { model.isSetInFile($0) }.count
    }

    private var sidebarFooter: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return VStack(alignment: .leading, spacing: 3) {
            Divider().padding(.bottom, 4)
            Text("Settings are saved to").font(.caption).foregroundStyle(.secondary)
            Text(model.store.url.path.replacingOccurrences(of: home, with: "~"))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(model.store.url.path)
            Button("Open Config File…", action: openInEditor)
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }
}

private extension Array where Element: Hashable {
    var uniqueCount: Int { Set(self).count }
}

// MARK: - Toast

/// "Saved font-size · applied live · Show change · Undo" after each write.
struct SettingsToast: View {
    @ObservedObject var model: SettingsModel
    @State private var expanded = false

    var body: some View {
        if let change = model.lastChange {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(change.message).fontWeight(.medium)
                    Text(change.backedUpTo != nil ? "applied live · backed up first" : "applied live")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(expanded ? "Hide Change" : "Show Change") { expanded.toggle() }.buttonStyle(.link)
                    Button("Undo") { model.undoLastChange() }.buttonStyle(.link)
                    Button { model.dismissLastChange() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Dismiss")
                }
                if expanded {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(change.removed.enumerated()), id: \.offset) { Text("− " + $0.element).foregroundStyle(.red) }
                        ForEach(Array(change.added.enumerated()), id: \.offset) { Text("+ " + $0.element).foregroundStyle(.green) }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .padding(14)
            .frame(maxWidth: 620)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: change.id) {
                expanded = false
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !expanded, model.lastChange?.id == change.id { withAnimation { model.dismissLastChange() } }
            }
        }
    }
}

// MARK: - Window

/// The one Settings window. Its model (and so the once-per-session backup)
/// lives for the app session; reopening the window re-reads the file.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?
    let model: SettingsModel

    private init(model: SettingsModel, openInEditor: @escaping () -> Void) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("com.dzearing.ghoztty.settings")
        window.contentView = NSHostingView(rootView: SettingsView(model: model, openInEditor: openInEditor))
        window.center()
        window.setFrameAutosaveName("GhozttySettingsWindow")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Show (creating on first use) the Settings window.
    static func show(ghostty: Ghostty.App) {
        if let shared {
            shared.model.refresh()
            shared.showWindow(nil)
            shared.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let catalog = ConfigSchema.defaults() else {
            Ghostty.logger.error("settings: could not read the config schema; opening the config file instead")
            ghostty.openConfigFile()
            return
        }
        let path = ConfigSchema.preferredPath()
            ?? SettingsModel.defaultFileURLs().last!.path
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.dzearing.ghoztty", isDirectory: true)
        let store = ConfigFileStore(
            url: URL(fileURLWithPath: path),
            backupDirectory: support.appendingPathComponent("config-backups", isDirectory: true))
        let model = SettingsModel(
            catalog: catalog,
            store: store,
            reload: { [weak ghostty] in ghostty?.reloadConfig() },
            liveConfig: { [weak ghostty] in ghostty?.config.config })
        let controller = SettingsWindowController(model: model, openInEditor: { [weak ghostty] in ghostty?.openConfigFile() })
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

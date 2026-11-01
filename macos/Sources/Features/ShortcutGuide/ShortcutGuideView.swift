import SwiftUI

/// State for the shortcut guide window.
@MainActor
final class ShortcutGuideModel: ObservableObject {
    @Published var catalog: KeybindCatalog
    @Published var query: String = "" {
        didSet {
            // Searching always searches everything.
            if !query.isEmpty, oldValue.isEmpty { category = nil }
            selection = query.isEmpty ? nil : visibleRows.first?.id
        }
    }
    @Published var category: ShortcutCategory? { didSet { selection = nil } }
    @Published var includeUnbound: Bool = false {
        didSet { UserDefaults.standard.set(includeUnbound, forKey: Self.unboundDefaultsKey) }
    }
    @Published var selection: String?
    /// Bumped to ask the view to focus the search field.
    @Published var focusSearchToken = 0

    /// Runs a row's action in the most recent terminal window.
    var onRun: ((ShortcutRow) -> Void)?

    private static let unboundDefaultsKey = "ShortcutGuideIncludeUnbound"

    init(catalog: KeybindCatalog) {
        self.catalog = catalog
        self.includeUnbound = UserDefaults.standard.bool(forKey: Self.unboundDefaultsKey)
    }

    var visibleRows: [ShortcutRow] {
        ShortcutListView.visibleRows(catalog: catalog, query: query, category: category,
                                     includeUnbound: includeUnbound, editing: false)
    }

    /// Row counts per category for the sidebar, honoring the search and the
    /// unbound toggle.
    func count(for category: ShortcutCategory?) -> Int {
        ShortcutListView.visibleRows(catalog: catalog, query: query, category: nil,
                                     includeUnbound: includeUnbound, editing: false)
            .filter { category == nil || $0.category == category }.count
    }

    func moveSelection(by delta: Int) {
        let rows = visibleRows
        guard !rows.isEmpty else { return }
        let current = selection.flatMap { id in rows.firstIndex { $0.id == id } }
        let next: Int
        if let current { next = max(0, min(rows.count - 1, current + delta)) } else { next = delta > 0 ? 0 : rows.count - 1 }
        selection = rows[next].id
    }

    /// Runs the selected row, if it is runnable. Returns whether it ran.
    @discardableResult
    func runSelection() -> Bool {
        guard let id = selection, let row = visibleRows.first(where: { $0.id == id }), row.isRunnable else { return false }
        onRun?(row)
        return true
    }
}

/// The keyboard shortcut guide: categories on the left, a searchable list on
/// the right, counts and actions along the bottom.
struct ShortcutGuideView: View {
    @ObservedObject var model: ShortcutGuideModel
    var onOpenConfig: () -> Void = {}
    var onPrint: () -> Void = {}

    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
                .background(.regularMaterial)
            Divider()
            VStack(spacing: 0) {
                searchBar
                Divider()
                ShortcutListView(
                    catalog: model.catalog, query: model.query, category: model.category,
                    includeUnbound: model.includeUnbound, editor: nil,
                    selection: $model.selection, onRun: model.onRun)
                Divider()
                footer
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { searchFocused = true }
        .onChange(of: model.focusSearchToken) { _ in searchFocused = true }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 1) {
            categoryRow(nil, title: "All Shortcuts", symbol: "command")
            Text("Categories")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3)
            ForEach(ShortcutCategory.allCases) { cat in
                if cat != .other || model.count(for: .other) > 0 {
                    categoryRow(cat, title: cat.title, symbol: cat.symbol)
                }
            }
            Spacer()
            Toggle("Show unbound actions", isOn: $model.includeUnbound)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
    }

    private func categoryRow(_ category: ShortcutCategory?, title: String, symbol: String) -> some View {
        let count = model.count(for: category)
        let selected = model.category == category
        return Button {
            model.category = category
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(Color.accentColor)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.primary.opacity(0.08) : .clear))
            .opacity(count == 0 && category != nil ? 0.45 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(title), \(count) shortcuts")
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search actions or keys (e.g. ⌘D, split)", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($searchFocused)
                .accessibilityLabel("Search shortcuts")
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(searchFocused ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: searchFocused ? 1.5 : 0.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Footer

    private var footer: some View {
        let bound = model.catalog.rows().filter { $0.kind != .builtIn && $0.isBound }.count
        let customized = model.catalog.allRows.filter(\.isCustomized).count
        return HStack(spacing: 12) {
            Text("\(bound) shortcuts" + (customized > 0 ? " · \(customized) customized" : ""))
                .foregroundStyle(.secondary)
            Text("↑↓ select · ↩ run · esc close").foregroundStyle(.tertiary)
            Spacer()
            Button("Open Config File", action: onOpenConfig)
                .buttonStyle(.link)
            Button("Print Cheat Sheet…", action: onPrint)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

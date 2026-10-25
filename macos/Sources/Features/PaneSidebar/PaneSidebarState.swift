import AppKit
import SwiftUI

/// Per-window state for the pane sidebar (`docs/design/pane-sidebar.md`).
///
/// Two kinds of state live here, and the difference matters:
///
/// - **Layout** — `isExpanded` and `isHidden`. They size the sidebar's
///   column, which is part of the window's layout, so they persist (per
///   window, in the session-layout manifest) and are what new windows start
///   from. So does `order`, the sidebar's own order of the panes.
/// - **Transient** — `isQuickKill`, `showsAllWindows`, and the all-windows
///   folds. Never persisted: a window must never come back in kill mode.
///
/// The stash itself is NOT here — it is part of the tree (`SplitTree.stashed`),
/// which is what keeps a stashed pane in the window for everything else.
@MainActor
final class PaneSidebarState: ObservableObject {
    /// The full list (true) or the icon-only rail (false). One button at the
    /// top of the bar switches it; nothing else does — there is no hover-open,
    /// since the rail is where its icons are dragged.
    @Published var isExpanded: Bool {
        didSet { if isExpanded != oldValue { Self.rememberForNewWindows(self) } }
    }

    /// Hidden outright (Ctrl+Cmd+S). Not a drop target while hidden.
    @Published var isHidden: Bool {
        didSet { if isHidden != oldValue { Self.rememberForNewWindows(self) } }
    }

    /// Trash mode: every row grows a red × that kills with no confirmation.
    @Published var isQuickKill: Bool = false

    /// List panes from every window, grouped by window. Off by default.
    @Published var showsAllWindows: Bool = false {
        didSet {
            // A filter belongs to one look at every window, not to the next
            // one — and so do the folds: each look starts from the default.
            if !showsAllWindows {
                filter = ""
                toggledWindows = []
            }
        }
    }

    /// The all-windows search (`PaneSidebarFilter`). Empty = no filter.
    @Published var filter: String = ""

    /// The sidebar's own order of this window's panes, by pane id — what a
    /// drag within the list changes. It orders the LIST only: the grid is
    /// never touched. Empty until the first reorder, which means "the tree's
    /// order". Read through `PaneSidebarOrder.arranged`, which also places
    /// panes it has never seen; a stashed pane keeps its place in it, so it
    /// comes back to the same spot.
    @Published var order: [UUID] = []

    /// Window groups whose fold the user flipped away from its default in the
    /// all-windows list (`isWindowFolded`). Holding the flips rather than the
    /// folds is what lets a window opened while the list is showing arrive
    /// at the default — folded — with nothing to add.
    @Published var toggledWindows: Set<ObjectIdentifier> = []
    /// Folded project groups in the all-windows scope, by project name.
    @Published var foldedProjects: Set<String> = []

    /// How far the sidebar's drawn chrome reaches up past the grid, beside
    /// the window's tab bar (`TransparentTitlebarTerminalWindow` sets it to the
    /// tab row's height while the tab bar is moved right of the sidebar; 0
    /// otherwise). Drawing only: the titlebar owns every click in that strip,
    /// so the rows themselves stay below it. Never persisted.
    @Published var tabRowHeight: CGFloat = 0

    /// The flat panel's width. One preference shared by every window, like
    /// the viewer side panel's.
    @Published var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: Self.widthKey) }
    }

    init(isExpanded: Bool? = nil, isHidden: Bool? = nil) {
        let defaults = UserDefaults.standard
        self.isExpanded = isExpanded ?? Self.storedExpanded(defaults)
        self.isHidden = isHidden ?? (defaults.object(forKey: Self.hiddenKey) as? Bool ?? false)
        let stored = defaults.double(forKey: Self.widthKey)
        self.width = stored > 0 ? Self.clampWidth(CGFloat(stored)) : Self.defaultWidth
    }

    // MARK: Layout rules (pure; see PaneSidebarStateTests)

    enum Mode: Equatable {
        case hidden
        /// The flat panel: every pane as a full row.
        case expanded
        /// Collapsed (or a narrow window): the raised icon-only rail.
        case collapsed
    }

    /// Below this window width the full panel would crowd the grid; the
    /// rail doesn't. The same breakpoint the viewer side panel uses.
    nonisolated static let narrowWindowWidth: CGFloat = 720

    nonisolated static let defaultWidth: CGFloat = 240
    nonisolated static let minimumWidth: CGFloat = 180
    nonisolated static let maximumWidth: CGFloat = 380

    /// The rail's card.
    nonisolated static let railCardWidth: CGFloat = 44

    /// The space around the raised rail card.
    struct RailInsets: Equatable {
        let leading: CGFloat
        let vertical: CGFloat
        let trailing: CGFloat
    }

    /// Flat: the glass card's uniform outer margin on every side. Elevated:
    /// the SAME margin the panes keep from the window's edge, and none on the
    /// trailing side — the grid's own margin is already the gap there, and
    /// adding the card's on top of it left the rail sitting further from the
    /// panes than from the window edge, with its ends out of line with theirs.
    nonisolated static func railInsets(elevated: Bool) -> RailInsets {
        elevated
            ? .init(leading: PaneElevation.margin, vertical: PaneElevation.margin, trailing: 0)
            : .init(leading: GlassCard.outerMargin, vertical: GlassCard.outerMargin,
                    trailing: GlassCard.outerMargin)
    }

    /// Where the expanded panel's resize grip lies, from the panel's edge.
    /// Elevated: all of the gutter between the panel and the panes (the
    /// grid's margin), as every resizer lives in a gutter — it used to
    /// straddle the edge, half of it a click on the list. Flat: the grid
    /// starts right at the edge, so just inside it.
    static func pinnedEdgeGrip(elevated: Bool) -> (offset: CGFloat, width: CGFloat) {
        elevated
            ? (0, PaneElevation.margin)
            : (-SidePanelResizeHandle.grabWidth, SidePanelResizeHandle.grabWidth)
    }

    /// How far the expanded panel's host reaches past its edge: as far as the
    /// grip does.
    static func pinnedEdgeReach(elevated: Bool) -> CGFloat {
        let grip = pinnedEdgeGrip(elevated: elevated)
        return Swift.max(0, grip.offset + grip.width)
    }

    /// The rail's column: its insets and the card.
    nonisolated static func railColumnWidth(elevated: Bool) -> CGFloat {
        let insets = railInsets(elevated: elevated)
        return insets.leading + railCardWidth + insets.trailing
    }

    /// A rail's edge pulled out past this expands it. (An expanded panel
    /// dragged narrow just stops at `minimumWidth` — it never collapses
    /// itself.)
    nonisolated static let expandThreshold: CGFloat = 120

    nonisolated static func mode(isExpanded: Bool, isHidden: Bool, windowWidth: CGFloat) -> Mode {
        if isHidden { return .hidden }
        if isExpanded && windowWidth >= narrowWindowWidth { return .expanded }
        return .collapsed
    }

    /// Whether the collapse/expand button can expand: not in a window too
    /// narrow for the panel, where the rail is forced.
    nonisolated static func canExpand(windowWidth: CGFloat) -> Bool {
        windowWidth >= narrowWindowWidth
    }

    /// Whether a window's panes are folded away in the all-windows list.
    ///
    /// Every window starts folded — one row per window, the overview that
    /// scope is for — except THIS window, which starts open: it holds the
    /// selection, the pane you are in, and is the one window whose panes the
    /// list is otherwise showing you anyway. Only at the start: focus moving
    /// later never unfolds anything, or the list would jump under the
    /// pointer. A search unfolds everything, since a hit hidden inside a fold
    /// reads as no hit.
    nonisolated static func isWindowFolded(isThisWindow: Bool, isToggled: Bool, isSearching: Bool) -> Bool {
        if isSearching { return false }
        return isThisWindow == isToggled
    }

    func mode(windowWidth: CGFloat) -> Mode {
        Self.mode(isExpanded: isExpanded, isHidden: isHidden, windowWidth: windowWidth)
    }

    /// The width of the sidebar's COLUMN — what the grid is laid out beside.
    /// Only collapse/expand and hide/show change it, so a terminal is resized
    /// only by something somebody chose.
    nonisolated static func columnWidth(for mode: Mode, panelWidth: CGFloat, elevated: Bool) -> CGFloat {
        switch mode {
        case .hidden: 0
        case .expanded: panelWidth
        case .collapsed: railColumnWidth(elevated: elevated)
        }
    }

    nonisolated static func clampWidth(_ width: CGFloat) -> CGFloat {
        Swift.min(maximumWidth, Swift.max(minimumWidth, width))
    }

    // MARK: Defaults for new windows

    private static let expandedKey = "PaneSidebarExpanded"
    /// Before collapse/expand there was a pin: pinned was the flat full panel,
    /// which is what expanded is, so a stored pin is read as that.
    private static let legacyPinnedKey = "PaneSidebarPinned"
    private static let hiddenKey = "PaneSidebarHidden"
    private static let widthKey = "PaneSidebarWidth"

    nonisolated static func storedExpanded(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: expandedKey) as? Bool
            ?? defaults.object(forKey: legacyPinnedKey) as? Bool
            ?? false
    }

    /// New windows start from the most recently chosen layout, the way a
    /// Finder window's sidebar does.
    private static func rememberForNewWindows(_ state: PaneSidebarState) {
        UserDefaults.standard.set(state.isExpanded, forKey: expandedKey)
        UserDefaults.standard.set(state.isHidden, forKey: hiddenKey)
    }
}

// MARK: - Row text (pure)

/// The text a sidebar row or rail tile shows for a pane. Pure, so the rules
/// are unit-tested (`PaneSidebarTextTests`).
enum PaneSidebarText {
    /// A rail tile's label: ONE character of what the pane is called
    /// (`label` — its banner title, else its title, exactly as a stacked
    /// pane's strip is named), so a tile and the row it collapsed from name
    /// the pane the same way. The first letter or digit, upper-cased: a title
    /// that opens with a glyph — Claude Code's `✳ ` / spinner prefix, a path's
    /// `~/` — would otherwise give every such pane the same tile. A label with
    /// no letters at all shows its first visible character.
    static func monogram(for label: String) -> String {
        if let letter = label.first(where: { $0.isLetter || $0.isNumber }) {
            return String(letter).uppercased()
        }
        return label.first(where: { !$0.isWhitespace }).map(String.init) ?? "•"
    }

    /// The name a row shows. A terminal that never set a title carries
    /// Ghostty's placeholder (the ghost), which names nothing and gives a rail
    /// tile no letters to work with — so it falls back to the working
    /// directory's name, then to the pane kind.
    static func title(_ raw: String, pwd: String?, kind: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty && trimmed != placeholderTitle { return trimmed }
        if let pwd, !pwd.isEmpty {
            let name = (pwd as NSString).lastPathComponent
            if !name.isEmpty && name != "/" { return name }
        }
        return kind
    }

    /// The title a surface has before anything sets one.
    static let placeholderTitle = "👻"

    /// What a pane is called wherever it is named in one line — a sidebar
    /// row, a rail tile, a stacked pane's strip: its banner's title when the
    /// banner has one, else `title`. The banner title wins because it is the
    /// one somebody chose: an agent's banner hook sets it to the task, while
    /// the agent itself retitles the pane (OSC 0/2) with whatever it is doing.
    static func label(title raw: String, pwd: String?, kind: String, banner: String?) -> String {
        bannerTitle(banner) ?? title(raw, pwd: pwd, kind: kind)
    }

    /// The title a pane banner gives itself, as plain text, or nil when it
    /// has none. Only a line that IS a title counts, never just the first
    /// line of whatever the banner says:
    /// - a heading on the banner's first line (`## Fix strip labels`) — what
    ///   the banner hook writes above its table;
    /// - a one-line banner that opens with a bold run standing on its own
    ///   (`**Fix strip labels**`, or followed by ` · …`) — the hook's OSC
    ///   fallback. A bold label (`**Goal:** …`) is not a title, and neither
    ///   is a bold run followed by more prose (`**PR #12** — 3 files`).
    static func bannerTitle(_ banner: String?) -> String? {
        let lines = bannerLines(banner)
        guard let first = lines.first else { return nil }
        if let heading = headingText(first) {
            let plain = stripInlineMarkdown(heading)
            return plain.isEmpty ? nil : plain
        }
        guard lines.count == 1, first.hasPrefix("**") else { return nil }
        let rest = first.dropFirst(2)
        guard let close = rest.range(of: "**") else { return nil }
        let after = rest[close.upperBound...].trimmingCharacters(in: .whitespaces)
        guard after.isEmpty || after.hasPrefix("·") else { return nil }
        let plain = stripInlineMarkdown(String(rest[..<close.lowerBound]))
        return plain.isEmpty || plain.hasSuffix(":") ? nil : plain
    }

    /// A banner's non-empty lines, trimmed; a literal `\n` is a line break,
    /// as it is when the banner renders.
    private static func bannerLines(_ banner: String?) -> [String] {
        guard let banner else { return [] }
        return banner
            .replacingOccurrences(of: "\\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// An ATX heading's text (`## Title` → `Title`): 1–6 `#` and a space, as
    /// the banner renders one.
    private static func headingText(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }
        guard (1...6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// The first line of a pane banner as plain text: the markdown subset the
    /// banner renders (`**bold**`, `*italic*`, `_italic_`, `__underline__`,
    /// `` `code` ``, `[text](url)`, `\` escapes) stripped to its words. Table
    /// and rule lines are skipped — they are layout, not a summary.
    static func bannerLine(_ banner: String?) -> String? {
        guard let line = bannerLines(banner).first(where: { line in
            !line.hasPrefix("|") && !isThematicBreak(line)
        }) else { return nil }
        let plain = stripInlineMarkdown(headingText(line) ?? line)
        return plain.isEmpty ? nil : plain
    }

    /// The row's subtitle: the banner's first line when there is one and it
    /// is not the banner's title — a titled banner already names the row
    /// (`label`) — else the working directory or the viewer's location.
    static func subtitle(banner: String?, pwd: String?, viewerLocation: String?) -> String? {
        if bannerTitle(banner) == nil, let line = bannerLine(banner) { return line }
        if let pwd, !pwd.isEmpty { return pwd.abbreviatedPath }
        if let viewerLocation, !viewerLocation.isEmpty { return viewerLocation.abbreviatedPath }
        return nil
    }

    /// `subtitle`, unless it only repeats `title` — then nil.
    static func distinct(_ subtitle: String?, from title: String) -> String? {
        guard let subtitle else { return nil }
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        return trim(subtitle) == trim(title) ? nil : subtitle
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func stripInlineMarkdown(_ line: String) -> String {
        var text = line
        // Leading list / checkbox markers.
        for marker in ["- [x] ", "- [X] ", "- [ ] ", "[x] ", "[X] ", "[ ] ", "- ", "* "] where text.hasPrefix(marker) {
            text.removeFirst(marker.count)
            break
        }
        // [text](url) → text
        if let regex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#) {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        // Escapes first, so an escaped delimiter survives as a literal.
        var out = ""
        var escaped = false
        for ch in text {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "*" || ch == "`" { continue }
            out.append(ch)
        }
        // `_x_` / `__x__` emphasis: drop underscores at word edges only, so
        // snake_case names survive.
        if let regex = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9])_+|_+(?![A-Za-z0-9])"#) {
            out = regex.stringByReplacingMatches(
                in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "")
        }
        return out.trimmingCharacters(in: .whitespaces)
    }
}

/// The all-windows scope's order and grouping — pure, so pinned in tests.
///
/// Windows are sorted by name (stable as focus moves, unlike frontmost-first,
/// which reshuffled the list on every window switch). A window named
/// `<project>: <worktree>` — the convention for worktree windows — is grouped
/// under its project, which gets a collapsible sticky header; the window
/// itself is then labeled by its worktree alone.
enum PaneSidebarWindowGrouping {
    /// A window title split as `<project>: <worktree>`, or nil when it isn't
    /// one: both halves must be non-empty, and the project short and a single
    /// line — a sentence that happens to contain a colon is not a project.
    static func split(_ title: String) -> (project: String, worktree: String)? {
        guard let range = title.range(of: ": ") else { return nil }
        let project = title[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
        let worktree = title[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !project.isEmpty, !worktree.isEmpty,
              project.count <= 40,
              !project.contains(where: \.isNewline)
        else { return nil }
        return (project, worktree)
    }

    struct Entry<ID: Hashable> {
        let id: ID
        let title: String
        /// What the window's own header shows: the worktree inside a group,
        /// else the whole title.
        let label: String
    }

    /// A top-level item: a project and its windows, or a lone window.
    struct Section<ID: Hashable>: Identifiable {
        /// Non-nil for a project group.
        let project: String?
        let windows: [Entry<ID>]

        var id: String { project.map { "project:" + $0 } ?? "window:\(windows[0].id)" }
    }

    /// Sections in name order: projects by name (their windows by worktree),
    /// interleaved with ungrouped windows by title.
    static func sections<ID: Hashable>(_ windows: [(id: ID, title: String)]) -> [Section<ID>] {
        var projects: [String: [Entry<ID>]] = [:]
        var sections: [Section<ID>] = []
        for window in windows {
            if let parts = split(window.title) {
                projects[parts.project, default: []].append(
                    .init(id: window.id, title: window.title, label: parts.worktree))
            } else {
                sections.append(.init(project: nil, windows: [
                    .init(id: window.id, title: window.title, label: window.title)]))
            }
        }
        for (project, entries) in projects {
            sections.append(.init(project: project, windows: entries.sorted { before($0.label, $1.label) }))
        }
        return sections.sorted { before($0.project ?? $0.windows[0].title, $1.project ?? $1.windows[0].title) }
    }

    /// Finder's order: case-insensitive, numbers by value ("wt-2" before
    /// "wt-10").
    static func before(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}

// MARK: - All-windows search (pure)

/// The all-windows search: whitespace-separated terms, ALL of which must
/// appear (case- and diacritic-insensitive) somewhere in what a pane's row
/// says about it — its window's title (so `ghoztty` keeps a whole project and
/// `ghoztty relay` can't), its own title, its banner, its working directory
/// or location. Tested in `PaneSidebarFilterTests`.
enum PaneSidebarFilter {
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func matches(_ terms: [String], in fields: [String?]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = fields.compactMap { $0 }.joined(separator: "\n")
        return terms.allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

// MARK: - Sidebar order (pure)

/// The sidebar's own order of a window's panes. A drag in the list reorders
/// the LIST — the grid stays as it is — so the list keeps an order of its
/// own, reconciled against the tree on every read. Tested in
/// `PaneSidebarOrderTests`.
///
/// - Panes the order has never seen (a new split, a pane moved in from
///   another window) go beside their tree neighbour: after the nearest pane
///   before them in the tree that the order knows, else before the nearest
///   after them, else at the end. A split appears next to the pane it came
///   from.
/// - A pane that leaves the grid (stashed) keeps its place in the order, so
///   it comes back to the same spot. A closed pane is pruned on the next
///   move.
enum PaneSidebarOrder {
    /// `visible` — the grid's panes, in tree order — in the sidebar's order.
    static func arranged(_ visible: [UUID], by order: [UUID]) -> [UUID] {
        guard !order.isEmpty else { return visible }
        let shown = Set(visible)
        var result = order.filter { shown.contains($0) }
        var known = Set(result)
        for (index, id) in visible.enumerated() where !known.contains(id) {
            if let before = visible[..<index].last(where: known.contains),
               let at = result.firstIndex(of: before) {
                result.insert(id, at: at + 1)
            } else if let after = visible[(index + 1)...].first(where: known.contains),
                      let at = result.firstIndex(of: after) {
                result.insert(id, at: at)
            } else {
                result.append(id)
            }
            known.insert(id)
        }
        return result
    }

    /// The order after moving `id` to `index` of the arranged list, which
    /// `id` must be in (`visible`). Ids the order knows that are not on show
    /// (stashed panes) keep their place after whatever preceded them; ids in
    /// neither `visible` nor `existing` are dropped.
    static func moving(
        _ id: UUID,
        to index: Int,
        visible: [UUID],
        order: [UUID],
        existing: Set<UUID>
    ) -> [UUID] {
        var list = arranged(visible, by: order).filter { $0 != id }
        list.insert(id, at: Swift.min(Swift.max(index, 0), list.count))
        // Put back the panes not on show, each after the id it followed.
        let onShow = Set(list)
        var previous: UUID?
        var followers: [UUID?: [UUID]] = [:]
        for entry in order {
            // Not after the moved pane: the others stay where they were.
            if onShow.contains(entry) {
                if entry != id { previous = entry }
            } else if existing.contains(entry) {
                followers[previous, default: []].append(entry)
            }
        }
        var result = followers[nil] ?? []
        for entry in list {
            result.append(entry)
            result.append(contentsOf: followers[entry] ?? [])
        }
        return result
    }

    /// Where each of a section's rows is drawn while a drag is over the
    /// sidebar: the dragged row's gap closes where it left and opens where it
    /// would land, every other row sliding by the dragged row's height.
    /// `source` is the dragged row's index in this section (nil when it comes
    /// from elsewhere); `target` the index it would land at, of the section
    /// without it (nil when it would land elsewhere). The offset of row
    /// `index`, in rows (multiply by the row height).
    static func shift(index: Int, source: Int?, target: Int?) -> Int {
        if index == source { return 0 }
        let after = source.map { index > $0 } ?? false
        let without = after ? index - 1 : index
        let opens = target.map { without >= $0 } ?? false
        return (opens ? 1 : 0) - (after ? 1 : 0)
    }
}

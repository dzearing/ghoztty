import AppKit
import SwiftUI

/// Per-window state for the pane sidebar (`docs/design/pane-sidebar.md`).
///
/// Two kinds of state live here, and the difference matters:
///
/// - **Layout** — `isPinned` and `isHidden`. They size the sidebar's column,
///   which is part of the window's layout, so they persist (per window, in the
///   session-layout manifest) and are what new windows start from.
/// - **Transient** — `isHoverOpen`, `isQuickKill`, `showsAllWindows`, and the
///   folded window groups. Never persisted: a hover is over when the pointer
///   leaves, and a window must never come back in kill mode.
///
/// The stash itself is NOT here — it is part of the tree (`SplitTree.stashed`),
/// which is what keeps a stashed pane in the window for everything else.
@MainActor
final class PaneSidebarState: ObservableObject {
    /// Flat, full-width panel (true) or the raised mini rail (false).
    @Published var isPinned: Bool {
        didSet { if isPinned != oldValue { Self.rememberForNewWindows(self) } }
    }

    /// Hidden outright (Ctrl+Cmd+S). Not a drop target while hidden.
    @Published var isHidden: Bool {
        didSet { if isHidden != oldValue { Self.rememberForNewWindows(self) } }
    }

    /// The mini rail is open to full width under the pointer.
    @Published var isHoverOpen: Bool = false

    /// Trash mode: every row grows a red × that kills with no confirmation.
    @Published var isQuickKill: Bool = false

    /// List panes from every window, grouped by window. Off by default.
    @Published var showsAllWindows: Bool = false

    /// Window groups folded closed in the all-windows list.
    @Published var foldedWindows: Set<ObjectIdentifier> = []
    /// Folded project groups in the all-windows scope, by project name.
    @Published var foldedProjects: Set<String> = []

    /// The flat panel's width. One preference shared by every window, like
    /// the viewer side panel's.
    @Published var width: CGFloat {
        didSet { UserDefaults.standard.set(Double(width), forKey: Self.widthKey) }
    }

    init(isPinned: Bool? = nil, isHidden: Bool? = nil) {
        let defaults = UserDefaults.standard
        self.isPinned = isPinned ?? (defaults.object(forKey: Self.pinnedKey) as? Bool ?? false)
        self.isHidden = isHidden ?? (defaults.object(forKey: Self.hiddenKey) as? Bool ?? false)
        let stored = defaults.double(forKey: Self.widthKey)
        self.width = stored > 0 ? Self.clampWidth(CGFloat(stored)) : Self.defaultWidth
    }

    // MARK: Layout rules (pure; see PaneSidebarStateTests)

    enum Mode: Equatable {
        case hidden
        /// Pinned: the flat panel.
        case expanded
        /// Unpinned (or a narrow window): the raised mini rail.
        case mini
    }

    /// Below this window width the full panel would crowd the grid; the mini
    /// rail doesn't. The same breakpoint the viewer side panel uses.
    nonisolated static let narrowWindowWidth: CGFloat = 720

    nonisolated static let defaultWidth: CGFloat = 240
    nonisolated static let minimumWidth: CGFloat = 180
    nonisolated static let maximumWidth: CGFloat = 380

    /// The mini rail's card.
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

    /// The rail's column: its insets and the card.
    nonisolated static func railColumnWidth(elevated: Bool) -> CGFloat {
        let insets = railInsets(elevated: elevated)
        return insets.leading + railCardWidth + insets.trailing
    }

    /// Dragging the edge is the same gesture as the pin: a panel pushed under
    /// this collapses to the rail, a rail pulled past `expandThreshold` pins.
    nonisolated static let collapseThreshold: CGFloat = 140
    nonisolated static let expandThreshold: CGFloat = 120

    /// Hover-open timing: a short intent delay on the way in (so passing over
    /// the rail on the way somewhere else doesn't pop it open) and a grace
    /// period on the way out.
    nonisolated static let hoverOpenDelay: TimeInterval = 0.1
    nonisolated static let hoverCloseDelay: TimeInterval = 0.28

    nonisolated static func mode(isPinned: Bool, isHidden: Bool, windowWidth: CGFloat) -> Mode {
        if isHidden { return .hidden }
        if isPinned && windowWidth >= narrowWindowWidth { return .expanded }
        return .mini
    }

    func mode(windowWidth: CGFloat) -> Mode {
        Self.mode(isPinned: isPinned, isHidden: isHidden, windowWidth: windowWidth)
    }

    /// The width of the sidebar's COLUMN — what the grid is laid out beside.
    ///
    /// Deliberately independent of `isHoverOpen`: the hover-open card floats
    /// over the grid. Widening the column on hover would resize every terminal
    /// in the window (a SIGWINCH and a TUI redraw) each time the pointer
    /// passed by; only pin/unpin, which are deliberate, change it.
    nonisolated static func columnWidth(for mode: Mode, panelWidth: CGFloat, elevated: Bool) -> CGFloat {
        switch mode {
        case .hidden: 0
        case .expanded: panelWidth
        case .mini: railColumnWidth(elevated: elevated)
        }
    }

    nonisolated static func clampWidth(_ width: CGFloat) -> CGFloat {
        Swift.min(maximumWidth, Swift.max(minimumWidth, width))
    }

    // MARK: Defaults for new windows

    private static let pinnedKey = "PaneSidebarPinned"
    private static let hiddenKey = "PaneSidebarHidden"
    private static let widthKey = "PaneSidebarWidth"

    /// New windows start from the most recently chosen layout, the way a
    /// Finder window's sidebar does.
    private static func rememberForNewWindows(_ state: PaneSidebarState) {
        UserDefaults.standard.set(state.isPinned, forKey: pinnedKey)
        UserDefaults.standard.set(state.isHidden, forKey: hiddenKey)
    }
}

// MARK: - Row text (pure)

/// The text a sidebar row or rail tile shows for a pane. Pure, so the rules
/// are unit-tested (`PaneSidebarTextTests`).
enum PaneSidebarText {
    /// A rail tile's label. Every terminal shares one icon, so a tile needs
    /// text that tells panes apart: the part of the title after an em dash
    /// (`claude — relay` → `RE`), else the command's first word (`zsh`,
    /// `npm`), up to three characters.
    static func monogram(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        if let dash = trimmed.range(of: " — ") ?? trimmed.range(of: " - ") {
            let tail = trimmed[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            let words = tail
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { !$0.isEmpty }
            if words.count >= 2 {
                return String(words.prefix(2).compactMap(\.first)).uppercased()
            }
            if let word = words.first {
                return String(word.prefix(2)).uppercased()
            }
        }
        // A path — what a shell titles itself by default: its last component,
        // and home is "~" itself (a mark, not a bullet).
        if trimmed == "~" || trimmed.hasPrefix("~/") || trimmed.hasPrefix("/") {
            let last = (trimmed as NSString).lastPathComponent
            if last == "~" || last == "/" || last.isEmpty { return trimmed == "/" ? "/" : "~" }
            let letters = last.filter { $0.isLetter || $0.isNumber }
            if !letters.isEmpty { return String(letters.prefix(3)).lowercased() }
        }
        // A command: its first word, minus any path ("/bin/zsh" → "zsh").
        let first = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        let command = (first as NSString).lastPathComponent
        let letters = command.filter { $0.isLetter || $0.isNumber }
        if !letters.isEmpty { return String(letters.prefix(3)).lowercased() }
        // No letters at all: show what there is rather than a bullet.
        let visible = trimmed.filter { !$0.isWhitespace }
        return visible.isEmpty ? "•" : String(visible.prefix(2))
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

    /// The first line of a pane banner as plain text: the markdown subset the
    /// banner renders (`**bold**`, `*italic*`, `_italic_`, `__underline__`,
    /// `` `code` ``, `[text](url)`, `\` escapes) stripped to its words. Table
    /// and rule lines are skipped — they are layout, not a summary.
    static func bannerLine(_ banner: String?) -> String? {
        guard let banner else { return nil }
        let lines = banner
            .replacingOccurrences(of: "\\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let line = lines.first(where: { line in
            !line.isEmpty
                && !line.hasPrefix("|")
                && !isThematicBreak(line)
        }) else { return nil }
        let plain = stripInlineMarkdown(line)
        return plain.isEmpty ? nil : plain
    }

    /// The row's subtitle: the banner's first line when there is one (the
    /// banner hooks keep it as a live title/goal/status — the most useful
    /// single line about an agent pane), else the working directory or the
    /// viewer's location.
    static func subtitle(banner: String?, pwd: String?, viewerLocation: String?) -> String? {
        if let line = bannerLine(banner) { return line }
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

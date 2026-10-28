import AppKit
import Combine
import SwiftUI

/// The pane sidebar's view state that every window shares
/// (`docs/reference/pane-sidebar.md` → Shared across windows): one app-wide
/// model every window's sidebar observes, so changing any of it in one
/// window changes it in all of them, live, and clicking through windows
/// shows the same sidebar.
///
/// - **Layout** — `isExpanded`, `isHidden`, `width`. They size each window's
///   sidebar column, so they persist (UserDefaults). Each window still applies
///   its own presentation rule on top: a window under 720pt shows the rail
///   whatever `isExpanded` says (`PaneSidebarState.mode`).
/// - **The all-windows list** — the scope, the search, the folds, the custom
///   order of windows and project groups (`windowOrder`, persisted), and the
///   scroll position (`PaneSidebarScrollSync`).
@MainActor
final class PaneSidebarSharedState: ObservableObject {
    /// A test host keeps its own throwaway store: window tests hide and
    /// resize sidebars, and that must never reach the user's real debug app.
    static let shared = PaneSidebarSharedState(defaults: AppDelegate.isTestHost
        ? UserDefaults(suiteName: "PaneSidebarTestHost-\(UUID().uuidString)")!
        : .standard)

    let defaults: UserDefaults

    /// The full list (true) or the icon-only rail (false).
    @Published var isExpanded: Bool {
        didSet { if isExpanded != oldValue { defaults.set(isExpanded, forKey: Self.expandedKey) } }
    }

    /// Hidden outright (Ctrl+Cmd+S).
    @Published var isHidden: Bool {
        didSet { if isHidden != oldValue { defaults.set(isHidden, forKey: Self.hiddenKey) } }
    }

    /// The expanded panel's width. Written to the defaults once an edge drag
    /// pauses, not on every frame of it.
    @Published var width: CGFloat {
        didSet {
            guard width != oldValue else { return }
            widthWrite?.cancel()
            let (defaults, width) = (defaults, width)
            let write = DispatchWorkItem { defaults.set(Double(width), forKey: Self.widthKey) }
            widthWrite = write
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: write)
        }
    }
    private var widthWrite: DispatchWorkItem?

    /// List panes from every window, grouped by window. Off at launch.
    @Published var showsAllWindows: Bool = false {
        didSet {
            // A filter belongs to one look at every window, not to the next
            // one — and so do the window folds: each look starts from the
            // default.
            if !showsAllWindows && oldValue {
                filter = ""
                unfoldedWindows = []
            }
        }
    }

    /// The all-windows search (`PaneSidebarFilter`). Empty = no filter.
    @Published var filter: String = ""

    /// Windows whose panes are showing in the all-windows list, by
    /// `PaneSidebarState.windowID`; every other window is folded to its row
    /// (`isWindowFolded`). Absolute, not relative to the viewing window, so
    /// every window's list folds alike.
    @Published var unfoldedWindows: Set<UUID> = []

    /// Windows folded to their header in the "this window" list (where a
    /// window starts open), by `windowID`. Kept apart from
    /// `unfoldedWindows`: the all-windows overview starts every other window
    /// folded, this window's own list starts open.
    @Published var foldedThisWindowLists: Set<UUID> = []

    /// Folded project groups in the all-windows list, by project name.
    @Published var foldedProjects: Set<String> = []

    /// Another window's row (`windowID`) or pane row (pane id) just clicked
    /// in the all-windows list: drawn selected at once, in the window it was
    /// clicked in, while that window comes forward and draws its own
    /// selection. Cleared as it becomes key (`clearClicked`).
    @Published var clickedWindow: UUID?
    @Published var clickedPane: UUID?

    /// `windowID`'s window became key: it shows its own selection now.
    func clearClicked(windowID: UUID, panes: Set<UUID>) {
        if clickedWindow == windowID { clickedWindow = nil }
        if let pane = clickedPane, panes.contains(pane) { clickedPane = nil }
    }

    /// The all-windows list's own order of windows and project groups, by
    /// `PaneSidebarWindowGrouping` key, as a drag left it. Empty = by name.
    /// Read through `PaneSidebarWindowGrouping.sections(_:order:)`, which
    /// places windows and groups it has never seen beside their name
    /// neighbour; pruned of closed windows on the next move.
    @Published var windowOrder: [String] {
        didSet { if windowOrder != oldValue { defaults.set(windowOrder, forKey: Self.windowOrderKey) } }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        isExpanded = Self.storedExpanded(defaults)
        isHidden = defaults.object(forKey: Self.hiddenKey) as? Bool ?? false
        let stored = defaults.double(forKey: Self.widthKey)
        width = stored > 0 ? PaneSidebarState.clampWidth(CGFloat(stored)) : PaneSidebarState.defaultWidth
        windowOrder = defaults.stringArray(forKey: Self.windowOrderKey) ?? []
    }

    /// The all-windows toggle. Turning it on folds every window to its row —
    /// the one it was turned on from too — the overview that scope is for.
    func setShowsAllWindows(_ on: Bool) {
        guard on != showsAllWindows else { return }
        if on { unfoldedWindows = [] }
        showsAllWindows = on
    }

    // MARK: Persistence

    static let expandedKey = "PaneSidebarExpanded"
    /// Before collapse/expand there was a pin: pinned was the flat full panel,
    /// which is what expanded is, so a stored pin is read as that.
    static let legacyPinnedKey = "PaneSidebarPinned"
    static let hiddenKey = "PaneSidebarHidden"
    static let widthKey = "PaneSidebarWidth"
    static let windowOrderKey = "PaneSidebarWindowOrder"

    nonisolated static func storedExpanded(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: expandedKey) as? Bool
            ?? defaults.object(forKey: legacyPinnedKey) as? Bool
            ?? false
    }
}

/// One window's pane sidebar: the window's own state, and a view of the
/// state every window shares (`PaneSidebarSharedState`), so a window reads
/// `state.isExpanded` the same as before the two were split.
///
/// Only the window in use redraws for a shared change as it happens
/// (`isLive`, or the change was made through this window's state); every
/// other window catches up when it becomes key (`catchUp`), so a width drag,
/// a collapse, or a search typed in one window never re-renders — or
/// re-lays out — every other window per keystroke or frame. The column too:
/// a background window takes a collapse or expand, and resizes its grid for
/// it, when it is next key.
///
/// Per window: the sidebar's order of THIS window's panes (`order`), its
/// identity in the all-windows list (`windowID`), and drawing details
/// (`tabRowHeight`). Everything else is shared.
///
/// The stash itself is NOT here — it is part of the tree (`SplitTree.stashed`),
/// which is what keeps a stashed pane in the window for everything else.
@MainActor
final class PaneSidebarState: ObservableObject {
    let shared: PaneSidebarSharedState
    private var sharedChanges: AnyCancellable?
    private var rosterChanges: AnyCancellable?

    /// Whether this sidebar redraws for a shared change right away: its
    /// window is key (or has none yet). Set by the window's controller.
    var isLive: () -> Bool = { true }
    /// A shared change came in while not live: redraw on `catchUp`.
    private(set) var isStale = false
    /// A change made through THIS window's state: it redraws, live or not.
    private var isChanging = false

    private func change(_ body: () -> Void) {
        isChanging = true
        body()
        isChanging = false
    }

    /// The full list (true) or the icon-only rail (false). One button at the
    /// top of the bar switches it; nothing else does — there is no hover-open,
    /// since the rail is where its icons are dragged. Shared.
    var isExpanded: Bool {
        get { shared.isExpanded }
        set { change { shared.isExpanded = newValue } }
    }

    /// Hidden outright (Ctrl+Cmd+S). Not a drop target while hidden. Shared.
    var isHidden: Bool {
        get { shared.isHidden }
        set { change { shared.isHidden = newValue } }
    }

    /// The flat panel's width. Shared.
    var width: CGFloat {
        get { shared.width }
        set { change { shared.width = newValue } }
    }

    /// List panes from every window, grouped by window. Shared.
    var showsAllWindows: Bool {
        get { shared.showsAllWindows }
        set { change { shared.setShowsAllWindows(newValue) } }
    }

    /// The all-windows search. Shared.
    var filter: String {
        get { shared.filter }
        set { change { shared.filter = newValue } }
    }

    /// Folded project groups in the all-windows scope. Shared.
    var foldedProjects: Set<String> {
        get { shared.foldedProjects }
        set { change { shared.foldedProjects = newValue } }
    }

    /// This window in the all-windows list: what its fold and its place in
    /// the list's order are kept under. Persisted with the window, so a
    /// restored window keeps its place.
    var windowID = UUID()

    /// The sidebar's own order of this window's panes, by pane id — what a
    /// drag within the list changes. It orders the LIST only: the grid is
    /// never touched. Empty until the first reorder, which means "the tree's
    /// order". Read through `PaneSidebarOrder.arranged`, which also places
    /// panes it has never seen; a stashed pane keeps its place in it, so it
    /// comes back to the same spot.
    @Published var order: [UUID] = []

    /// How far the sidebar's drawn chrome reaches up past the grid, beside
    /// the window's tab bar (`TransparentTitlebarTerminalWindow` sets it to the
    /// tab row's height while the tab bar is moved right of the sidebar; 0
    /// otherwise). Drawing only: the titlebar owns every click in that strip,
    /// so the rows themselves stay below it. Never persisted.
    @Published var tabRowHeight: CGFloat = 0

    init(shared: PaneSidebarSharedState = .shared, roster: PaneRoster? = .shared) {
        self.shared = shared
        // Another window opened, closed, came forward or changed its panes:
        // the all-windows list redraws for it now in the window in use, and
        // in the others when they are next key — a window switch must not
        // re-render every window's sidebar.
        rosterChanges = roster?.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            if self.isLive() { self.objectWillChange.send() } else { self.isStale = true }
        }
        // A shared change is a change to every window's sidebar: now, in
        // the window in use; when it is next key, in the others.
        sharedChanges = shared.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            if self.isChanging || self.isLive() {
                self.isStale = false
                self.objectWillChange.send()
            } else {
                self.isStale = true
            }
        }
    }

    /// The window became key: show whatever changed while it was not.
    func catchUp() {
        guard isStale else { return }
        isStale = false
        objectWillChange.send()
    }

    /// Whether `windowID`'s panes are folded away: in the all-windows list
    /// (folded unless unfolded), or in its own "this window" list (open
    /// unless folded).
    func isWindowFolded(_ windowID: UUID, isSearching: Bool) -> Bool {
        guard showsAllWindows else { return shared.foldedThisWindowLists.contains(windowID) }
        return Self.isWindowFolded(isUnfolded: shared.unfoldedWindows.contains(windowID), isSearching: isSearching)
    }

    func toggleWindowFold(_ windowID: UUID) {
        change {
            if !showsAllWindows {
                shared.foldedThisWindowLists.formSymmetricDifference([windowID])
            } else if shared.unfoldedWindows.contains(windowID) {
                shared.unfoldedWindows.remove(windowID)
            } else {
                shared.unfoldedWindows.insert(windowID)
            }
        }
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

    /// The rail's card: exactly a row's pill around its icon — the pill
    /// `fillInset` in from each side, the icon `textInset` into the pill —
    /// so a tile's icon is where its row's is (`PaneSidebarRow.iconWidth`).
    nonisolated static let railCardWidth: CGFloat = 2 * (8 + 10) + 16

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

    /// The sidebar's card — the rail's, and the expanded list's, which is
    /// the same raised glass card at the panel's width: same margins, same
    /// top, same height, so a pane's icon sits at the same height in both.
    /// Its width.
    nonisolated static func cardWidth(for mode: Mode, panelWidth: CGFloat) -> CGFloat {
        mode == .expanded ? panelWidth : railCardWidth
    }

    /// Where the sidebar's edge grip lies, from the card's trailing edge:
    /// the gutter between the card and the panes, never over the card — the
    /// grid's margin in the elevated style, the card's own trailing margin in
    /// the flat one. The same in both modes, since the card is. (It used to
    /// sit just inside the rail card, its bar over the tiles.)
    static func edgeGrip(for mode: Mode, elevated: Bool) -> (offset: CGFloat, width: CGFloat) {
        (0, elevated ? PaneElevation.margin : railInsets(elevated: false).trailing)
    }

    /// How far the sidebar's host reaches past its column for the grip: only
    /// as far as the grip lies outside the column — the grid's margin,
    /// elevated; none, flat, where the gutter is the card's own margin.
    static func edgeReach(for mode: Mode, elevated: Bool) -> CGFloat {
        elevated ? PaneElevation.margin : 0
    }

    /// How far past the strips a gutter drag pushes before the expanded
    /// sidebar tucks into its rail (`BaseTerminalController.sidebarAwareRow`):
    /// what it would give before reaching its minimum, as a pane gives down
    /// to its own — kept between a nudge and a deliberate push.
    nonisolated static func dividerTuckGive(panelWidth: CGFloat) -> CGFloat {
        Swift.min(Swift.max(panelWidth - minimumWidth, 24), 80)
    }

    /// Dragged back, the sidebar comes back out this far past where it
    /// tucked, so the edge never flickers at one point.
    nonisolated static let dividerTuckHysteresis: CGFloat = 24

    /// Collapsing or expanding: the sidebar's width (and the crossfade of
    /// rail and panel) on the curve the grid's cards glide on — most of the
    /// travel up front, then a soft settle.
    nonisolated static let columnAnimation: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)

    /// The width an edge drag makes of the sidebar, from the width it would
    /// have at `proposed`: past the panel's minimum, expanded at that width
    /// (clamped); short of `expandThreshold`, collapsed; between the two, what
    /// it already is — expanded at its minimum, or still the rail. So the
    /// rail is pulled out by its gutter once the panel would fit, and the
    /// panel tucks back into the rail when pushed well under its minimum,
    /// both within one drag and both ways.
    nonisolated static func edgeDrag(proposed: CGFloat, isExpanded: Bool) -> (expanded: Bool, width: CGFloat?) {
        if proposed >= minimumWidth { return (true, clampWidth(proposed)) }
        if proposed < expandThreshold { return (false, nil) }
        return isExpanded ? (true, minimumWidth) : (false, nil)
    }

    /// The rail's column: its insets and the card.
    nonisolated static func railColumnWidth(elevated: Bool) -> CGFloat {
        let insets = railInsets(elevated: elevated)
        return insets.leading + railCardWidth + insets.trailing
    }

    /// An expanded panel's edge pushed in short of this collapses it to the
    /// rail (`edgeDrag`); between this and `minimumWidth` it stops at its
    /// minimum.
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
    /// Every window is folded — one row per window, the overview that scope
    /// is for, the window the list was turned on from included
    /// (`PaneSidebarSharedState.setShowsAllWindows`) — unless it was unfolded
    /// by hand. The
    /// same in every window's list, since the folds are shared; focus moving
    /// later never unfolds anything, or the list would jump under the
    /// pointer. A search unfolds everything, since a hit hidden inside a fold
    /// reads as no hit.
    nonisolated static func isWindowFolded(isUnfolded: Bool, isSearching: Bool) -> Bool {
        if isSearching { return false }
        return !isUnfolded
    }

    func mode(windowWidth: CGFloat) -> Mode {
        Self.mode(isExpanded: isExpanded, isHidden: isHidden, windowWidth: windowWidth)
    }

    /// The width of the sidebar's COLUMN — what the grid is laid out beside.
    /// Only collapse/expand and hide/show change it, so a terminal is resized
    /// only by something somebody chose.
    nonisolated static func columnWidth(for mode: Mode, panelWidth: CGFloat, elevated: Bool) -> CGFloat {
        guard mode != .hidden else { return 0 }
        let insets = railInsets(elevated: elevated)
        return insets.leading + cardWidth(for: mode, panelWidth: panelWidth) + insets.trailing
    }

    /// The sidebar host's width, whichever mode it is in: the expanded
    /// column and the gutter its grip lies in, or the rail's, the wider —
    /// so collapsing or expanding never resizes the host under its card.
    static func hostWidth(panelWidth: CGFloat, elevated: Bool) -> CGFloat {
        [Mode.expanded, .collapsed].map {
            columnWidth(for: $0, panelWidth: panelWidth, elevated: elevated) + edgeReach(for: $0, elevated: elevated)
        }.max() ?? 0
    }

    nonisolated static func clampWidth(_ width: CGFloat) -> CGFloat {
        Swift.min(maximumWidth, Swift.max(minimumWidth, width))
    }
}

// MARK: - Row text (pure)

/// The text a sidebar row or rail tile shows for a pane. Pure, so the rules
/// are unit-tested (`PaneSidebarTextTests`).
enum PaneSidebarText {
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
    /// row, a rail tile, a stacked pane's strip: the name the user gave it
    /// (`userTitle`: Change Pane Title, the sidebar's pencil), else its
    /// banner's title when the banner has one, else `title`. The banner title
    /// beats the terminal's because it is the one somebody chose: an agent's
    /// banner hook sets it to the task, while the agent itself retitles the
    /// pane (OSC 0/2) with whatever it is doing.
    static func label(title raw: String, pwd: String?, kind: String, banner: String?, userTitle: String? = nil) -> String {
        if let userTitle, !userTitle.isEmpty { return userTitle }
        return bannerTitle(banner) ?? title(raw, pwd: pwd, kind: kind)
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
/// A window named `<project>: <worktree>` — the convention for worktree
/// windows — is grouped under its project, which gets a collapsible sticky
/// header; the window itself is then labeled by its worktree alone.
///
/// The order is the user's (`sections(_:order:)`): windows and groups go
/// where a drag left them, kept as one list of keys (`key(project:)`,
/// `key(window:)`). Until something is dragged — and for any window or group
/// the order has never seen — it is by name (stable as focus moves, unlike
/// frontmost-first, which reshuffled the list on every window switch).
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

        var key: String { PaneSidebarWindowGrouping.key(window: id) }
    }

    /// A top-level item: a project and its windows, or a lone window.
    struct Section<ID: Hashable>: Identifiable {
        /// Non-nil for a project group.
        let project: String?
        let windows: [Entry<ID>]

        /// Its key in the list's order.
        var id: String { project.map(PaneSidebarWindowGrouping.key(project:)) ?? windows[0].key }
    }

    /// A project group's key in the all-windows order.
    static func key(project: String) -> String { "project:" + project }
    /// A window's key in the all-windows order.
    static func key<ID>(window id: ID) -> String { "window:\(id)" }

    /// Sections in name order: projects by name (their windows by worktree),
    /// interleaved with ungrouped windows by title.
    static func sections<ID: Hashable>(_ windows: [(id: ID, title: String)]) -> [Section<ID>] {
        var projects: [String: [Entry<ID>]] = [:]
        var sections: [Section<ID>] = []
        // Windows come in frontmost first. Put them in one fixed order before
        // anything else, so windows that share a name (two shells both
        // called `~`) tie-break the same way in every window's list — not
        // with whichever window you are in on top.
        let windows = windows.sorted { "\($0.id)" < "\($1.id)" }
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
            sections.append(.init(project: project, windows: entries.sorted { before($0.label, $1.label, $0.key, $1.key) }))
        }
        return sections.sorted {
            before($0.project ?? $0.windows[0].title, $1.project ?? $1.windows[0].title, $0.id, $1.id)
        }
    }

    /// `sections(windows)` in the user's order: the top level (groups and
    /// lone windows) and each group's windows each follow `order`
    /// (`PaneSidebarOrder.arranged`, over the name order). Whatever `order`
    /// has never seen — a new window, a new group, a window that moved into
    /// a group by being renamed — goes after its name-order neighbour that
    /// it has seen (else before the next one, else at the end), so a new
    /// `ghoztty: wt-3` lands right after `ghoztty: wt-2` wherever that was
    /// dragged. Closed windows are simply not there.
    static func sections<ID: Hashable>(_ windows: [(id: ID, title: String)], order: [String]) -> [Section<ID>] {
        let byName = sections(windows)
        guard !order.isEmpty else { return byName }
        let byKey = Dictionary(byName.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return PaneSidebarOrder.arranged(byName.map(\.id), by: order).compactMap { key in
            guard let section = byKey[key] else { return nil }
            guard section.project != nil else { return section }
            let entries = Dictionary(section.windows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
            let windows = PaneSidebarOrder.arranged(section.windows.map(\.key), by: order).compactMap { entries[$0] }
            return Section(project: section.project, windows: windows)
        }
    }

    /// Every key the all-windows list has now — each group and each window —
    /// for `PaneSidebarOrder.moving`'s `existing`: a key outside it (a
    /// closed window) is pruned from the order.
    static func keys<ID: Hashable>(_ sections: [Section<ID>]) -> Set<String> {
        Set(sections.flatMap { section in
            (section.project.map { [key(project: $0)] } ?? []) + section.windows.map(\.key)
        })
    }

    /// `sections` as an order: every group's key, then its windows', and
    /// each lone window's, as listed. Read back over the same windows, it
    /// lists them exactly so, whatever their names.
    static func pinned<ID: Hashable>(_ sections: [Section<ID>]) -> [String] {
        sections.flatMap { section in
            (section.project.map { [key(project: $0)] } ?? []) + section.windows.map(\.key)
        }
    }

    /// The order to keep while window `id` is retitled `title`: the list as
    /// `sections` shows it (`pinned`), so a rename moves nothing — by name,
    /// a new title would re-sort it. A `<project>: ` that names another
    /// group still moves it there, at the edge nearest where it was; one
    /// that names a group not in the list makes that group where the window
    /// was. Dropping its `<project>: ` leaves it beside the group it left.
    static func renaming<ID: Hashable>(window id: ID, to title: String, in sections: [Section<ID>]) -> [String] {
        var order = pinned(sections)
        if let project = split(title)?.project, !order.contains(key(project: project)),
           let index = order.firstIndex(of: key(window: id)) {
            order.insert(key(project: project), at: index)
        }
        return order
    }

    /// The order to keep while group `project` is renamed `name` (each of
    /// its windows retitled `<name>: <label>`): the list as shown, the
    /// group's key renamed in place. Named as another group, it merges
    /// into that one where that one is; emptied, its windows stand where
    /// it was, in its order.
    static func renaming<ID: Hashable>(project: String, to name: String, in sections: [Section<ID>]) -> [String] {
        var order = pinned(sections)
        guard let index = order.firstIndex(of: key(project: project)) else { return order }
        if name.isEmpty || order.contains(key(project: name)) {
            order.remove(at: index)
        } else {
            order[index] = key(project: name)
        }
        return order
    }

    /// Finder's order: case-insensitive, numbers by value ("wt-2" before
    /// "wt-10").
    static func before(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    /// `before`, names that compare equal ordered by `aKey`/`bKey`: one total
    /// order, the same whatever order the windows came in.
    static func before(_ a: String, _ b: String, _ aKey: String, _ bKey: String) -> Bool {
        switch a.localizedStandardCompare(b) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: aKey < bKey
        }
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
    static func arranged<ID: Hashable>(_ visible: [ID], by order: [ID]) -> [ID] {
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
    static func moving<ID: Hashable>(
        _ id: ID,
        to index: Int,
        visible: [ID],
        order: [ID],
        existing: Set<ID>
    ) -> [ID] {
        var list = arranged(visible, by: order).filter { $0 != id }
        list.insert(id, at: Swift.min(Swift.max(index, 0), list.count))
        // Put back the panes not on show, each after the id it followed.
        let onShow = Set(list)
        var previous: ID?
        var followers: [ID?: [ID]] = [:]
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

// MARK: - Pane hues

/// Each pane's own hue in the sidebar: its tile is tinted with it, and
/// hovering its tile or row tints the pane itself (`PaneSidebarHover`), so the
/// sidebar says which pane an icon is. Spaced by the golden ratio along the
/// pane's place in its window's tree, so neighbours never come out alike —
/// and the list's own order (a drag) changes no pane's color.
enum PaneSidebarHue {
    /// The hue, 0..<1, of the pane at `index` of its window's tree.
    nonisolated static func hue(index: Int) -> Double {
        let h = (0.58 + Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1)
        return h < 0 ? h + 1 : h
    }

    /// Light and soft enough to read on a dark sidebar as an icon on its own
    /// — at full saturation the deep hues (violet, blue) sank into it — and
    /// deeper on a light one, where a pastel would vanish.
    nonisolated static func color(index: Int) -> Color {
        let h = hue(index: index)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hue: h, saturation: 0.42, brightness: 1, alpha: 1)
                : NSColor(hue: h, saturation: 0.7, brightness: 0.62, alpha: 1)
        })
    }

    /// `pane`'s color in `owner`'s tree (stashed panes included).
    @MainActor
    static func color(for pane: PaneView, in owner: BaseTerminalController) -> Color {
        color(index: owner.surfaceTree.enumerated().first { $0.element === pane }?.offset ?? 0)
    }
}

/// The pane whose sidebar tile or row is under the pointer, and its hue:
/// that pane is tinted with it (`PaneSidebarHoverTint`) — quickly in, and
/// back out when the pointer leaves.
@MainActor
final class PaneSidebarHover: ObservableObject {
    static let shared = PaneSidebarHover()

    @Published private(set) var pane: UUID?
    private(set) var color: Color = .clear

    /// The tint fades in this fast and back out a touch slower: quick, never
    /// a flicker as the pointer runs down the list.
    static let fadeIn: Animation = .easeOut(duration: 0.12)
    static let fadeOut: Animation = .easeOut(duration: 0.2)

    func hover(_ pane: UUID, color: Color) {
        self.color = color
        self.pane = pane
    }

    /// The pointer left `pane`'s tile or row (another may already have it).
    func leave(_ pane: UUID) {
        if self.pane == pane { self.pane = nil }
    }
}

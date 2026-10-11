import AppKit
import Combine
import SwiftUI

/// The pane sidebar's content: header, the window's panes (grid, then
/// stashed), and — with the all-windows scope — every other window's.
///
/// Mounted inside `PaneSidebarHostView`, an AppKit host, never directly in
/// the terminal's SwiftUI tree: see that type for why.
struct PaneSidebarView: View {
    @ObservedObject var controller: BaseTerminalController
    @ObservedObject var state: PaneSidebarState
    @ObservedObject var geometry: PaneSidebarGeometry
    @ObservedObject private var roster = PaneRoster.shared
    @ObservedObject private var dragSession = PaneDragSession.shared

    /// Laid out as the mini rail (tiles) rather than full rows.
    let isRail: Bool
    /// The flat pinned panel (vs the raised card).
    let isFlat: Bool

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.paneSidebarInteractive) private var isInteractive
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        content
            .onPreferenceChange(PaneSidebarRowFrames.self) { geometry.rowFrames = $0 }
            .onPreferenceChange(PaneSidebarGroupFrames.self) { geometry.groupFrames = $0 }
            .font(.system(size: 12))
            .environment(\.paneSidebarEmphasized, controlActiveState == .key)
    }

    /// Glass panes: the header is no band of its own — just the caption and
    /// buttons on the panel, as in the mock — so the list starts BELOW it
    /// rather than scrolling under a backdrop.
    @ViewBuilder
    private var content: some View {
        if isRail {
            // The minimized rail is just its tiles: the header's buttons are
            // there once it opens (hover) or is pinned.
            list
        } else if controller.ghostty.config.paneGlass {
            VStack(spacing: 0) {
                headerContent
                list
            }
        } else {
            list.safeAreaInset(edge: .top, spacing: 0) {
                SidePanelHeader(base: controller.ghostty.config.backgroundColor) { headerContent }
            }
        }
    }

    // MARK: Header

    private var headerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                caption
                Spacer(minLength: 4)
                headerButtons
            }
            .padding(.leading, SidePanelRow.labelInset)
            .padding(.trailing, 6)
            .frame(height: 34)
            // All windows is the "find that pane" view, so it brings a
            // search with it.
            if state.showsAllWindows {
                searchField
                    .transition(PaneSidebarOutline.foldTransition)
            }
        }
    }

    private var caption: some View {
        Group {
            if state.isQuickKill {
                SidePanelCaption(text: "Click × to kill", color: Color(nsColor: .systemRed))
            } else {
                SidePanelCaption(text: state.showsAllWindows ? "All windows" : "Panes")
            }
        }
    }

    @ViewBuilder
    private var headerButtons: some View {
        PaneSidebarHeaderButton(
            symbol: .windows(filled: state.showsAllWindows),
            help: state.showsAllWindows ? "Show only this window’s panes" : "Show panes from all windows"
        ) {
            withAnimation(PaneSidebarOutline.scopeAnimation) { state.showsAllWindows.toggle() }
        }

        PaneSidebarHeaderButton(
            symbol: .trash(filled: state.isQuickKill),
            tint: state.isQuickKill ? Color(nsColor: .systemRed) : nil,
            help: state.isQuickKill
                ? "Done killing panes (Esc)"
                : "Quick close — kill panes with one click, no confirmation"
        ) { state.isQuickKill.toggle() }

        PaneSidebarHeaderButton(
            symbol: .pin(filled: state.isPinned),
            // Unpinned the pin lies tilted; pinned it stands upright.
            rotation: state.isPinned ? 0 : 45,
            help: state.isPinned ? "Unpin — collapse to icons" : "Pin — keep the sidebar open"
        ) { controller.togglePaneSidebarPin() }
    }

    // MARK: List

    /// Switching between this window and all windows slides like a
    /// navigation push: this window's list lives on the LEFT, all windows on
    /// the RIGHT, so going to all windows slides left and coming back slides
    /// right, each list fading as it goes. Each list's transition is tied to
    /// which list it IS (not to the direction of the switch), because a
    /// removed view animates with the transition it was last rendered with.
    private var list: some View {
        let side: CGFloat = state.showsAllWindows ? 1 : -1
        let slide = AnyTransition.offset(x: side * PaneSidebarOutline.scopeSlide).combined(with: .opacity)
        // A ZStack, so the outgoing and incoming lists overlap; clipped, so
        // neither slides past the panel's edge.
        return ZStack(alignment: .top) {
            scrollingList
                .id(state.showsAllWindows)
                .transition(slide)
        }
        .clipped()
    }

    @ViewBuilder
    private var scrollingList: some View {
        if isInteractive {
            ScrollView(.vertical) {
                // Lazy only for the pinned (sticky) project headers.
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    listContent
                }
                .padding(.vertical, SidePanelRow.fillInset)
            }
        } else {
            let content = VStack(alignment: .leading, spacing: 0) { listContent }
                .padding(.vertical, SidePanelRow.fillInset)
            // A still render (`ImageRenderer` can't draw ScrollView content).
            content.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if state.showsAllWindows {
            allWindows
        } else {
            windowSection(controller, isThisWindow: true, indent: 0)
        }
    }

    /// Every window, sorted by name; `<project>: <worktree>` windows grouped
    /// under a collapsible, sticky project header (`PaneSidebarWindowGrouping`).
    @ViewBuilder
    private var allWindows: some View {
        let controllers = roster.controllers.contains { $0 === controller }
            ? roster.controllers : [controller] + roster.controllers
        let byID = Dictionary(uniqueKeysWithValues: controllers.map { (ObjectIdentifier($0), $0) })
        let titled = controllers.map { (id: ObjectIdentifier($0), title: PaneSidebarText.windowTitle(of: $0)) }
        let matches = searchMatches(controllers, titles: Dictionary(uniqueKeysWithValues: titled.map { ($0.id, $0.title) }))
        // Searching: only windows with a matching pane, and nothing folded
        // away — a hit hidden inside a folded group would read as no hit.
        let sections = PaneSidebarWindowGrouping.sections(titled).compactMap { section in
            guard let matches else { return section }
            let windows = section.windows.filter { !(matches[$0.id]?.isEmpty ?? true) }
            return windows.isEmpty
                ? nil : PaneSidebarWindowGrouping.Section(project: section.project, windows: windows)
        }

        if matches != nil && sections.isEmpty {
            Text("No matching panes")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, SidePanelRow.labelInset)
                .padding(.vertical, SidePanelRow.verticalPadding)
        }

        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
            if let project = section.project, !isRail {
                let folded = matches == nil && state.foldedProjects.contains(project)
                Section {
                    if !folded {
                        ForEach(section.windows, id: \.id) { entry in
                            if let owner = byID[entry.id] {
                                windowGroup(owner, isThisWindow: owner === controller,
                                            label: entry.label, indent: PaneSidebarOutline.childIndent,
                                            matches: matches?[entry.id])
                                    .transition(PaneSidebarOutline.foldTransition)
                            }
                        }
                    }
                } header: {
                    PaneSidebarProjectHeader(
                        project: project,
                        windowCount: section.windows.count,
                        isFolded: folded,
                        isFirst: index == 0,
                        onFold: {
                            withAnimation(PaneSidebarOutline.foldAnimation) {
                                if folded { state.foldedProjects.remove(project) }
                                else { state.foldedProjects.insert(project) }
                            }
                        })
                }
            } else {
                ForEach(section.windows, id: \.id) { entry in
                    if let owner = byID[entry.id] {
                        if !isRail, index > 0 {
                            PaneSidebarDivider(isRail: false).padding(.bottom, 4)
                        }
                        windowGroup(owner, isThisWindow: owner === controller, label: entry.label,
                                    matches: matches?[entry.id])
                    }
                }
            }
        }
    }

    private func windowGroup(
        _ owner: BaseTerminalController,
        isThisWindow: Bool,
        label: String,
        indent: CGFloat = 0,
        matches: Set<ObjectIdentifier>? = nil
    ) -> some View {
        let folded = matches == nil && state.foldedWindows.contains(ObjectIdentifier(owner))
        return VStack(alignment: .leading, spacing: 0) {
            if isRail {
                PaneSidebarDivider(isRail: true)
            } else {
                PaneSidebarWindowHeader(
                    owner: owner,
                    title: label,
                    isThisWindow: isThisWindow,
                    indent: indent,
                    isFolded: folded,
                    isQuickKill: state.isQuickKill,
                    isDropTarget: isJoinTarget(owner),
                    onFold: {
                        withAnimation(PaneSidebarOutline.foldAnimation) {
                            if folded { state.foldedWindows.remove(ObjectIdentifier(owner)) }
                            else { state.foldedWindows.insert(ObjectIdentifier(owner)) }
                        }
                    })
            }
            if !folded || isRail {
                // In the outline, a window's panes are its CHILDREN: indented
                // under its header so the header reads as the parent.
                VStack(alignment: .leading, spacing: 0) {
                    windowSection(owner, isThisWindow: isThisWindow,
                                  indent: isRail ? 0 : indent + PaneSidebarOutline.childIndent,
                                  matches: matches)
                }
                .transition(PaneSidebarOutline.foldTransition)
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.preference(
                key: PaneSidebarGroupFrames.self,
                value: isThisWindow ? [] : [.init(
                    window: PaneDropWindowRef(owner),
                    frame: proxy.frame(in: .named(PaneSidebarGeometry.space)))])
        })
    }

    @ViewBuilder
    private func windowSection(
        _ owner: BaseTerminalController,
        isThisWindow: Bool,
        indent: CGFloat,
        matches: Set<ObjectIdentifier>? = nil
    ) -> some View {
        let tree = owner.surfaceTree
        let shown = { (pane: PaneView) in matches?.contains(ObjectIdentifier(pane)) ?? true }
        let visible = tree.visibleLeaves.filter(shown)
        let stashed = tree.stashedViews.filter(shown)
        // Only THIS window has a selection: another window's focus is not
        // focus here, and a highlighted row among its siblings read as a
        // "primary" pane with the others nested under it.
        let focused = isThisWindow ? (owner.publishedFocusedPane ?? visible.first) : nil

        ForEach(visible) { pane in
            row(pane, owner: owner, isStashed: false,
                isSelected: pane === focused, isThisWindow: isThisWindow, indent: indent)
        }

        if !stashed.isEmpty || (isThisWindow && dragSession.isDragging && stashed.isEmpty) {
            PaneSidebarDivider(isRail: isRail, indent: indent)
            if !isRail {
                HStack(alignment: .firstTextBaseline) {
                    SidePanelCaption(text: "Stashed")
                    Spacer()
                    if !stashed.isEmpty {
                        Text("\(stashed.count)")
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, SidePanelRow.labelInset + indent)
                .padding(.trailing, SidePanelRow.labelInset)
                .padding(.top, 10)
                .padding(.bottom, 5)
            }
        }

        let caret = isThisWindow ? stashCaretIndex : nil
        ForEach(Array(stashed.enumerated()), id: \.element.id) { index, pane in
            if caret == index { PaneSidebarCaret(isRail: isRail) }
            row(pane, owner: owner, isStashed: true, isSelected: false,
                isThisWindow: isThisWindow, indent: indent)
        }
        if let caret, caret >= stashed.count, !stashed.isEmpty { PaneSidebarCaret(isRail: isRail) }

        if isThisWindow && stashed.isEmpty && dragSession.isDragging {
            PaneSidebarEmptyStashSlot(isRail: isRail, isHot: caret != nil)
        }
    }

    private func row(
        _ pane: PaneView,
        owner: BaseTerminalController,
        isStashed: Bool,
        isSelected: Bool,
        isThisWindow: Bool,
        indent: CGFloat
    ) -> some View {
        PaneSidebarRow(
            pane: pane,
            owner: owner,
            isStashed: isStashed,
            isSelected: isSelected,
            isForeign: !isThisWindow,
            isRail: isRail,
            isQuickKill: state.isQuickKill,
            isBeingDragged: dragSession.isDragging(pane),
            indent: indent)
        .background(GeometryReader { proxy in
            Color.clear.preference(
                key: PaneSidebarRowFrames.self,
                value: isThisWindow && isStashed
                    ? [.init(id: pane.id, frame: proxy.frame(in: .named(PaneSidebarGeometry.space)))]
                    : [])
        })
    }

    // MARK: Search

    /// Searching: for each window, the panes the query matches. Nil when not
    /// searching (no query, or the rail, which has no room for the field).
    private func searchMatches(
        _ controllers: [BaseTerminalController],
        titles: [ObjectIdentifier: String]
    ) -> [ObjectIdentifier: Set<ObjectIdentifier>]? {
        let terms = PaneSidebarFilter.terms(state.filter)
        guard !terms.isEmpty, !isRail else { return nil }
        var result: [ObjectIdentifier: Set<ObjectIdentifier>] = [:]
        for owner in controllers {
            let id = ObjectIdentifier(owner)
            let tree = owner.surfaceTree
            let panes = tree.visibleLeaves + tree.stashedViews
            result[id] = Set(panes
                .filter { PaneSidebarFilter.matches(terms, in: [titles[id]] + PaneSidebarText.searchFields(of: $0)) }
                .map(ObjectIdentifier.init))
        }
        return result
    }

    /// Return in the search field: go to the first match, as clicking it would.
    private func revealFirstMatch() {
        let controllers = roster.controllers.contains { $0 === controller }
            ? roster.controllers : [controller] + roster.controllers
        let titled = controllers.map { (id: ObjectIdentifier($0), title: PaneSidebarText.windowTitle(of: $0)) }
        guard let matches = searchMatches(
            controllers, titles: Dictionary(uniqueKeysWithValues: titled.map { ($0.id, $0.title) })) else { return }
        let byID = Dictionary(uniqueKeysWithValues: controllers.map { (ObjectIdentifier($0), $0) })
        for section in PaneSidebarWindowGrouping.sections(titled) {
            for entry in section.windows {
                guard let owner = byID[entry.id], let hits = matches[entry.id] else { continue }
                let tree = owner.surfaceTree
                if let pane = (tree.visibleLeaves + tree.stashedViews).first(where: { hits.contains(ObjectIdentifier($0)) }) {
                    owner.revealPane(pane)
                    return
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Search windows and panes", text: $state.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($isSearchFocused)
                .onSubmit { revealFirstMatch() }
                // Escape clears a query, then gives the caret back.
                .onExitCommand {
                    if state.filter.isEmpty { isSearchFocused = false } else { state.filter = "" }
                }
            if !state.filter.isEmpty {
                Button(action: { state.filter = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, SidePanelRow.labelInset)
        .padding(.bottom, 6)
        .onChange(of: isSearchFocused) { focused in
            state.isFilterFocused = focused
            // The diff filter's yield: a terminal in this window keeps its
            // `focused` flag while the field has the caret, and its key
            // handling would eat Cmd-C/V before the field editor saw them.
            if focused { _ = controller.focusedSurface?.resignFirstResponder() }
        }
    }

    // MARK: Drop feedback

    /// Where the in-flight drag would land in this window's stash, if here.
    private var stashCaretIndex: Int? {
        guard case .stash(let window, let index) = dragSession.target,
              window == PaneDropWindowRef(controller) else { return nil }
        return index
    }

    private func isJoinTarget(_ owner: BaseTerminalController) -> Bool {
        guard case .joinWindow(let window) = dragSession.target else { return false }
        return window == PaneDropWindowRef(owner)
    }
}

// MARK: - Header button

/// A 24pt borderless glyph button, styled exactly like the viewer nav bar's
/// chevrons: the `.primary` glyph, no fill; pressing dims it. On/off is read
/// from the glyph (outline ⇄ filled, tilted ⇄ upright), never from a tint —
/// the one exception being trash's red, which says "this kills".
struct PaneSidebarHeaderButton: View {
    let symbol: PaneSidebarSymbol
    var tint: Color? = nil
    var rotation: Double = 0
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PaneSidebarSymbolView(symbol: symbol, size: 15)
                .rotationEffect(.degrees(rotation))
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: rotation)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Window group header (all-windows scope)

private struct PaneSidebarWindowHeader: View {
    @ObservedObject var owner: BaseTerminalController
    /// The window's name, or — inside a project group — its worktree.
    let title: String
    let isThisWindow: Bool
    /// Inside a project group: one outline level in.
    var indent: CGFloat = 0
    let isFolded: Bool
    let isQuickKill: Bool
    let isDropTarget: Bool
    let onFold: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: PaneSidebarOutline.chevronSpacing) {
            Button(action: onFold) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isFolded ? -90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: PaneSidebarOutline.chevronWidth, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFolded ? "Show this window’s panes" : "Hide this window’s panes")

            // The PARENT row: the window's own name, at the weight a sidebar
            // gives a group, with its panes indented beneath it.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .labelColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isThisWindow {
                    Text("This Window")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            Spacer(minLength: 4)

            if hasQuestion {
                PaneSidebarQuestionBadge(isOnAccent: false)
            } else {
                Text("\(owner.surfaceTree.count)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if showsKill {
                PaneSidebarKillButton(help: "Kill this window now") {
                    owner.window?.close()
                }
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, PaneSidebarOutline.headerLeading + indent)
        // With a trailing button, the SAME inset a row's button has, so the
        // header's × and its panes' ×s line up in one column.
        .padding(.trailing, showsKill ? PaneSidebarRow.trailingButtonInset : SidePanelRow.textInset)
        .background(
            RoundedRectangle(cornerRadius: SidePanelRow.cornerRadius, style: .continuous)
                .fill(isHovered && !isThisWindow ? Color.primary.opacity(0.06) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: SidePanelRow.cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: isDropTarget ? 2 : 0))
        .padding(.horizontal, SidePanelRow.fillInset)
        .contentShape(Rectangle())
        // Not `.onHover`: it blinks off for a frame when a fold re-lays out
        // the list (see `HoverTrackingView`).
        .background(HoverTrackingArea(isHovered: $isHovered))
        .onTapGesture {
            guard !isThisWindow else { onFold(); return }
            owner.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        .help(isThisWindow ? "This window" : "Raise this window")
    }

    private var hasQuestion: Bool {
        owner.surfaceTree.contains { $0.activityState == .needsInput }
    }

    private var showsKill: Bool { isQuickKill && !isThisWindow }
}

// MARK: - Project header (all-windows scope)

/// A `<project>: …` group's header: sticky at the top of the list while its
/// windows scroll under it, and folds them away. On Liquid Glass so rows
/// passing beneath stay legible (see `glassBackdrop`).
private struct PaneSidebarProjectHeader: View {
    let project: String
    let windowCount: Int
    let isFolded: Bool
    let isFirst: Bool
    let onFold: () -> Void

    var body: some View {
        Button(action: onFold) {
            HStack(spacing: PaneSidebarOutline.chevronSpacing) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isFolded ? -90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: PaneSidebarOutline.chevronWidth, height: 14)
                Text(project.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(windowCount)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, PaneSidebarOutline.headerLeading)
            .padding(.trailing, SidePanelRow.textInset)
            .padding(.horizontal, SidePanelRow.fillInset)
            .padding(.top, isFirst ? 4 : 10)
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassBackdrop()
        .help(isFolded ? "Show \(project)’s windows" : "Hide \(project)’s windows")
        .accessibilityLabel("\(project), \(windowCount) windows")
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Small pieces

/// The all-windows outline's geometry: a window header's disclosure chevron
/// sits where a row's label starts, and a window's panes are indented so
/// their icons line up under the window's name — the parent/child reading.
enum PaneSidebarOutline {
    /// Folding a group open or closed: a disclosure. The group's rows stay
    /// where they are and are revealed (or covered) from the top down while
    /// the rows below slide to their new place. Not a `.move`: that slid the
    /// rows up THROUGH the (transparent) header and whatever was above it.
    static let foldAnimation: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)
    /// This window ⇄ all windows: the same ease-out, a little longer — the
    /// whole list changes, not one group.
    static let scopeAnimation: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.3)
    /// How far a list slides as it leaves or arrives: enough to read as a
    /// direction, not a full page turn.
    static let scopeSlide: CGFloat = 48
    static let foldTransition: AnyTransition = .modifier(
        active: FoldReveal(fraction: 0), identity: FoldReveal(fraction: 1))
    static let chevronWidth: CGFloat = 12
    static let chevronSpacing: CGFloat = 5
    /// The header's leading edge inside its fill: the chevron's left edge
    /// lands on the rows' label inset.
    static var headerLeading: CGFloat { SidePanelRow.textInset }
    /// How far a window's pane rows are indented: one chevron and its gap.
    static var childIndent: CGFloat { chevronWidth + chevronSpacing }
}

struct PaneSidebarDivider: View {
    let isRail: Bool
    var indent: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 1)
            .padding(.leading, isRail ? 10 : SidePanelRow.labelInset + indent)
            .padding(.trailing, isRail ? 10 : SidePanelRow.labelInset)
            .padding(.vertical, isRail ? 5 : 0)
            .padding(.top, isRail ? 0 : 8)
    }
}

/// The insertion line where a drop would land in the stash.
private struct PaneSidebarCaret: View {
    let isRail: Bool

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
                .frame(width: 8, height: 8)
            Rectangle()
                .fill(Color(nsColor: .controlAccentColor))
                .frame(height: 2)
        }
        .frame(height: 8)
        .padding(.horizontal, isRail ? 6 : SidePanelRow.fillInset + 2)
        .padding(.vertical, -3)
        .allowsHitTesting(false)
    }
}

/// While a drag is in flight and nothing is stashed: the target, made visible.
private struct PaneSidebarEmptyStashSlot: View {
    let isRail: Bool
    let isHot: Bool

    var body: some View {
        let accent = Color(nsColor: .controlAccentColor)
        Text(isRail ? "" : "Drop to stash — it keeps running")
            .font(.system(size: 11))
            .foregroundStyle(isHot ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .frame(height: isRail ? 28 : 40)
            .background(
                RoundedRectangle(cornerRadius: SidePanelRow.cornerRadius, style: .continuous)
                    .fill(isHot ? accent.opacity(0.08) : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: SidePanelRow.cornerRadius, style: .continuous)
                    .strokeBorder(isHot ? accent : Color.primary.opacity(0.3),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
            .padding(.horizontal, isRail ? 6 : SidePanelRow.fillInset)
            .padding(.vertical, 4)
            .allowsHitTesting(false)
    }
}

/// The `needs_input` badge — the human label, never the machine token.
struct PaneSidebarQuestionBadge: View {
    /// On the accent selection pill the badge inverts, or it would vanish.
    let isOnAccent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        let accent = Color(nsColor: .controlAccentColor)
        Text("question")
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(height: 15)
            .foregroundStyle(isOnAccent ? accent : .white)
            .background(Capsule().fill(isOnAccent ? Color.white : accent))
            .background(
                // A soft ring that breathes, so a question in an otherwise
                // quiet list is the thing that draws the eye.
                Capsule()
                    .stroke(accent.opacity(pulse ? 0.22 : 0), lineWidth: 3)
                    .padding(-1.5))
            .onAppear {
                guard !reduceMotion, !isOnAccent else { return }
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
            .accessibilityLabel("Has a question")
    }
}

/// Trash mode's red ×.
struct PaneSidebarKillButton: View {
    var size: CGFloat = 18
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Color(nsColor: .systemRed)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Shimmer

/// A busy pane's icon: the glyph drawn dim, with a brighter band sweeping
/// across it. The whole busy signal — no spinner, no glow (both were tried
/// in the design mock and dropped). See `PaneSidebarShimmer` for the timing.
struct PaneSidebarGlyph<Content: View>: View {
    let isBusy: Bool
    let color: Color
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isBusy && !reduceMotion {
            TimelineView(.animation) { context in
                let progress = PaneSidebarShimmer.bandPosition(at: context.date.timeIntervalSinceReferenceDate)
                // A SOLID base under the band, so the glyph is never partly
                // blank — the band only ever adds light on top.
                content
                    .foregroundStyle(color.opacity(PaneSidebarShimmer.baseOpacity))
                    .overlay {
                        GeometryReader { proxy in
                            let width = proxy.size.width
                            LinearGradient(
                                stops: [
                                    .init(color: color.opacity(0), location: 0.35),
                                    .init(color: color, location: 0.5),
                                    .init(color: color.opacity(0), location: 0.65),
                                ],
                                startPoint: UnitPoint(x: 0, y: 0.35),
                                endPoint: UnitPoint(x: 1, y: 0.65))
                            .frame(width: width * PaneSidebarShimmer.bandWidthFactor)
                            .offset(x: PaneSidebarShimmer.offset(position: progress, width: width))
                        }
                        .mask(content)
                        .allowsHitTesting(false)
                    }
            }
            .accessibilityLabel("Busy")
        } else {
            content.foregroundStyle(color)
        }
    }
}

/// The shimmer's timing and geometry, pure so it is testable.
enum PaneSidebarShimmer {
    /// One cycle: a sweep, then a short rest before the next.
    static let period: TimeInterval = 1.4
    /// The part of the period the band spends moving.
    static let sweepFraction: Double = 0.8
    /// The band layer is this many times the glyph's width, so that at either
    /// end of its travel the bright band is fully off the glyph.
    static let bandWidthFactor: CGFloat = 3
    /// The glyph's base under the band. Low enough that the band reads at a
    /// glance on a 14pt glyph: at 0.62 it swept from 62% to 100% and, at
    /// that size, looked like no busy indication at all.
    static let baseOpacity: Double = 0.3

    /// 1 = band parked off the LEADING edge, 0 = off the TRAILING edge; the
    /// sweep runs 1 → 0 (left to right), eased, then rests at 0.
    static func bandPosition(at time: TimeInterval) -> Double {
        let phase = time.truncatingRemainder(dividingBy: period) / period
        let t = Swift.min(1, phase / sweepFraction)
        let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
        return 1 - eased
    }

    /// The band layer's x offset for a position, for a glyph `width` wide.
    /// At 1 the band's bright middle sits half a glyph off the leading edge;
    /// at 0, half a glyph off the trailing edge.
    static func offset(position: Double, width: CGFloat) -> CGFloat {
        -(bandWidthFactor - 1) * width * CGFloat(position)
    }
}

// MARK: - Geometry plumbing

/// Row and group frames, reported by the SwiftUI list and read by the AppKit
/// host to answer the drag session's drop geometry.
@MainActor
final class PaneSidebarGeometry: ObservableObject {
    static let space = "paneSidebar"

    var rowFrames: [PaneSidebarRowFrames.Entry] = []
    var groupFrames: [PaneSidebarGroupFrames.Entry] = []
}

struct PaneSidebarRowFrames: PreferenceKey {
    struct Entry: Equatable {
        let id: UUID
        let frame: CGRect
    }

    static let defaultValue: [Entry] = []
    static func reduce(value: inout [Entry], nextValue: () -> [Entry]) {
        value.append(contentsOf: nextValue())
    }
}

struct PaneSidebarGroupFrames: PreferenceKey {
    struct Entry: Equatable {
        let window: PaneDropWindowRef
        let frame: CGRect

        static func == (lhs: Entry, rhs: Entry) -> Bool {
            lhs.window == rhs.window && lhs.frame == rhs.frame
        }
    }

    static let defaultValue: [Entry] = []
    static func reduce(value: inout [Entry], nextValue: () -> [Entry]) {
        value.append(contentsOf: nextValue())
    }
}

private struct PaneSidebarInteractiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether rows mount their AppKit click/drag view. Always true in the
    /// app; a still render (`ImageRenderer`, which can only draw AppKit views
    /// as placeholders) turns it off to see the row underneath.
    var paneSidebarInteractive: Bool {
        get { self[PaneSidebarInteractiveKey.self] }
        set { self[PaneSidebarInteractiveKey.self] = newValue }
    }
}

private struct PaneSidebarEmphasizedKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the sidebar's window is key: AppKit draws a selected sidebar
    /// row with the accent fill only then (see `SidePanelRow.fill`).
    var paneSidebarEmphasized: Bool {
        get { self[PaneSidebarEmphasizedKey.self] }
        set { self[PaneSidebarEmphasizedKey.self] = newValue }
    }
}

// MARK: - The roster of windows

/// Every terminal window with a pane sidebar, front to back, and a single
/// change signal for "some window's panes changed" — what the all-windows
/// scope observes so another window's rows stay live.
@MainActor
final class PaneRoster: ObservableObject {
    static let shared = PaneRoster()

    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PaneRoster.shared.changed() }
            })
        }
    }

    /// Terminal windows with a sidebar, frontmost first.
    var controllers: [BaseTerminalController] {
        NSApp.orderedWindows.compactMap { window in
            guard let controller = window.windowController as? BaseTerminalController,
                  controller.hasPaneSidebar,
                  window.isVisible
            else { return nil }
            return controller
        }
    }

    /// Something about some window's panes changed.
    func changed() {
        objectWillChange.send()
    }
}

extension PaneSidebarText {
    /// A window's name as a person would say it: a title the user set, else
    /// what its focused pane is called — never the raw window title, which
    /// carries the activity suffix ("(question)") and, for a pane that never
    /// set one, the placeholder ghost. What the all-windows scope sorts and
    /// groups by.
    /// Everything a pane's row says about it, for the all-windows search:
    /// its title, banner, and working directory or location (both as shown
    /// and in full, so `~/git` and `/Users/me/git` each find it).
    @MainActor
    static func searchFields(of pane: PaneView) -> [String?] {
        let pwd = pane.surfaceView?.pwd
        let location = pane.viewerView?.location
        return [
            title(pane.title, pwd: pwd, kind: pane.surfaceView != nil ? "Terminal" : "Viewer"),
            bannerLine(pane.paneBanner),
            pwd, pwd?.abbreviatedPath,
            location, location?.abbreviatedPath,
        ]
    }

    @MainActor
    static func windowTitle(of owner: BaseTerminalController) -> String {
        if let override = owner.windowTitleOverride ?? owner.titleOverride, !override.isEmpty {
            return override
        }
        let pane = owner.publishedFocusedPane ?? owner.surfaceTree.visibleLeaves.first
        return title(pane?.title ?? "", pwd: pane?.surfaceView?.pwd, kind: "Window")
    }
}

/// Shows the top `fraction` of its content, cut off at a straight edge: the
/// fold transition's mask.
struct FoldReveal: ViewModifier, Animatable {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        content
            .mask(alignment: .top) {
                GeometryReader { proxy in
                    Rectangle().frame(height: max(0, proxy.size.height * fraction))
                }
            }
            .opacity(fraction > 0 ? 1 : 0)
    }
}

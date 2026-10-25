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
    @ObservedObject private var rowDrag = PaneSidebarRowDrag.shared

    /// Laid out as the rail (tiles) rather than full rows.
    let isRail: Bool
    /// The flat expanded panel (vs the raised rail card).
    let isFlat: Bool
    /// The window is wide enough for the expanded panel (the rail's expand
    /// button is off otherwise).
    var canExpand: Bool = true

    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.paneSidebarInteractive) private var isInteractive

    var body: some View {
        content
            .overlay(alignment: .topLeading) { ghost }
            .onPreferenceChange(PaneSidebarRowFrames.self) { frames in
                geometry.rowFrames = frames
                if let pane = rowDrag.pane,
                   let frame = frames.first(where: { $0.id == pane.id })?.frame,
                   frame != rowDrag.frame {
                    rowDrag.frame = frame
                }
            }
            .onPreferenceChange(PaneSidebarGroupFrames.self) { geometry.groupFrames = $0 }
            .onPreferenceChange(PaneSidebarTrayFrame.self) { geometry.trayFrame = $0 }
            .font(.system(size: 12))
            .environment(\.paneSidebarEmphasized, controlActiveState == .key)
    }

    /// Glass panes: the header is no band of its own — just the caption and
    /// buttons on the panel, as in the mock — so the list starts BELOW it
    /// rather than scrolling under a backdrop.
    @ViewBuilder
    private var content: some View {
        if isRail {
            // The rail is its tiles under one button: expand. The header's
            // other buttons are there once it is expanded.
            VStack(spacing: 0) {
                PaneSidebarHeaderButton(
                    symbol: .sidebar(expanded: false),
                    help: canExpand ? "Expand the sidebar" : "Too narrow to expand — widen the window"
                ) { controller.setPaneSidebarExpanded(true, cause: "rail button") }
                    .disabled(!canExpand)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, Self.toggleLeading)
                    .frame(height: 34)
                list
            }
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

    // MARK: Dragged row

    /// The row being dragged, drawn over the list where the pointer has it:
    /// at its own place, moved only up or down, never sideways, and kept
    /// inside the bar. Let go, it glides to where it landed. The row in the
    /// list leaves its gap meanwhile (`PaneSidebarShift.isLifted`).
    @ViewBuilder
    private var ghost: some View {
        if let pane = rowDrag.pane, let frame = rowDrag.frame,
           controller.surfaceTree.contains(where: { $0 === pane }) {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .named(PaneSidebarGeometry.space)).origin
                let top = rowDrag.isSettling ? frame.minY : frame.minY + rowDrag.dy
                let y = Swift.min(Swift.max(top - origin.y, 0), Swift.max(0, proxy.size.height - frame.height))
                PaneSidebarRow(
                    pane: pane, owner: controller,
                    isStashed: controller.surfaceTree.isStashed(pane),
                    isSelected: pane === controller.publishedFocusedPane,
                    isForeign: false, isRail: isRail, isBeingDragged: false)
                    .environment(\.paneSidebarInteractive, false)
                    .frame(width: frame.width, height: frame.height)
                    // Solid under the glass while it is held, so it reads as
                    // on top of the rows it passes rather than mixed with them.
                    .background {
                        RoundedRectangle(
                            cornerRadius: isRail ? PaneSidebarTileButton.cornerRadius : SidePanelRow.cornerRadius,
                            style: .continuous)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(rowDrag.isSettling ? 0 : 0.92))
                            .overlay(
                                RoundedRectangle(
                                    cornerRadius: isRail ? PaneSidebarTileButton.cornerRadius : SidePanelRow.cornerRadius,
                                    style: .continuous)
                                    .fill(Color.primary.opacity(rowDrag.isSettling ? 0 : 0.06)))
                            .padding(.horizontal, isRail ? (frame.width - 30) / 2 : SidePanelRow.fillInset)
                            .padding(.vertical, isRail ? (frame.height - 30) / 2 : 0.5)
                    }
                    .scaleEffect(rowDrag.isSettling ? 1 : 1.04)
                    .shadow(color: .black.opacity(rowDrag.isSettling ? 0 : 0.3), radius: 6, y: 3)
                    .offset(x: frame.minX - origin.x, y: y)
                    .animation(rowDrag.isSettling ? PaneSidebarRowDrag.settleAnimation : nil, value: y)
                    .animation(PaneSidebarRowDrag.settleAnimation, value: rowDrag.isSettling)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Header

    private var headerContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                // The collapse button first, where the rail's expand button
                // is: centered on the rail's width, so toggling never moves
                // it (`toggleLeading`).
                PaneSidebarHeaderButton(
                    symbol: .sidebar(expanded: true),
                    help: "Collapse the sidebar to icons"
                ) { controller.setPaneSidebarExpanded(false, cause: "header button") }
                caption.padding(.leading, 4)
                Spacer(minLength: 4)
                headerButtons
            }
            .padding(.leading, Self.toggleLeading)
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
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SidePanelCaption(text: state.showsAllWindows ? "All windows" : "Panes")
            if state.showsAllWindows {
                // How many WINDOWS, styled as a project header's count.
                PaneSidebarCount(value: allControllers.count)
                    .accessibilityLabel("\(allControllers.count) windows")
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
    }

    /// The collapse/expand button's leading inset: centered on the rail card,
    /// in both modes, so it stays put when toggled.
    static let toggleLeading: CGFloat = (PaneSidebarState.railCardWidth - 24) / 2

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
        if state.showsAllWindows {
            scrollingWindows
        } else {
            thisWindowList
        }
    }

    /// This window: its panes, then — right after the last of them, under a
    /// divider — the tray of stashed panes, in one scrolling list. Two lists,
    /// and a drag moves a pane within either or across: into the tray
    /// stashes it, out restores. (The tray was first anchored at the bottom
    /// of the bar, which left it far from the panes it is for.)
    @ViewBuilder
    private var thisWindowList: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            paneRows(controller, isThisWindow: true, indent: 0)
            tray(controller, isThisWindow: true, indent: 0)
        }
        .padding(.vertical, SidePanelRow.fillInset)
        if isInteractive {
            ScrollView(.vertical) { content }
        } else {
            content.frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var scrollingWindows: some View {
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

    private var listContent: some View { allWindows }

    /// Every terminal window with a sidebar, this one included even before
    /// it is visible.
    private var allControllers: [BaseTerminalController] {
        let controllers = roster.controllers
        return controllers.contains { $0 === controller } ? controllers : [controller] + controllers
    }

    /// Every window, sorted by name; `<project>: <worktree>` windows grouped
    /// under a collapsible, sticky project header (`PaneSidebarWindowGrouping`).
    @ViewBuilder
    private var allWindows: some View {
        let controllers = allControllers
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
        let id = ObjectIdentifier(owner)
        let folded = PaneSidebarState.isWindowFolded(
            isThisWindow: isThisWindow, isToggled: state.toggledWindows.contains(id), isSearching: matches != nil)
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
                    isDropTarget: isJoinTarget(owner),
                    onFold: {
                        withAnimation(PaneSidebarOutline.foldAnimation) {
                            if state.toggledWindows.contains(id) { state.toggledWindows.remove(id) }
                            else { state.toggledWindows.insert(id) }
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
        .background {
            // Only while a drag is in flight: the frames are in the panel's
            // space, outside the scroll view, so they change on every frame
            // of a scroll — and each change sends SwiftUI through a rebuild
            // of the window's key-view loop. Measured as the largest cost
            // left in scrolling a fully expanded list.
            if dragSession.isDragging && !isThisWindow {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: PaneSidebarGroupFrames.self,
                        value: [.init(
                            window: PaneDropWindowRef(owner),
                            frame: proxy.frame(in: .named(PaneSidebarGeometry.space)))])
                }
            }
        }
    }

    /// A window's panes and tray, one after the other: a group of the
    /// all-windows list.
    @ViewBuilder
    private func windowSection(
        _ owner: BaseTerminalController,
        isThisWindow: Bool,
        indent: CGFloat,
        matches: Set<ObjectIdentifier>? = nil
    ) -> some View {
        paneRows(owner, isThisWindow: isThisWindow, indent: indent, matches: matches)
        tray(owner, isThisWindow: isThisWindow, indent: indent, matches: matches)
    }

    /// A window's grid panes, in the sidebar's order (`PaneSidebarOrder`).
    @ViewBuilder
    private func paneRows(
        _ owner: BaseTerminalController,
        isThisWindow: Bool,
        indent: CGFloat,
        matches: Set<ObjectIdentifier>? = nil
    ) -> some View {
        let shown = { (pane: PaneView) in matches?.contains(ObjectIdentifier(pane)) ?? true }
        let visible = owner.paneSidebarPanes.filter(shown)
        // Only THIS window has a selection: another window's focus is not
        // focus here, and a highlighted row among its siblings read as a
        // "primary" pane with the others nested under it.
        let focused = isThisWindow ? (owner.publishedFocusedPane ?? visible.first) : nil
        let drag = isThisWindow ? dragLayout : nil
        let slide = slideIndices(owner, matches: matches, drag: drag)

        ForEach(Array(visible.enumerated()), id: \.element.id) { index, pane in
            row(pane, owner: owner, isStashed: false,
                isSelected: pane === focused, isThisWindow: isThisWindow, indent: indent)
                .modifier(PaneSidebarShift(
                    rows: slide.map { PaneSidebarOrder.shift(index: index, source: $0.source, target: $0.target) } ?? 0,
                    height: drag?.height ?? 0,
                    isLifted: rowDrag.pane === pane || (slide != nil && index == slide?.source),
                    isDragging: drag != nil))
                .background { rowFrameReader(pane, isStashed: false, isThisWindow: isThisWindow) }
        }
    }

    /// A drag over this window's sidebar as one sequence — the pane list, the
    /// tray's header (its divider and caption), then the tray — for the
    /// slide (`PaneSidebarOrder.shift`): where the dragged row is in it, and
    /// where it would land, of the sequence without it. One sequence, so a
    /// row crossing from the list into the tray (or back) slides the header
    /// with the rows between, and the list's last row never runs over the
    /// divider. Nil when nothing is dragged over this sidebar.
    private func slideIndices(
        _ owner: BaseTerminalController,
        matches: Set<ObjectIdentifier>?,
        drag: DragLayout?
    ) -> (source: Int?, target: Int?)? {
        guard let drag, drag.isOverSidebar else { return nil }
        let shown = { (pane: PaneView) in matches?.contains(ObjectIdentifier(pane)) ?? true }
        let visible = owner.paneSidebarPanes.filter(shown)
        let stashed = owner.surfaceTree.stashedViews.filter(shown)
        let inList = visible.firstIndex { $0 === drag.pane }
        let inTray = stashed.firstIndex { $0 === drag.pane }
        let source = inList ?? inTray.map { visible.count + 1 + $0 }
        let listCount = visible.count - (inList == nil ? 0 : 1)
        let target = drag.paneTarget ?? drag.stashTarget.map { listCount + 1 + $0 }
        return (source, target)
    }

    /// Where a tray item — `nil` for the header, else a stashed row's index —
    /// is in `slideIndices`' sequence.
    private func trayIndex(_ owner: BaseTerminalController, matches: Set<ObjectIdentifier>?, row: Int?) -> Int {
        let shown = { (pane: PaneView) in matches?.contains(ObjectIdentifier(pane)) ?? true }
        let listCount = owner.paneSidebarPanes.filter(shown).count
        return row.map { listCount + 1 + $0 } ?? listCount
    }

    /// A window's tray: a divider, then its stashed panes. In this window's
    /// list it is always there (it is a drop target); in another's, only
    /// when it holds something.
    @ViewBuilder
    private func tray(
        _ owner: BaseTerminalController,
        isThisWindow: Bool,
        indent: CGFloat,
        matches: Set<ObjectIdentifier>? = nil
    ) -> some View {
        let shown = { (pane: PaneView) in matches?.contains(ObjectIdentifier(pane)) ?? true }
        let stashed = owner.surfaceTree.stashedViews.filter(shown)
        let drag = isThisWindow ? dragLayout : nil
        let slide = slideIndices(owner, matches: matches, drag: drag)
        let source = slide?.source.map { $0 - trayIndex(owner, matches: matches, row: 0) }
        let slides = { (item: Int) in
            slide.map { PaneSidebarOrder.shift(index: item, source: $0.source, target: $0.target) } ?? 0
        }

        if !stashed.isEmpty || (isThisWindow && (dragSession.isDragging || !state.showsAllWindows)) {
          VStack(alignment: .leading, spacing: 0) {
            PaneSidebarDivider(isRail: isRail, indent: indent)
            if !isRail {
                HStack(alignment: .firstTextBaseline) {
                    SidePanelCaption(text: "Stashed")
                    Spacer()
                    if !stashed.isEmpty {
                        PaneSidebarCount(value: stashed.count)
                    }
                }
                .padding(.leading, SidePanelRow.labelInset + indent)
                .padding(.trailing, SidePanelRow.labelInset)
                .padding(.top, 10)
                .padding(.bottom, 5)
            }
          }
          // The header slides with the rows (`slideIndices`); its frame is
          // read outside the slide, as the rows' are.
          .modifier(PaneSidebarShift(
              rows: slides(trayIndex(owner, matches: matches, row: nil)),
              height: drag?.height ?? 0, isLifted: false, isDragging: drag != nil))
          .background {
              // Where the tray begins, for the drop geometry: only during a
              // drag, as for the rows.
              if drag != nil {
                  GeometryReader { proxy in
                      Color.clear.preference(
                          key: PaneSidebarTrayFrame.self,
                          value: proxy.frame(in: .named(PaneSidebarGeometry.space)))
                  }
              }
          }
        }

        ForEach(Array(stashed.enumerated()), id: \.element.id) { index, pane in
            row(pane, owner: owner, isStashed: true, isSelected: false,
                isThisWindow: isThisWindow, indent: indent)
                .modifier(PaneSidebarShift(
                    rows: slides(trayIndex(owner, matches: matches, row: index)),
                    height: drag?.height ?? 0,
                    isLifted: rowDrag.pane === pane || (slide != nil && index == source),
                    isDragging: drag != nil))
                .background { rowFrameReader(pane, isStashed: true, isThisWindow: isThisWindow) }
        }

        // An empty tray is still somewhere to drop: a slot that says so,
        // always there in this window's list, lit while a drag would land in
        // it. It stays put; the rows open the gap above it.
        if stashed.isEmpty && isThisWindow {
            PaneSidebarEmptyStashSlot(isRail: isRail, isHot: drag?.stashTarget != nil,
                                      isDragging: drag != nil)
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
            isBeingDragged: dragSession.isDragging(pane),
            indent: indent)

    }

    /// Reports a row's frame for the drop geometry — only during a drag, for
    /// the same reason as a group's frame. Attached OUTSIDE the row's slide
    /// (`PaneSidebarShift`): a background takes its content's layout frame,
    /// which an offset does not move, where a reader inside the offset moves
    /// with it. The drop index is read off the rows as laid out, so it never
    /// moves under the pointer as they slide (read inside, a row sliding into
    /// the gap reported the gap's place, and the index chased it).
    @ViewBuilder
    private func rowFrameReader(_ pane: PaneView, isStashed: Bool, isThisWindow: Bool) -> some View {
        if (dragSession.isDragging || rowDrag.pane != nil) && isThisWindow {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PaneSidebarRowFrames.self,
                    value: [.init(id: pane.id, frame: proxy.frame(in: .named(PaneSidebarGeometry.space)),
                                  isStashed: isStashed)])
            }
        }
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
        let controllers = allControllers
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

    /// System Settings' sidebar search: a soft capsule, a magnifier, a
    /// "Search" placeholder, a clear button once there is a query.
    ///
    /// The text is a borderless `NSTextField`, which draws its placeholder
    /// and edits its text in the same rect. A SwiftUI `TextField` drew the
    /// placeholder a point off from the field editor (it jumped when the
    /// field took the caret), and an unbezeled `NSSearchField` moved its text
    /// under the magnifier while editing.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            PaneSidebarSearchField(
                text: $state.filter,
                onSubmit: revealFirstMatch,
                onFocusChange: { focused in
                    // The diff filter's yield: a terminal in this window keeps
                    // its `focused` flag while the field has the caret, and its
                    // key handling would eat Cmd-C/V before the field editor
                    // saw them.
                    if focused { _ = controller.focusedSurface?.resignFirstResponder() }
                })
            if !state.filter.isEmpty {
                Button(action: { state.filter = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        .padding(.horizontal, SidePanelRow.fillInset)
        .padding(.bottom, 6)
    }

    // MARK: Drop feedback

    /// The in-flight drag as this window's list draws it: which pane, where
    /// it would land in either list, and how far the rows slide for it.
    private struct DragLayout {
        let pane: PaneView
        /// Its index in the pane list, if it would land there.
        let paneTarget: Int?
        /// Its index in the tray, if it would land there.
        let stashTarget: Int?
        /// The dragged row's height: how far every row it passes slides.
        let height: CGFloat

        /// Released now, it would land in this sidebar: the rows make room.
        /// Anywhere else they stay put, the dragged row dimmed in place.
        var isOverSidebar: Bool { paneTarget != nil || stashTarget != nil }
    }

    private var dragLayout: DragLayout? {
        guard let pane = dragSession.pane else { return nil }
        let here = PaneDropWindowRef(controller)
        var paneTarget: Int?, stashTarget: Int?
        switch dragSession.target {
        case .sidebarOrder(let window, let index) where window == here: paneTarget = index
        case .stash(let window, let index) where window == here: stashTarget = index
        default: break
        }
        // The dragged row's own height, else a row of this list's (a pane
        // from another window), else a row's usual height.
        let frames = geometry.rowFrames
        let height = frames.first { $0.id == pane.id }?.frame.height
            ?? frames.first?.frame.height
            ?? (isRail ? 34 : 38)
        return .init(pane: pane, paneTarget: paneTarget, stashTarget: stashTarget, height: height)
    }

    private func isJoinTarget(_ owner: BaseTerminalController) -> Bool {
        guard case .joinWindow(let window) = dragSession.target else { return false }
        return window == PaneDropWindowRef(owner)
    }
}

// MARK: - Header button

/// A 24pt borderless glyph button, styled exactly like the viewer nav bar's
/// chevrons: the `.primary` glyph, no fill; pressing dims it. On/off is read
/// from the glyph (outline ⇄ filled), never from a tint.
struct PaneSidebarHeaderButton: View {
    let symbol: PaneSidebarSymbol
    var tint: Color? = nil
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PaneSidebarSymbolView(symbol: symbol, size: 15)
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
                PaneSidebarCount(value: owner.surfaceTree.count)
            }
        }
        .padding(.vertical, 6)
        .padding(.leading, PaneSidebarOutline.headerLeading + indent)
        .padding(.trailing, SidePanelRow.textInset)
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
                PaneSidebarCount(value: windowCount)
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

/// A group's count — panes, windows, stashed panes — in the sidebar's one
/// style for it.
struct PaneSidebarCount: View {
    let value: Int

    var body: some View {
        Text("\(value)")
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.tertiary)
    }
}

/// A hairline between sections — above all, the tray's: the line a pane is
/// dragged below to stash it, so it must read on glass (at 9% it all but
/// vanished there).
struct PaneSidebarDivider: View {
    let isRail: Bool
    var indent: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.22))
            .frame(height: 1)
            .padding(.leading, isRail ? 8 : SidePanelRow.labelInset + indent)
            .padding(.trailing, isRail ? 8 : SidePanelRow.labelInset)
            .padding(.vertical, isRail ? 7 : 0)
            .padding(.top, isRail ? 0 : 8)
    }
}

/// A row of the sidebar while a pane is dragged over it: slid `rows` rows
/// of `height` to make room (`PaneSidebarOrder.shift`), or — the dragged row
/// itself, over the sidebar — lifted out, leaving its gap. The slide is a
/// short bounded animation, and none at all once the drag ends: the drop
/// re-lays the list out where the rows were already drawn, so nothing moves.
private struct PaneSidebarShift: ViewModifier {
    let rows: Int
    let height: CGFloat
    let isLifted: Bool
    let isDragging: Bool

    static let animation: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.2)

    func body(content: Content) -> some View {
        content
            .opacity(isLifted ? 0 : 1)
            .offset(y: CGFloat(rows) * height)
            .animation(isDragging ? Self.animation : nil, value: rows)
            .animation(isDragging ? Self.animation : nil, value: isLifted)
    }
}

/// An empty tray: the place to drop a pane to stash it, made visible. Faint
/// at rest — a dashed well with a tray glyph (and, expanded, what it is for)
/// — brighter while a pane is dragged, and lit in the accent when the drag
/// would land in it.
private struct PaneSidebarEmptyStashSlot: View {
    let isRail: Bool
    let isHot: Bool
    var isDragging: Bool = false

    var body: some View {
        let accent = Color(nsColor: .controlAccentColor)
        let ink: AnyShapeStyle = isHot ? AnyShapeStyle(accent)
            : isDragging ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary)
        HStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: isRail ? 12 : 11, weight: .medium))
            if !isRail {
                Text(isDragging ? "Drop to stash — it keeps running" : "Drag a pane here to stash it")
                    .font(.system(size: 11))
            }
        }
        .foregroundStyle(ink)
        .frame(maxWidth: .infinity)
        .frame(height: isRail ? 30 : 36)
        .background(
            RoundedRectangle(cornerRadius: SidePanelRow.cornerRadius, style: .continuous)
                .fill(isHot ? accent.opacity(0.10) : .clear))
        .overlay(
            RoundedRectangle(cornerRadius: SidePanelRow.cornerRadius, style: .continuous)
                .strokeBorder(isHot ? accent : Color.primary.opacity(isDragging ? 0.3 : 0.14),
                              style: StrokeStyle(lineWidth: isHot ? 1.5 : 1, dash: [4, 3])))
        .padding(.horizontal, isRail ? 7 : SidePanelRow.fillInset)
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.15), value: isHot)
        .help("Drag a pane here to stash it — out of the grid, still running")
        .allowsHitTesting(false)
    }
}

/// The `needs_input` badge — the human label, never the machine token.
struct PaneSidebarQuestionBadge: View {
    /// On the accent selection pill the badge inverts, or it would vanish.
    let isOnAccent: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let accent = Color(nsColor: .controlAccentColor)
        Text("question")
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(height: 15)
            .foregroundStyle(isOnAccent ? accent : .white)
            .background(Capsule().fill(isOnAccent ? Color.white : accent))
            .background {
                // A soft ring that breathes, so a question in an otherwise
                // quiet list is the thing that draws the eye. On Core
                // Animation — see `PaneSidebarShimmerLayer` for why.
                if !reduceMotion && !isOnAccent {
                    PaneSidebarPulseRing(color: accent).padding(-1.5)
                }
            }
            .accessibilityLabel("Has a question")
    }
}

// MARK: - Shimmer

/// A busy pane's icon: the glyph drawn dim, with a brighter band sweeping
/// across it. The whole busy signal — no spinner, no glow (both were tried
/// in the design mock and dropped). See `PaneSidebarShimmer` for the timing.
///
/// The sweep is a Core Animation layer under a mask of the glyph, drawn once
/// (`PaneSidebarShimmerLayer` says why it is not SwiftUI). `maskKey` names
/// the glyph, so the mask is redrawn only when the glyph changes.
struct PaneSidebarGlyph<Content: View>: View {
    let isBusy: Bool
    let color: Color
    let maskKey: AnyHashable
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if isBusy && !reduceMotion {
            // The glyph only sizes the slot; the layer draws it.
            content
                .hidden()
                .overlay {
                    PaneSidebarShimmerLayer(color: color, maskKey: maskKey) { size, scale in
                        let renderer = ImageRenderer(content: content
                            .foregroundStyle(Color.black)
                            .frame(width: size.width, height: size.height))
                        renderer.scale = scale
                        return renderer.cgImage
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
    /// This window's tray divider, during a drag.
    var trayFrame: CGRect?
}

struct PaneSidebarRowFrames: PreferenceKey {
    struct Entry: Equatable {
        let id: UUID
        let frame: CGRect
        /// A tray row (vs a row of the pane list).
        let isStashed: Bool
    }

    static let defaultValue: [Entry] = []
    static func reduce(value: inout [Entry], nextValue: () -> [Entry]) {
        value.append(contentsOf: nextValue())
    }
}

struct PaneSidebarTrayFrame: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        value = value ?? nextValue()
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
    /// its name, its own title (which a banner title hides), banner, and
    /// working directory or location (both as shown and in full, so `~/git`
    /// and `/Users/me/git` each find it).
    @MainActor
    static func searchFields(of pane: PaneView) -> [String?] {
        let pwd = pane.surfaceView?.pwd
        let location = pane.viewerView?.location
        return [
            pane.displayLabel, pane.title,
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

/// The all-windows search's text: a borderless `NSTextField` (see
/// `searchField`). Return reports a submit; Escape clears the query, and on
/// an empty field gives the caret back.
struct PaneSidebarSearchField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search"
        field.font = .systemFont(ofSize: 14)
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search windows and panes")
        field.toolTip = "Search windows and panes — every word must match"
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PaneSidebarSearchField

        init(_ parent: PaneSidebarSearchField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ note: Notification) { parent.onFocusChange(true) }
        func controlTextDidEndEditing(_ note: Notification) { parent.onFocusChange(false) }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if parent.text.isEmpty {
                    control.window?.makeFirstResponder(nil)
                } else {
                    (control as? NSTextField)?.stringValue = ""
                    parent.text = ""
                }
                return true
            default:
                return false
            }
        }
    }
}

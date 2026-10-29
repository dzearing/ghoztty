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
    @ObservedObject private var dragSession = PaneDragSession.shared
    @ObservedObject private var rowDrag = PaneSidebarRowDrag.shared
    /// Not observed here: its once-per-drag changes come through `state`,
    /// live windows only (`PaneSidebarState`), so starting a drag redraws
    /// the list it is in — not every window's.
    private var itemDrag: PaneSidebarItemDrag { .shared }

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
            .onPreferenceChange(PaneSidebarItemFrames.self) { frames in
                geometry.itemFrames = frames
                if itemDrag.isDragging(in: controller) { itemDrag.framesChanged(frames) }
            }
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
            // Only this observes the pointer's travel, so a move redraws the
            // dragged row, not every window's list.
            PaneSidebarObserving(rowDrag.motion) { motion in
            GeometryReader { proxy in
                let origin = proxy.frame(in: .named(PaneSidebarGeometry.space)).origin
                let top = rowDrag.heldTop ?? (rowDrag.isSettling ? frame.minY : frame.minY + motion.dy)
                let y = Swift.min(Swift.max(top - origin.y, 0), Swift.max(0, proxy.size.height - frame.height))
                PaneSidebarRow(
                    pane: pane, owner: controller,
                    isStashed: controller.surfaceTree.isStashed(pane),
                    isSelected: pane === controller.publishedFocusedPane,
                    isForeign: false, isRail: isRail, isBeingDragged: false,
                    indent: geometry.rowFrames.first { $0.id == pane.id }?.indent ?? 0)
                    .environment(\.paneSidebarInteractive, false)
                    .frame(width: frame.width, height: frame.height)
                    // Glass under it while it is held, so it reads as on top
                    // of the rows it passes; gone as it settles.
                    .background { PaneSidebarLiftBacking().opacity(rowDrag.isSettling ? 0 : 1) }
                    .scaleEffect(rowDrag.isSettling ? 1 : 1.04)
                    .offset(x: frame.minX - origin.x, y: y)
                    .animation(rowDrag.isSettling && rowDrag.heldTop == nil ? PaneSidebarRowDrag.settleAnimation : nil, value: y)
                    .animation(PaneSidebarRowDrag.settleAnimation, value: rowDrag.isSettling)
            }
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
        // Cmd-N, from here. Not in the rail, whose header is the expand
        // button alone.
        PaneSidebarHeaderButton(symbol: .plus, help: "New window") {
            BaseTerminalController.newWindowFromSidebar(controller.ghostty, from: controller)
        }
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

    /// This window: its header (the window holding the panes, with its +
    /// and ×, as in all windows), then its panes, then — right after the last
    /// of them, under a divider — the tray of stashed panes, in one scrolling
    /// list. Two lists, and a drag moves a pane within either or across: into
    /// the tray stashes it, out restores. (The tray was first anchored at the
    /// bottom of the bar, which left it far from the panes it is for.) In the
    /// rail, the header is a + alone (a new pane, as the header's +).
    @ViewBuilder
    private var thisWindowList: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            if isRail {
                // The header with its text taken away, as a tile is its row:
                // a +, at the header's height, so no icon moves. This list is
                // the window's panes, so its + adds one, as the header's does.
                PaneSidebarRailAddSlot(help: "New pane") { controller.addPaneFromSidebar() }
                paneRows(controller, isThisWindow: true, indent: 0)
                tray(controller, isThisWindow: true, indent: 0)
            } else {
                // Its own name, as the all-windows list shows it: a
                // `<project>: <name>` window is `<name>`, under its group's
                // header — folding it folds the group here and there.
                let title = PaneSidebarText.windowTitle(of: controller)
                if let parts = PaneSidebarWindowGrouping.split(title) {
                    thisWindowsGroupHeader(parts.project)
                    PaneSidebarOutline.headerGapView
                    if !state.foldedProjects.contains(parts.project) {
                        windowGroup(controller, isThisWindow: true, label: parts.worktree)
                            .transition(PaneSidebarOutline.foldTransition)
                    }
                } else {
                    windowGroup(controller, isThisWindow: true, label: title)
                }
            }
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
                // Every window's all-windows list scrolls as one.
                .background(PaneSidebarScrollSyncAnchor(isRail: isRail))
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
        // The rail's + above every window: the panel header's — a new
        // window, as Cmd-N — since this list is windows.
        if isRail {
            PaneSidebarRailAddSlot(help: "New window") {
                BaseTerminalController.newWindowFromSidebar(controller.ghostty, from: controller)
            }
        }
        allWindows
    }

    /// This window's group header in its own Panes list: the all-windows
    /// list's, with the whole group's count and buttons (pencil, + and ×).
    private func thisWindowsGroupHeader(_ project: String) -> some View {
        let windows = controller.paneSidebarSections.first { $0.project == project }?.windows ?? []
        let byID = Dictionary(allControllers.map { ($0.paneSidebarState.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let folded = state.foldedProjects.contains(project)
        return PaneSidebarProjectHeader(
            project: project,
            windowCount: windows.count,
            isFolded: folded,
            onAdd: {
                BaseTerminalController.newWindowInGroupFromSidebar(
                    controller.ghostty, project: project, from: controller)
            },
            onClose: {
                BaseTerminalController.closeWindowsFromSidebar(windows.compactMap { byID[$0.id] })
            },
            onFold: {
                withAnimation(PaneSidebarOutline.foldAnimation) {
                    if folded { state.foldedProjects.remove(project) } else { state.foldedProjects.insert(project) }
                }
            },
            onRename: { name in
                BaseTerminalController.renameGroupFromSidebar(
                    project, to: name,
                    windows: windows.compactMap { entry in byID[entry.id].map { ($0, entry.label) } })
            })
    }

    /// Every terminal window with a sidebar, this one included even before
    /// it is visible.
    private var allControllers: [BaseTerminalController] {
        controller.paneSidebarAllControllers
    }

    /// Every window, in the list's own order (by name until something is
    /// dragged); `<project>: <worktree>` windows grouped under a collapsible,
    /// sticky project header (`PaneSidebarWindowGrouping`). A window row and
    /// a project header drag to reorder (`PaneSidebarItemDrag`).
    @ViewBuilder
    private var allWindows: some View {
        let controllers = allControllers
        let byID = Dictionary(controllers.map { ($0.paneSidebarState.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let titled = controllers.map { (id: $0.paneSidebarState.windowID, title: PaneSidebarText.windowTitle(of: $0)) }
        let matches = searchMatches(controllers, titles: Dictionary(titled.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a }))
        // Searching: only windows with a matching pane, and nothing folded
        // away — a hit hidden inside a folded group would read as no hit.
        let sections = PaneSidebarWindowGrouping.sections(titled, order: state.shared.windowOrder).compactMap { section in
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

        let topLevel = sections.map(\.id)
        let reporting = itemDrag.isDragging(in: controller)
        ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
            if let project = section.project, !isRail {
                let folded = matches == nil && state.foldedProjects.contains(project)
                let windows = section.windows.map(\.key)
                let onFold = {
                    withAnimation(PaneSidebarOutline.foldAnimation) {
                        if folded { state.foldedProjects.remove(project) }
                        else { state.foldedProjects.insert(project) }
                    }
                }
                // A gap above the header's band, so it never touches what
                // ends the list above it (a row's hover, the tray's well).
                // A group is one item in the list's order: its gaps, header
                // and windows each report its frame and slide as one.
                if index > 0 {
                    PaneSidebarOutline.headerGapView
                        .modifier(PaneSidebarItemShift(key: section.id, drag: itemDrag, isActive: reporting, showsBacking: false))
                }
                Section {
                    if !folded {
                        // ...and below it, before its first window.
                        PaneSidebarOutline.headerGapView
                            .modifier(PaneSidebarItemShift(key: section.id, drag: itemDrag, isActive: reporting, showsBacking: false))
                        ForEach(section.windows, id: \.id) { entry in
                            if let owner = byID[entry.id] {
                                // Not indented: every window's chevron lines
                                // up, grouped or not; the group's header says
                                // which windows are its.
                                windowGroup(owner, isThisWindow: owner === controller,
                                            label: entry.label,
                                            matches: matches?[entry.id], siblings: windows)
                                    // INSIDE the slide: the fold's mask is the
                                    // item's own frame, and outside it would
                                    // cut away an item slid past its height.
                                    .transition(PaneSidebarOutline.foldTransition)
                                    .modifier(PaneSidebarItemShift(key: entry.key, drag: itemDrag, isActive: reporting))
                            }
                        }
                        .modifier(PaneSidebarItemShift(
                            key: section.id + PaneSidebarItemDrag.windowsSuffix, drag: itemDrag,
                            isActive: reporting, showsBacking: false))
                    }
                } header: {
                    PaneSidebarProjectHeader(
                        project: project,
                        windowCount: section.windows.count,
                        isFolded: folded,
                        onAdd: {
                            BaseTerminalController.newWindowInGroupFromSidebar(
                                controller.ghostty, project: project,
                                from: section.windows.first.flatMap { byID[$0.id] })
                        },
                        onClose: {
                            BaseTerminalController.closeWindowsFromSidebar(
                                section.windows.compactMap { byID[$0.id] })
                        },
                        onFold: onFold,
                        onRename: { name in
                            BaseTerminalController.renameGroupFromSidebar(
                                project, to: name,
                                windows: section.windows.compactMap { entry in byID[entry.id].map { ($0, entry.label) } })
                        })
                        .paneSidebarItemDrag(
                            key: section.id, siblings: topLevel, controller: controller,
                            leading: 0, trailing: PaneSidebarProjectHeader.trailingControls,
                            help: folded ? "Show \(project)’s windows — drag to reorder"
                                : "Hide \(project)’s windows — drag to reorder",
                            onClick: onFold)
                        .modifier(PaneSidebarJoinHighlight(project: project, motion: itemDrag.motion))
                        .modifier(PaneSidebarItemShift(key: section.id, drag: itemDrag, isActive: reporting, showsBacking: false))
                }
            } else {
                ForEach(section.windows, id: \.id) { entry in
                    if let owner = byID[entry.id] {
                        // No divider between lone windows: their headers
                        // set them apart, as grouped windows' do.
                        windowGroup(owner, isThisWindow: owner === controller, label: entry.label,
                                    matches: matches?[entry.id], siblings: topLevel)
                        .modifier(PaneSidebarItemShift(key: entry.key, drag: itemDrag, isActive: reporting))
                    }
                }
            }
        }
    }

    /// A window of the all-windows list: its row, and its panes unless
    /// folded. `siblings`: the keys it is reordered among when its row is
    /// dragged.
    private func windowGroup(
        _ owner: BaseTerminalController,
        isThisWindow: Bool,
        label: String,
        indent: CGFloat = 0,
        matches: Set<ObjectIdentifier>? = nil,
        siblings: [String] = []
    ) -> some View {
        let id = owner.paneSidebarState.windowID
        let folded = state.isWindowFolded(id, isSearching: matches != nil)
        let onFold = {
            withAnimation(PaneSidebarOutline.foldAnimation) { state.toggleWindowFold(id) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            // In the rail a window is its tiles alone: no divider between
            // windows.
            if !isRail {
                PaneSidebarWindowHeader(
                    owner: owner,
                    title: label,
                    isThisWindow: isThisWindow,
                    // Only among other windows does it need saying.
                    showsThisWindowTag: isThisWindow && state.showsAllWindows,
                    indent: indent,
                    isFolded: folded,
                    isClicked: !isThisWindow && state.shared.clickedWindow == id,
                    isDropTarget: isJoinTarget(owner),
                    onFold: onFold)
                    .paneSidebarItemDrag(
                        key: PaneSidebarWindowGrouping.key(window: id), siblings: siblings,
                        controller: controller,
                        leading: PaneSidebarWindowHeader.leadingControls(indent: indent),
                        trailing: PaneSidebarWindowHeader.trailingControls,
                        help: isThisWindow ? "This window — drag to reorder" : "Raise this window — drag to reorder") {
                            guard !isThisWindow else { return onFold() }
                            // Selected at once, while it comes forward.
                            state.shared.clickedWindow = id
                            owner.window?.makeKeyAndOrderFront(nil)
                            NSApp.activate(ignoringOtherApps: true)
                        }
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
                isSelected: pane === focused || (!isThisWindow && state.shared.clickedPane == pane.id),
                isThisWindow: isThisWindow, indent: indent)
                .modifier(PaneSidebarShift(
                    rows: slide.map { PaneSidebarOrder.shift(index: index, source: $0.source, target: $0.target) } ?? 0,
                    height: drag?.height ?? 0,
                    isLifted: rowDrag.pane === pane || (slide != nil && index == slide?.source),
                    isDragging: drag != nil))
                .background { rowFrameReader(pane, isStashed: false, isThisWindow: isThisWindow, indent: indent) }
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
            // All windows: no divider and no caption — a window's stashed
            // panes follow its others in one list, the same in the rail and
            // the panel, so collapsing or expanding moves nothing. (Still
            // here, at no height, for where the tray begins.)
            if !state.showsAllWindows {
                PaneSidebarDivider(isRail: isRail)
            }
            // Captioned only when it holds something: an empty tray is its
            // drop slot, whose own text says what it is.
            if !isRail && !stashed.isEmpty && !state.showsAllWindows {
                HStack(alignment: .firstTextBaseline) {
                    SidePanelCaption(text: "Stashed")
                    Spacer()
                    PaneSidebarCount(value: stashed.count)
                }
                .padding(.leading, SidePanelRow.labelInset + indent)
                .padding(.trailing, SidePanelRow.labelInset)
                // 10pt under the line, the divider's own space included.
                .padding(.top, 10 - PaneSidebarDivider.bottom)
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
                .background { rowFrameReader(pane, isStashed: true, isThisWindow: isThisWindow, indent: indent) }
        }

        // An empty tray is still somewhere to drop: a slot that says so,
        // always there in this window's list, lit while a drag would land in
        // it. It stays put; the rows open the gap above it.
        // In all windows it is there only while a pane is dragged: the list
        // is every window's panes and nothing else.
        if stashed.isEmpty && isThisWindow && (!state.showsAllWindows || dragSession.isDragging) {
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
    private func rowFrameReader(_ pane: PaneView, isStashed: Bool, isThisWindow: Bool, indent: CGFloat) -> some View {
        if (dragSession.isDragging || rowDrag.pane != nil) && isThisWindow {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PaneSidebarRowFrames.self,
                    value: [.init(id: pane.id, frame: proxy.frame(in: .named(PaneSidebarGeometry.space)),
                                  isStashed: isStashed, indent: indent)])
            }
        }
    }

    // MARK: Search

    /// Searching: for each window, the panes the query matches. Nil when not
    /// searching (no query, or the rail, which has no room for the field).
    private func searchMatches(
        _ controllers: [BaseTerminalController],
        titles: [UUID: String]
    ) -> [UUID: Set<ObjectIdentifier>]? {
        let terms = PaneSidebarFilter.terms(state.filter)
        guard !terms.isEmpty, !isRail else { return nil }
        var result: [UUID: Set<ObjectIdentifier>] = [:]
        for owner in controllers {
            let id = owner.paneSidebarState.windowID
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
        let titled = controllers.map { (id: $0.paneSidebarState.windowID, title: PaneSidebarText.windowTitle(of: $0)) }
        guard let matches = searchMatches(
            controllers, titles: Dictionary(titled.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a }))
        else { return }
        let byID = Dictionary(controllers.map { ($0.paneSidebarState.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        for section in PaneSidebarWindowGrouping.sections(titled, order: state.shared.windowOrder) {
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
            ?? PaneSidebarRow.height
        return .init(pane: pane, paneTarget: paneTarget, stashTarget: stashTarget, height: height)
    }

    private func isJoinTarget(_ owner: BaseTerminalController) -> Bool {
        guard case .joinWindow(let window) = dragSession.target else { return false }
        return window == PaneDropWindowRef(owner)
    }
}

/// Observes `model` for its content alone: a part of a view that must redraw
/// on every change of a fast-changing model (a drag's pointer travel) without
/// the view around it observing that model too.
struct PaneSidebarObserving<Model: ObservableObject, Content: View>: View {
    @ObservedObject private var model: Model
    private let content: (Model) -> Content

    init(_ model: Model, @ViewBuilder content: @escaping (Model) -> Content) {
        self.model = model
        self.content = content
    }

    var body: some View { content(model) }
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

// MARK: - Renaming in place

/// The sidebar item being renamed in place, by its key: a window's or a
/// group's (`PaneSidebarWindowGrouping.key`), or a pane's (`key(pane:)`).
/// One at a time across every window's sidebar; while it is set, that item's
/// drag source steps aside so its field takes the clicks.
@MainActor
final class PaneSidebarRename: ObservableObject {
    static let shared = PaneSidebarRename()
    @Published var editing: String?

    static func key(pane id: UUID) -> String { "pane:\(id)" }
}

/// A sidebar item's name, edited in place (`PaneSidebarRename`): a
/// borderless `NSTextField`, as the search field is, that takes the caret as
/// it appears with its text selected. (A SwiftUI `TextField` asked for focus
/// never got it here: keys went on to whatever had it, the search field or a
/// terminal.) Return or clicking away ends it with the text; Escape with nil.
struct PaneSidebarRenameField: NSViewRepresentable {
    let initial: String
    var font: NSFont = .systemFont(ofSize: 12, weight: .semibold)
    let onEnd: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEnd: onEnd) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initial)
        field.font = font
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Name")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Once it is in the window: the caret, the whole name selected.
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window else { return }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            context.coordinator.isLive = true
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.onEnd = onEnd
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onEnd: (String?) -> Void
        /// Took the caret: only then does losing it end the edit.
        var isLive = false
        private var ended = false

        init(onEnd: @escaping (String?) -> Void) { self.onEnd = onEnd }

        private func end(_ text: String?) {
            guard !ended else { return }
            ended = true
            onEnd(text)
        }

        func controlTextDidEndEditing(_ note: Notification) {
            // Clicked away: keep what was typed, as Return does.
            guard isLive, let field = note.object as? NSTextField else { return }
            end(field.stringValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                end((control as? NSTextField)?.stringValue)
                control.window?.makeFirstResponder(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                end(nil)
                control.window?.makeFirstResponder(nil)
                return true
            default:
                return false
            }
        }
    }
}

// MARK: - Window header (this window's list, and each window in all windows)

struct PaneSidebarWindowHeader: View {
    @ObservedObject var owner: BaseTerminalController
    /// The window's name, or — inside a project group — its worktree.
    let title: String
    let isThisWindow: Bool
    var showsThisWindowTag = false
    /// Inside a project group: one outline level in.
    var indent: CGFloat = 0
    let isFolded: Bool
    /// Just clicked (another window): selected while it comes forward.
    var isClicked = false
    let isDropTarget: Bool
    let onFold: () -> Void

    @State private var isHovered = false
    @ObservedObject private var rename = PaneSidebarRename.shared
    @Environment(\.paneSidebarInteractive) private var isInteractive
    @Environment(\.paneSidebarEmphasized) private var windowIsKey

    private var key: String { PaneSidebarWindowGrouping.key(window: owner.paneSidebarState.windowID) }
    private var isEditing: Bool { rename.editing == key }

    /// This window folded: the selected pane is inside the fold, so its
    /// header carries the selection, as a row would.
    private var isSelected: Bool { (isThisWindow && isFolded) || isClicked }
    private var onAccent: Bool { isSelected && windowIsKey }

    static let contentHeight: CGFloat = 16
    static let verticalPadding: CGFloat = 6
    /// Its whole height in the list, the gap to its neighbours included.
    static var height: CGFloat { contentHeight + verticalPadding * 2 + PaneSidebarRow.gap }

    var body: some View {
        HStack(spacing: PaneSidebarOutline.chevronSpacing) {
            Button(action: onFold) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isFolded ? -90 : 0))
                    .foregroundStyle(onAccent
                        ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor).opacity(0.8))
                        : AnyShapeStyle(.secondary))
                    .frame(width: PaneSidebarOutline.chevronWidth, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFolded ? "Show this window’s panes" : "Hide this window’s panes")

            // A window's icon, in a pane row's icon column and spacing: its
            // panes, indented one chevron, put theirs right under it.
            HStack(spacing: 7) {
            Image(systemName: "macwindow")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(onAccent
                    ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
                    : AnyShapeStyle(.secondary))
                .frame(width: PaneSidebarRow.iconWidth, height: 15)
                .accessibilityHidden(true)

            // The PARENT row: the window's own name, at the weight a sidebar
            // gives a group, with its panes indented beneath it.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if isEditing {
                    nameField
                } else {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SidePanelRow.foreground(isActive: isSelected, isEmphasized: windowIsKey))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if showsThisWindowTag && !isEditing {
                    Text("This Window")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(onAccent
                            ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor).opacity(0.7))
                            : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            }
            Spacer(minLength: 4)

            // Hovered, the count gives way to + and × in its place: a pane
            // split the way the last one was (focused, as Cmd-D), and close
            // the window — no questions, no focus taken.
            ZStack(alignment: .trailing) {
                PaneSidebarCount(value: owner.surfaceTree.count, onAccent: onAccent)
                    .opacity(isHovered && isInteractive && !isEditing ? 0 : 1)
                if isHovered && isInteractive && !isEditing {
                    HStack(spacing: PaneSidebarRow.trailingButtonSpacing) {
                        PaneSidebarItemButton(symbol: "pencil", help: "Rename window", onAccent: onAccent) {
                            beginRename()
                        }
                        PaneSidebarItemButton(symbol: "plus", help: "New pane", onAccent: onAccent) {
                            owner.addPaneFromSidebar()
                        }
                        PaneSidebarItemButton(symbol: "xmark", help: "Close window", onAccent: onAccent) {
                            owner.closeWindowFromSidebar()
                        }
                    }
                    .offset(x: PaneSidebarItemButton.headerOffset)
                }
            }
            .frame(height: 14)
        }
        // One height, whatever the font's line: the rail's + slot matches it
        // (`PaneSidebarRailAddSlot`), so collapsing moves no icon.
        .frame(height: Self.contentHeight)
        .padding(.vertical, Self.verticalPadding)
        .padding(.leading, PaneSidebarOutline.headerLeading + indent)
        .padding(.trailing, SidePanelRow.textInset)
        .background(SidePanelRow.fill(
            isActive: isSelected, isHovered: isHovered && !isThisWindow, isEmphasized: windowIsKey))
        .overlay(
            RoundedRectangle(cornerRadius: SidePanelRow.cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: isDropTarget ? 2 : 0))
        .padding(.horizontal, SidePanelRow.fillInset)
        // Clear of its neighbours' pills, as a row is (`PaneSidebarRow.gap`).
        .padding(.vertical, PaneSidebarRow.gap / 2)
        .contentShape(Rectangle())
        // Not `.onHover`: it blinks off for a frame when a fold re-lays out
        // the list (see `HoverTrackingView`).
        .background(HoverTrackingArea(isHovered: $isHovered))
        // Clicked (raise it; this window's folds) and dragged (reorder) by
        // `paneSidebarItemDrag`, between its chevron and its count.
    }

    /// The whole title in place of the name — a grouped window's
    /// `<project>: ` too, so the group can be changed here. Return keeps it,
    /// Escape or an unchanged name leaves the window as it was, and an
    /// empty one goes back to following the window's own title.
    private var nameField: some View {
        PaneSidebarRenameField(initial: currentTitle) { name in
            rename.editing = nil
            guard let name = name?.trimmingCharacters(in: .whitespaces) else { return }
            // Unchanged: don't pin a title that was following the shell.
            guard name != currentTitle else { return }
            owner.renameWindowKeepingPlace(name.isEmpty ? nil : name)
        }
        .frame(height: Self.contentHeight)
    }

    private var currentTitle: String {
        owner.effectiveWindowTitleOverride ?? PaneSidebarText.windowTitle(of: owner)
    }

    private func beginRename() { rename.editing = key }

    /// The chevron's end, from the row's leading edge: the drag source
    /// starts there.
    static func leadingControls(indent: CGFloat) -> CGFloat {
        SidePanelRow.fillInset + PaneSidebarOutline.headerLeading + indent + PaneSidebarOutline.chevronWidth
    }

    /// The count's (or pencil, + and ×'s) start, from the row's trailing
    /// edge: the drag source stops there.
    static var trailingControls: CGFloat {
        SidePanelRow.fillInset + SidePanelRow.textInset
            + 3 * PaneSidebarItemButton.size + 2 * PaneSidebarRow.trailingButtonSpacing
    }
}

/// The rail's + at the top of its list: in this window, its header's
/// stand-in (a new pane); in all windows, the panel header's (a new window).
/// In a slot exactly the header's height (`PaneSidebarWindowHeader.height`).
struct PaneSidebarRailAddSlot: View {
    let help: String
    let action: () -> Void

    var body: some View {
        PaneSidebarItemButton(symbol: "plus", help: help, action: action)
            .frame(maxWidth: .infinity)
            .frame(height: PaneSidebarWindowHeader.height)
    }
}

// MARK: - Project header (all-windows scope)

/// A `<project>: …` group's header: sticky at the top of the list while its
/// windows scroll under it, and folds them away. On Liquid Glass so rows
/// passing beneath stay legible (see `glassBackdrop`).
private struct PaneSidebarProjectHeader: View {
    /// Its band's height: a little under a row's, its caption centered in it.
    static let height: CGFloat = 32

    /// The pencil, + and ×'s start, from the header's trailing edge: the drag
    /// source (`paneSidebarItemDrag`, which also folds on a click) stops there.
    static var trailingControls: CGFloat {
        SidePanelRow.fillInset + SidePanelRow.textInset
            + 3 * PaneSidebarItemButton.size + 2 * PaneSidebarRow.trailingButtonSpacing
    }

    let project: String
    let windowCount: Int
    let isFolded: Bool
    /// A new window in the group, focused (as Cmd-N).
    let onAdd: () -> Void
    /// Close every window in the group: no questions, no focus taken.
    let onClose: () -> Void
    let onFold: () -> Void
    /// Rename the group: every window in it takes the new `<project>: `.
    let onRename: (String) -> Void

    @State private var isHovered = false
    @ObservedObject private var rename = PaneSidebarRename.shared
    @Environment(\.paneSidebarInteractive) private var isInteractive

    private var isEditing: Bool { rename.editing == PaneSidebarWindowGrouping.key(project: project) }

    var body: some View {
        HStack(spacing: 0) {
            if isEditing {
                HStack(spacing: PaneSidebarOutline.chevronSpacing) {
                    Color.clear.frame(width: PaneSidebarOutline.chevronWidth, height: 14)
                    PaneSidebarRenameField(initial: project, font: .systemFont(ofSize: 11, weight: .semibold)) { name in
                        rename.editing = nil
                        guard let name = name?.trimmingCharacters(in: .whitespaces), name != project else { return }
                        onRename(name)
                    }
                    .frame(height: 14)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isFolded ? "Show \(project)’s windows" : "Hide \(project)’s windows")
            .accessibilityLabel("\(project), \(windowCount) windows")
            .accessibilityAddTraits(.isHeader)
            }

            // As a window row: hovered, the count gives way to pencil, + and ×.
            ZStack(alignment: .trailing) {
                PaneSidebarCount(value: windowCount)
                    .opacity(isHovered && isInteractive && !isEditing ? 0 : 1)
                if isHovered && isInteractive && !isEditing {
                    HStack(spacing: PaneSidebarRow.trailingButtonSpacing) {
                        PaneSidebarItemButton(symbol: "pencil", help: "Rename group") {
                            rename.editing = PaneSidebarWindowGrouping.key(project: project)
                        }
                        PaneSidebarItemButton(
                            symbol: "plus", help: "New window in \(project)", action: onAdd)
                        PaneSidebarItemButton(
                            symbol: "xmark",
                            help: windowCount == 1 ? "Close its window" : "Close its \(windowCount) windows",
                            action: onClose)
                    }
                    .offset(x: PaneSidebarItemButton.headerOffset)
                }
            }
            .frame(height: 14)
        }
        .padding(.leading, PaneSidebarOutline.headerLeading)
        .padding(.trailing, SidePanelRow.textInset)
        .padding(.horizontal, SidePanelRow.fillInset)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HoverTrackingArea(isHovered: $isHovered))
        .glassBackdrop()
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
    /// Clear space between a project header's band and the content above
    /// and below it. Outside the band (a sticky header's backdrop), in the
    /// scrolling list, so a pinned header is still just its band.
    static let headerGap: CGFloat = 6
    static var headerGapView: some View {
        Color.clear.frame(height: headerGap).accessibilityHidden(true)
    }
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
    /// On the accent selection pill: white, not the tertiary label color.
    var onAccent = false

    var body: some View {
        Text("\(value)")
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(onAccent
                ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor).opacity(0.7))
                : AnyShapeStyle(.tertiary))
    }
}

/// A hairline between sections — above all, the tray's: the line a pane is
/// dragged below to stash it, so it must read on glass (at 9% it all but
/// vanished there).
struct PaneSidebarDivider: View {
    let isRail: Bool

    /// Space under the line in the panel: with what follows it — the empty
    /// tray's drop slot, inset 4.5pt in its own frame — as much clear space
    /// below the line as above it (its 8pt and the last row's 3pt).
    static let bottom: CGFloat = 6.5

    var body: some View {
        // As wide as a row's fill, not its text.
        Rectangle()
            .fill(Color.primary.opacity(0.22))
            .frame(height: 1)
            .padding(.horizontal, isRail ? 8 : SidePanelRow.fillInset)
            .padding(.vertical, isRail ? 7 : 0)
            .padding(.top, isRail ? 0 : 8)
            .padding(.bottom, isRail ? 0 : Self.bottom)
    }
}

/// A row of the sidebar while a pane is dragged over it: slid `rows` rows
/// of `height` to make room (`PaneSidebarOrder.shift`), or — the dragged row
/// itself, over the sidebar — lifted out, leaving its gap. The slide is a
/// short bounded animation, and none at all once the drag ends: the drop
/// re-lays the list out where the rows were already drawn, so nothing moves.
struct PaneSidebarShift: ViewModifier {
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
        .padding(.horizontal, SidePanelRow.fillInset)
        .padding(.vertical, 4)
        .animation(.easeOut(duration: 0.15), value: isHot)
        .help("Drag a pane here to stash it — out of the grid, still running")
        .allowsHitTesting(false)
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
    /// The all-windows list's windows and groups, by key, while one is
    /// dragged (`PaneSidebarItemDrag`).
    var itemFrames: [String: CGRect] = [:]
}

struct PaneSidebarRowFrames: PreferenceKey {
    struct Entry: Equatable {
        let id: UUID
        let frame: CGRect
        /// A tray row (vs a row of the pane list).
        let isStashed: Bool
        /// Its content's indent, so the dragged row drawn over the list
        /// keeps it.
        let indent: CGFloat
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
        // The tab group's window title, whichever tab holds it — as the
        // titlebar and `+list` show it — so every tab groups as one window.
        if let override = owner.effectiveWindowTitleOverride ?? owner.titleOverride, !override.isEmpty {
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
        // Fully revealed, the mask reaches far past every edge: a transition
        // wraps the WHOLE inserted item, offsets included, so a mask cut at
        // its frame would hide a window row slid past its own height in a
        // reorder (`PaneSidebarItemShift`), or its lifted shadow.
        let open = fraction >= 1
        content
            .mask(alignment: .top) {
                GeometryReader { proxy in
                    let reach = open ? Self.reach : 0
                    Rectangle()
                        .frame(width: proxy.size.width + 2 * reach,
                               height: max(0, proxy.size.height * fraction) + 2 * reach)
                        .offset(x: -reach, y: -reach)
                }
            }
            .opacity(fraction > 0 ? 1 : 0)
    }

    private static let reach: CGFloat = 10_000
}

/// The all-windows search's text: a borderless `NSTextField` (see
/// `searchField`). Return reports a submit; Escape clears the query, and on
/// an empty field gives the caret back.
struct PaneSidebarSearchField: NSViewRepresentable {
    /// Takes the caret only when clicked: out of the key-view loop, so a
    /// window ordered in (`-[NSWindow _selectFirstKeyView]`, with no
    /// `initialFirstResponder`) does not hand it the caret ahead of the
    /// window's terminal. A click still focuses it (`acceptsFirstResponder`).
    final class ClickToFocusField: NSTextField {
        override var canBecomeKeyView: Bool { false }
    }

    @Binding var text: String
    let onSubmit: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = ClickToFocusField()
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

extension BaseTerminalController {
    /// Rename project group `project` to `name`: each of its `windows` (with
    /// its own name, the part after `<project>: `) is retitled
    /// `<name>: <label>` — pinned, as Change Window Title pins it — and
    /// nothing moves in the list (`PaneSidebarWindowGrouping.renaming`). An
    /// empty name takes them out of any group, each to its own name, where
    /// the group was.
    static func renameGroupFromSidebar(
        _ project: String, to name: String, windows: [(BaseTerminalController, String)]
    ) {
        guard let sections = windows.first?.0.paneSidebarSections else { return }
        let shared = PaneSidebarSharedState.shared
        let order = PaneSidebarWindowGrouping.renaming(project: project, to: name, in: sections)
        if order != shared.windowOrder { shared.windowOrder = order }
        for (window, label) in windows {
            window.setWindowTitle(name.isEmpty ? label : "\(name): \(label)", byUser: true)
        }
    }

    /// Retitle this window as the user (`windowTitleIsUsers`: no script
    /// renames over it), as Change Window Title does (nil follows its panes
    /// again), without moving it in the all-windows list: the list is
    /// pinned as it was shown (`PaneSidebarWindowGrouping.renaming`), in
    /// every window's sidebar. A rename by the user — the sidebar's field,
    /// the Change Window Title prompt; a programmatic title (`+rename`,
    /// `+new-window --title`) still places a window by name.
    func renameWindowKeepingPlace(_ title: String?) {
        let sections = paneSidebarSections
        setWindowTitle(title, byUser: true)
        let shared = PaneSidebarSharedState.shared
        let order = PaneSidebarWindowGrouping.renaming(
            window: paneSidebarState.windowID, to: PaneSidebarText.windowTitle(of: self), in: sections)
        if order != shared.windowOrder { shared.windowOrder = order }
    }
}

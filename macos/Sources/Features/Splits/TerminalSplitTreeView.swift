import SwiftUI

/// A single operation within the split tree.
///
/// Rather than binding the split tree (which is immutable), any mutable operations are
/// exposed via this enum to the embedder to handle.
///
/// Dropping a pane is deliberately NOT here. A drop is resolved from a screen
/// point against every candidate window (`PaneDropResolver`) and applied by
/// `PaneMoveCoordinator`, because a per-leaf drop delegate can see neither the
/// window's edges, nor the tab bar, nor which of two overlapping windows won.
enum TerminalSplitOperation {
    case resize(Resize)

    /// A drag that tucks a row's outermost pane on one side behind the rest,
    /// or brings one back (see `PaneLayout.Restack`).
    case restack(PaneLayout.Row<UUID>, PaneLayout.Restack)

    /// A grip on a stack dragged: between two cards it resizes them, or
    /// collapses the row; at the run's edge it widens it.
    case stackDrag(StackDrag)

    /// A divider double-clicked: even out the panes across dividers that run
    /// its way, and only those (`SplitTree.equalized(only:)`).
    case equalize(SplitTree<PaneView>.Direction)

    struct Resize {
        /// The split node whose divider the gesture is on.
        let node: SplitTree<PaneView>.Node

        /// What the gesture is doing. A `.moved` reports the divider's position in
        /// POINTS rather than a ratio, which is what lets the embedder move that one
        /// edge and leave the rest of the window's dividers where they are.
        let gesture: SplitViewDividerGesture

        /// On `.began`: the tree as it is laid out on screen
        /// (`PaneLayout.Result.displayed`), which `node` belongs to. Its ratios
        /// differ from the stored ones where a pane minimum overrides them, and
        /// the drag starts from what the user sees.
        var displayed: SplitTree<PaneView>.Node? = nil

        /// On `.began`: the row the divider is in. The divider is a gutter
        /// of it: the drag makes the row what its position makes of it
        /// (`PaneLayout.dragged`), panes tucking away and strips coming out.
        var row: PaneLayout.Row<UUID>? = nil

        /// On `.began`: how many of the row's items lie before the divider.
        var boundary: Int = 0

        /// On `.began`: where the node starts in the row, so a position in
        /// the node is measured from the row's start by adding it.
        var rowOffset: CGFloat = 0
    }

    /// A grip on a stacked row dragged (`PaneLayout.StackHandle`). The row and
    /// grip are as the drag found them; `.moved` carries the distance from
    /// mouse-down.
    struct StackDrag {
        let row: PaneLayout.Row<UUID>
        let kind: PaneLayout.StackHandle<UUID>.Kind
        let direction: PaneLayout.Direction
        let gesture: SplitViewDividerGesture
        /// Where the grip was in its row when the drag began.
        var position: CGFloat = 0
    }
}

struct TerminalSplitTreeView: View {
    let tree: SplitTree<PaneView>
    let action: (TerminalSplitOperation) -> Void
    @ObservedObject var heroModeState: HeroModeState
    @ObservedObject var rearrangeModeState: RearrangeModeState
    @ObservedObject var stackState: PaneStackState

    /// Names this window for drop resolution.
    let windowRef: PaneDropWindowRef

    var body: some View {
        // The LAYOUT is the visible tree: stashed panes stay in `tree` (so
        // nothing that walks it loses them) but are not mounted here, exactly
        // as the panes behind a zoom are not. Divider gestures report nodes of
        // this tree; the controller lifts their ratios back onto the full one.
        let visible = tree.visibleTree
        let ranks = stackState.ranks
        Group {
            if heroModeState.isActive {
                HeroModeView(tree: visible, state: heroModeState)
                    .transition(.opacity)
            } else if let node = visible.zoomed ?? visible.root {
                PaneGrid(
                    node: node,
                    isRoot: node == visible.root,
                    rearranging: rearrangeModeState.isActive,
                    ranks: ranks,
                    pins: stackState.pins,
                    shares: stackState.shares,
                    stackState: stackState,
                    slots: nil,
                    action: action)
                // This is necessary because we can't rely on SwiftUI's implicit
                // structural identity to detect changes to this view. Due to
                // the tree structure of splits it could result in bad behaviors.
                // See: https://github.com/ghostty-org/ghostty/issues/7546
                .id(node.structuralIdentity)
                // A top-level insert spans the whole window, so its feedback
                // cannot belong to any one leaf; nor does a strip's slot.
                .overlay { TopLevelDropOverlay(windowRef: windowRef) }
                .overlay { BladeDropOverlay(windowRef: windowRef) }
            }
        }
        .background {
            if !tree.stashed.isEmpty, let root = tree.root {
                // Where stashed panes LIVE: mounted, hidden, behind the grid,
                // each in the slot it would occupy in the full (unstashed)
                // layout. See `PaneGrid.slots`.
                PaneGrid(
                    node: root,
                    isRoot: true,
                    rearranging: false,
                    ranks: ranks,
                    pins: stackState.pins,
                    shares: stackState.shares,
                    stackState: stackState,
                    slots: Set(tree.stashed),
                    action: { _ in })
                    .id(root.structuralIdentity)
                    // Opacity, not `.hidden()`: a hidden SwiftUI subtree
                    // never mounts its AppKit views, which is the bug this
                    // layer exists to fix. Behind the grid, so the grid's
                    // views win every hit test anyway.
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// A window's panes, each where `PaneLayout` puts it: side by side, or — in
/// a row too narrow for them — stacked, with the panes that don't fit tucked
/// behind as cards the user clicks to bring forward.
///
/// One flat layer of panes rather than nested split views, because a stack
/// is a property of a whole row and its cards slide across what were nested
/// split boundaries. Each pane keeps its identity (its id), so bringing a
/// card forward moves the pane's view; nothing is remounted.
private struct PaneGrid: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<PaneView>.Node
    let isRoot: Bool
    let rearranging: Bool
    /// `PaneStackState.ranks`: 0 is the focused pane, a featured one -1.
    let ranks: [UUID: Int]
    /// Which rows the user collapsed — passed by value, so a change to them
    /// redraws the grid.
    let pins: [Set<UUID>: PaneLayout.Pin]
    /// How the user sized stacked runs (`PaneStackState.shares`).
    let shares: [Set<UUID>: [CGFloat]]
    /// Told the order of each stack's items, which a focus change slides by.
    let stackState: PaneStackState

    /// Non-nil: this is the hidden layer where stashed panes live, and only
    /// these panes are mounted (each at the size it will come back at).
    ///
    /// A stashed pane is out of the layout but must keep its geometry.
    /// Unmounted, a terminal that was stashed when the window opened (a session
    /// restore) is never laid out at all and is told it is the 800×600
    /// placeholder — 49×17 cells — so its program re-renders at 49 columns, and
    /// restoring it is a reflow. Laid out here by the SAME layout the grid uses,
    /// it always has exactly the size it will have when it comes back, through
    /// relaunches and window resizes alike, and it keeps a window (so
    /// window-scoped actions from its terminal still find their controller).
    ///
    /// Visible panes are empty placeholders: they are mounted in the grid, and
    /// a view can only be in one place. The layer is hidden and never
    /// hit-tested; it has no dividers or tabs.
    let slots: Set<UUID>?

    let action: (TerminalSplitOperation) -> Void

    private var paneGap: CGFloat? { PaneElevation.paneGap(for: ghostty.config.macosPaneStyle) }
    private var isElevated: Bool { ghostty.config.macosPaneStyle == .elevated }

    var body: some View {
        GeometryReader { geo in
            let layout = PaneLayout.compute(
                node,
                in: CGRect(origin: .zero, size: geo.size),
                metrics: .forStyle(paneGap: paneGap),
                rank: { ranks[$0.id] },
                pin: { pins[$0] },
                shares: { shares[$0] },
                // The stashed-pane layer lays out another tree; the runs
                // that stick are the grid's.
                shown: { slots == nil ? stackState.shownRun($0) : nil })
            let panes = node.leaves()
            // The grid on screen is the one whose stacks a drag finds; the
            // hidden stashed-pane layer lays out the full tree.
            let _ = slots == nil
                ? stackState.noteStacks(layout.stacks)
                : layout.stacks.forEach { stackState.noteItems($0.items, fits: $0.fits) }
            let _ = slots == nil ? stackState.noteGrid { [node, size = geo.size, paneGap, ranks, stackState] in
                PaneLayout.compute(
                    node,
                    in: CGRect(origin: .zero, size: size),
                    metrics: .forStyle(paneGap: paneGap),
                    rank: { ranks[$0.id] },
                    pin: { stackState.pins[$0] },
                    shares: { stackState.shares[$0] },
                    shown: { stackState.shownRun($0) })
            } : ()
            ZStack(alignment: .topLeading) {
                if let slots {
                    ForEach(panes, id: \.id) { pane in
                        if let leaf = layout.leaves[pane.id] {
                            slot(pane, leaf, isStashed: slots.contains(pane.id))
                        }
                    }
                } else {
                    let stacked = Set(layout.stacks.flatMap { $0.items.flatMap { $0 } })
                    PaneStage(
                        cards: PaneLayout.paintOrder(panes, layout.leaves).compactMap { pane in
                            guard let leaf = layout.leaves[pane.id] else { return nil }
                            let isStacked = stacked.contains(pane.id)
                            return PaneStage.Card(
                                pane: pane,
                                leaf: leaf,
                                isStacked: isStacked,
                                content: AnyView(PaneLeafView(
                                    pane: pane,
                                    isSplit: !(isRoot && panesAreOne),
                                    rearranging: rearranging)))
                        },
                        size: geo.size,
                        runs: layout.stacks.map(\.run),
                        isGesturing: stackState.isGesturing,
                        stackState: stackState,
                        style: .init(
                            isCard: isElevated,
                            cornerRadius: isElevated ? PaneElevation.cornerRadius : 0,
                            background: ghostty.config.backgroundColor,
                            isLight: OSColor(ghostty.config.backgroundColor).isLightColor))
                    .frame(width: geo.size.width, height: geo.size.height)
                    // Keyed by place in the row, so a divider that goes away
                    // mid-drag (its row collapsed) takes its drag with it.
                    ForEach(layout.dividers, id: \.id) { divider in
                        GridDivider(
                            divider: divider,
                            displayed: layout.displayed,
                            paneGap: paneGap,
                            color: ghostty.config.splitDividerColor,
                            action: action)
                    }
                    ForEach(layout.stackHandles, id: \.id) { handle in
                        StackGrip(
                            handle: handle,
                            paneGap: paneGap,
                            color: ghostty.config.splitDividerColor,
                            action: action)
                    }
                }
            }
        }
    }

    /// A window of one pane has nothing to set it apart from.
    private var panesAreOne: Bool {
        if case .leaf = node { return true }
        return false
    }

    /// A pane's place in the hidden stashed-pane layer: the pane itself if it
    /// is stashed, else an empty placeholder.
    @ViewBuilder
    private func slot(_ pane: PaneView, _ leaf: PaneLayout.Leaf, isStashed: Bool) -> some View {
        Group {
            if isStashed {
                switch pane.content {
                case .terminal(let surfaceView):
                    Ghostty.InspectableSurface(surfaceView: surfaceView, isSplit: true)
                case .viewer(let viewerView):
                    ViewerSplitLeaf(viewerView: viewerView, isOnGlass: ghostty.config.paneGlass)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: leaf.frame.width, height: leaf.frame.height)
        .offset(x: leaf.frame.minX, y: leaf.frame.minY)
    }
}

/// A divider between two side-by-side panes: the line (flat style) or the
/// gap (elevated), with the AppKit grab handle over it. A drag reports the
/// divider's position in points from its split node's leading edge.
private struct GridDivider: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let divider: PaneLayout.Divider<SplitTree<PaneView>.Node, UUID>
    /// The tree as laid out, which the drag starts from.
    let displayed: SplitTree<PaneView>.Node?
    let paneGap: CGFloat?
    let color: Color
    let action: (TerminalSplitOperation) -> Void

    /// A drag keeps a sliver of each side; the controller clamps again
    /// against the pane minimums, which can only be tighter.
    private let floor: CGFloat = 10


    private var direction: SplitViewDirection {
        divider.direction == .horizontal ? .horizontal : .vertical
    }

    private var extent: CGFloat {
        divider.direction == .horizontal ? divider.nodeFrame.width : divider.nodeFrame.height
    }

    var body: some View {
        // The grab target is the gutter between the panes, all of it and
        // nothing more: a click just inside a pane's edge is the pane's (its
        // grab handle sits there). It is an APPKIT handle view
        // (`DividerHandle`) layered above the panes, because the panes host
        // AppKit views (terminal surfaces, web views) that out-hit-test any
        // SwiftUI gesture area.
        let hit = divider.gutter
        let across = direction == .horizontal ? hit.width : hit.height
        // The flat style's line, down the middle of its gutter.
        let line: CGFloat = paneGap == nil ? 1 : across
        ZStack {
            SplitView<EmptyView, EmptyView>.Divider(
                direction: direction,
                visibleSize: line,
                invisibleSize: across - line,
                color: paneGap == nil ? color : .clear,
                split: divider.fraction,
                onAdjust: { fraction in
                    // An accessibility nudge is a drag of one step.
                    send(.began)
                    move(to: fraction * extent)
                    send(.ended)
                })
            DividerHandle(
                direction: direction,
                onDragBegan: { send(.began) },
                onDragDelta: { delta, startSplit in
                    // The delta is cumulative from mouse-down and `startSplit` is
                    // where the divider was then, so this is an absolute target
                    // measured against the layout the drag started from. Not
                    // clamped: well past a minimum, the row collapses.
                    let target = startSplit * extent + delta
                    guard extent > 0 else { return }
                    send(.moved(position: target, dimension: extent))
                },
                onDragEnded: { send(.ended) },
                onDoubleClick: equalize,
                currentSplit: { divider.fraction },
                // The divider goes away when its row collapses; the drag
                // carries on, and can bring the row back.
                tracksModally: true)
        }
        .frame(width: hit.width, height: hit.height)
        .offset(x: hit.minX, y: hit.minY)
    }

    private func send(_ gesture: SplitViewDividerGesture) {
        let began = if case .began = gesture { true } else { false }
        let nodeStart = divider.direction == .horizontal ? divider.nodeFrame.minX : divider.nodeFrame.minY
        action(.resize(.init(
            node: divider.node,
            gesture: gesture,
            displayed: began ? displayed : nil,
            row: began ? divider.row : nil,
            boundary: divider.index,
            rowOffset: nodeStart - divider.row.start)))
    }

    private func move(to position: CGFloat) {
        guard extent > 0 else { return }
        let clamped = min(max(position, floor), max(floor, extent - floor))
        send(.moved(position: clamped, dimension: extent))
    }

    /// Double-click: even out the panes across this divider — the splits
    /// laid out its way — and leave the other direction alone. (It used to
    /// run `equalize_splits`, which reset every ratio both ways.)
    private func equalize() {
        action(.equalize(divider.direction == .horizontal ? .horizontal : .vertical))
    }
}

/// A grip on a stacked row (`PaneLayout.StackHandle`). Between two cards on
/// show it resizes them, and a drag well past a card's minimum tucks the
/// outermost card on that side behind instead, as a divider does; at the edge
/// of a run the user narrowed it is the divider of the nearest strip, which
/// comes out once it has been pulled to a pane's minimum and then follows
/// the pointer. Either way, dragging back undoes it while the mouse is still
/// down (see `BaseTerminalController.splitDidDragStack`).
private struct StackGrip: View {
    let handle: PaneLayout.StackHandle<UUID>
    let paneGap: CGFloat?
    let color: Color
    let action: (TerminalSplitOperation) -> Void

    private var direction: SplitViewDirection {
        handle.direction == .horizontal ? .horizontal : .vertical
    }

    var body: some View {
        let isBetweenCards = if case .between = handle.kind { true } else { false }
        // The gutter it sits in, and nothing more (see `GridDivider`).
        let hit = handle.gutter
        ZStack {
            // In the flat style the cards on show meet at a line, as panes
            // side by side do; elsewhere a grip is only a cursor.
            if isBetweenCards && paneGap == nil {
                Rectangle()
                    .fill(color)
                    .frame(width: direction == .horizontal ? 1 : nil, height: direction == .vertical ? 1 : nil)
            }
            DividerHandle(
                direction: direction,
                onDragBegan: { send(.began) },
                onDragDelta: { delta, _ in send(.moved(position: delta, dimension: 0)) },
                onDragEnded: { send(.ended) },
                onDoubleClick: nil,
                currentSplit: { 0.5 },
                // A grip goes away as the row collapses or widens; the drag
                // carries on, and can undo it.
                tracksModally: true)
        }
        .frame(width: hit.width, height: hit.height)
        .offset(x: hit.minX, y: hit.minY)
    }

    /// Every message of one drag carries the row and grip as the drag found
    /// them: the controller replays each step from there.
    private func send(_ gesture: SplitViewDividerGesture) {
        action(.stackDrag(.init(
            row: handle.row, kind: handle.kind, direction: handle.direction, gesture: gesture,
            position: handle.position)))
    }
}

/// One leaf of the tree, of either kind.
///
/// Both pane kinds share this wrapper so the rearrange header, the
/// dragged-pane dimming, and the drop feedback are written once — a viewer is
/// an ordinary leaf and rearranges exactly like a terminal.
private struct PaneLeafView: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject var pane: PaneView
    let isSplit: Bool
    let rearranging: Bool

    @ObservedObject private var dragSession = PaneDragSession.shared
    @Environment(\.paneContentFreeze) private var freeze
    @Environment(\.paneContentAnchor) private var anchor
    @Environment(\.paneCollapse) private var collapse

    private var isBeingDragged: Bool { dragSession.isDragging(pane) }

    var body: some View {
        // Mid-glide, and as a strip, the pane keeps one size (`PaneStage`),
        // from the card's top-left corner — or its far edge, gliding into or
        // out of its strip — cut by the card, or with sheet to spare. An
        // overlay, so a frozen pane larger than its card never reports that
        // size up (a frame would, and be centered); the same structure frozen
        // or not, so nothing remounts. It fades out as its card goes into its
        // strip, leaving the card's glass and the strip's title.
        Color.clear.overlay(alignment: anchor) {
            VStack(spacing: 0) {
                if rearranging {
                    PaneHeaderView(pane: pane)
                }
                content
            }
            .frame(width: freeze?.width, height: freeze?.height)
            .opacity(1 - collapse)
        }
        .clipped()
        // The source pane fades for the duration of the drag, so the layout
        // it is leaving reads as provisional.
        .opacity(isBeingDragged ? 0.4 : 1.0)
        .overlay {
            PaneDropFeedbackView(paneID: pane.id, isDraggedPane: isBeingDragged)
                .allowsHitTesting(false)
        }
        // Its sidebar tile or row is under the pointer: the pane takes its hue.
        .overlay {
            PaneSidebarHoverTint(paneID: pane.id,
                                 cornerRadius: ghostty.config.macosPaneStyle == .elevated ? PaneElevation.cornerRadius : 0)
                .allowsHitTesting(false)
        }
        // The elevated style: a raised rounded card on the window's gradient.
        .modifier(PaneCard(
            isElevated: ghostty.config.macosPaneStyle == .elevated,
            isGlass: ghostty.config.paneGlass,
            // Only among siblings: a lone pane has nothing to stand out from.
            isFocused: isSplit && pane.isFocusedPane,
            background: ghostty.config.backgroundColor,
            isLight: OSColor(ghostty.config.backgroundColor).isLightColor))
    }

    @ViewBuilder
    private var content: some View {
        switch pane.content {
        case .terminal(let surfaceView):
            Ghostty.InspectableSurface(surfaceView: surfaceView, isSplit: isSplit)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Terminal pane")
        case .viewer(let viewerView):
            ViewerSplitLeaf(viewerView: viewerView, isOnGlass: ghostty.config.paneGlass)
        }
    }
}

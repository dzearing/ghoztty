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

    struct Resize {
        /// The split node whose divider the gesture is on.
        let node: SplitTree<PaneView>.Node

        /// What the gesture is doing. A `.moved` reports the divider's position in
        /// POINTS rather than a ratio, which is what lets the embedder move that one
        /// edge and leave the rest of the window's dividers where they are.
        let gesture: SplitViewDividerGesture
    }
}

struct TerminalSplitTreeView: View {
    let tree: SplitTree<PaneView>
    let action: (TerminalSplitOperation) -> Void
    @ObservedObject var heroModeState: HeroModeState
    @ObservedObject var rearrangeModeState: RearrangeModeState

    /// Names this window for drop resolution.
    let windowRef: PaneDropWindowRef

    var body: some View {
        // The LAYOUT is the visible tree: stashed panes stay in `tree` (so
        // nothing that walks it loses them) but are not mounted here, exactly
        // as the panes behind a zoom are not. Divider gestures report nodes of
        // this tree; the controller lifts their ratios back onto the full one.
        let visible = tree.visibleTree
        Group {
            if heroModeState.isActive {
                HeroModeView(tree: visible, state: heroModeState)
                    .transition(.opacity)
            } else if let node = visible.zoomed ?? visible.root {
                TerminalSplitSubtreeView(
                    node: node,
                    isRoot: node == visible.root,
                    rearranging: rearrangeModeState.isActive,
                    action: action)
                // This is necessary because we can't rely on SwiftUI's implicit
                // structural identity to detect changes to this view. Due to
                // the tree structure of splits it could result in bad behaviors.
                // See: https://github.com/ghostty-org/ghostty/issues/7546
                .id(node.structuralIdentity)
                // A top-level insert spans the whole window, so its feedback
                // cannot belong to any one leaf.
                .overlay { TopLevelDropOverlay(windowRef: windowRef) }
            }
        }
        .background {
            if !tree.stashed.isEmpty, let root = tree.root {
                StashedPaneSlots(node: root, stashed: Set(tree.stashed))
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

/// Where stashed panes LIVE: mounted, hidden, behind the grid, each in the
/// slot it would occupy in the full (unstashed) layout.
///
/// A stashed pane is out of the layout but must keep its geometry. Unmounted,
/// a terminal that was stashed when the window opened (a session restore) is
/// never laid out at all and is told it is the 800×600 placeholder — 49×17
/// cells — so its program re-renders at 49 columns, and restoring it is a
/// reflow. Laid out here with the SAME split views the grid uses, it always
/// has exactly the size it will have when it comes back, through relaunches
/// and window resizes alike, and it keeps a window (so window-scoped actions
/// from its terminal still find their controller).
///
/// Visible leaves are empty placeholders: they are mounted in the grid, and a
/// view can only be in one place. The layer is hidden and never hit-tested;
/// its dividers do nothing.
private struct StashedPaneSlots: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<PaneView>.Node
    let stashed: Set<UUID>

    var body: some View {
        switch node {
        case .leaf(let pane):
            if stashed.contains(pane.id) {
                switch pane.content {
                case .terminal(let surfaceView):
                    Ghostty.InspectableSurface(surfaceView: surfaceView, isSplit: true)
                case .viewer(let viewerView):
                    ViewerSplitLeaf(viewerView: viewerView)
                }
            } else {
                Color.clear
            }

        case .split(let split):
            SplitView(
                split.direction == .horizontal ? .horizontal : .vertical,
                CGFloat(split.ratio),
                dividerColor: ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                onDividerGesture: { _ in },
                left: { StashedPaneSlots(node: split.left, stashed: stashed) },
                right: { StashedPaneSlots(node: split.right, stashed: stashed) },
                onEqualize: {},
                // The slots must lay out EXACTLY as the grid does, gaps and all.
                paneGap: PaneElevation.paneGap(for: ghostty.config.macosPaneStyle))
        }
    }
}

private struct TerminalSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let node: SplitTree<PaneView>.Node
    var isRoot: Bool = false
    let rearranging: Bool
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        switch node {
        case .leaf(let pane):
            PaneLeafView(pane: pane, isSplit: !isRoot, rearranging: rearranging)

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                CGFloat(split.ratio),
                dividerColor: ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                onDividerGesture: { action(.resize(.init(node: node, gesture: $0))) },
                left: {
                    TerminalSplitSubtreeView(
                        node: split.left, rearranging: rearranging, action: action)
                },
                right: {
                    TerminalSplitSubtreeView(
                        node: split.right, rearranging: rearranging, action: action)
                },
                onEqualize: {
                    // Any terminal surface in the subtree can host the equalize
                    // action (the leftmost leaf may be a viewer pane).
                    guard let surface = node.leaves().compactMap(\.surface).first else { return }
                    ghostty.splitEqualize(surface: surface)
                },
                paneGap: PaneElevation.paneGap(for: ghostty.config.macosPaneStyle)
            )
        }
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

    private var isBeingDragged: Bool { dragSession.isDragging(pane) }

    var body: some View {
        VStack(spacing: 0) {
            if rearranging {
                PaneHeaderView(pane: pane)
            }
            content
        }
        // The source pane fades for the duration of the drag, so the layout
        // it is leaving reads as provisional.
        .opacity(isBeingDragged ? 0.4 : 1.0)
        .overlay {
            PaneDropFeedbackView(paneID: pane.id, isDraggedPane: isBeingDragged)
                .allowsHitTesting(false)
        }
        // The elevated style: a raised rounded card on the window's gradient.
        .modifier(PaneCard(
            isElevated: ghostty.config.macosPaneStyle == .elevated,
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
            ViewerSplitLeaf(viewerView: viewerView)
        }
    }
}

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
        if heroModeState.isActive {
            HeroModeView(tree: tree, state: heroModeState)
                .transition(.opacity)
        } else if let node = tree.zoomed ?? tree.root {
            TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
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
                }
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

import AppKit
import OSLog

/// Applies a resolved `PaneDropTarget`: the one place a pane actually moves.
///
/// Every mutation rebuilds trees out of the EXISTING `PaneView` instances, so
/// leaf identity survives — and with it the terminal's process and scrollback,
/// and a viewer's rendered page and scroll position. This is the same rule
/// `RearrangeLayout` follows for `+rearrange`, for the same reason.
@MainActor
enum PaneMoveCoordinator {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "PaneMoveCoordinator")

    /// The undo action name every rearrange registers under, so a run of
    /// drags reads as one kind of thing in the Edit menu.
    static let undoActionName = "Move Pane"

    // MARK: Entry points

    /// Perform `target` by moving `pane` out of `source`.
    static func apply(
        _ target: PaneDropTarget,
        pane: PaneView,
        from source: BaseTerminalController
    ) {
        guard let sourceNode = source.surfaceTree.root?.node(view: pane) else {
            logger.warning("dragged pane is not in its source window; ignoring drop")
            return
        }

        switch target {
        case .split(let window, let destPaneID, let direction):
            guard let destination = controller(for: window),
                  let destPane = destination.surfaceTree.first(where: { $0.id == destPaneID })
            else { return }
            split(pane: pane, node: sourceNode, from: source,
                  onto: destPane, in: destination, direction: direction)

        case .swap(let window, let destPaneID):
            guard let destination = controller(for: window),
                  let destPane = destination.surfaceTree.first(where: { $0.id == destPaneID })
            else { return }
            swap(pane: pane, node: sourceNode, from: source,
                 with: destPane, in: destination)

        case .topLevel(let window, let side):
            guard let destination = controller(for: window) else { return }
            insertAtTopLevel(pane: pane, node: sourceNode, from: source,
                             in: destination, side: side)

        case .newTab(let window, let index):
            guard let destination = controller(for: window) else { return }
            moveToNewTab(pane: pane, node: sourceNode, from: source,
                         near: destination, index: index)

        case .newWindow(let point):
            moveToNewWindow(pane: pane, node: sourceNode, from: source, at: point)
        }
    }

    /// The header's pop-out button: the same move as dropping in empty space,
    /// without the drag.
    static func popOut(pane: PaneView, from source: BaseTerminalController) {
        guard let node = source.surfaceTree.root?.node(view: pane) else { return }
        moveToNewWindow(pane: pane, node: node, from: source, at: nil)
    }

    /// Whether `pane` can leave `source` at all.
    ///
    /// A drag never closes a window. Moving a window's ONLY pane out would
    /// empty it, and an emptied window closing as a side effect of a drag is
    /// both surprising and dangerous — it would bypass the close confirmation
    /// and the remote Disconnect prompt that `SessionDisconnectPolicy` exists
    /// to present. If you want the window gone, close it.
    static func canMove(pane: PaneView, from source: BaseTerminalController) -> Bool {
        source.surfaceTree.isSplit
    }

    // MARK: Moves

    private static func split(
        pane: PaneView,
        node: SplitTree<PaneView>.Node,
        from source: BaseTerminalController,
        onto destPane: PaneView,
        in destination: BaseTerminalController,
        direction: SplitTree<PaneView>.NewDirection
    ) {
        if source === destination {
            let without = source.surfaceTree.removing(node)
            guard let rebuilt = try? without.inserting(
                view: pane, at: destPane, direction: direction)
            else {
                logger.warning("failed to insert pane during same-window split drop")
                return
            }
            commit(in: source, tree: rebuilt, focus: pane)
            return
        }

        guard canMove(pane: pane, from: source) else { return }
        guard let inserted = try? destination.surfaceTree.inserting(
            view: pane, at: destPane, direction: direction)
        else {
            logger.warning("failed to insert pane during cross-window split drop")
            return
        }
        crossWindowCommit(
            pane: pane,
            source: source, sourceTree: source.surfaceTree.removing(node),
            destination: destination, destinationTree: inserted)
    }

    private static func swap(
        pane: PaneView,
        node: SplitTree<PaneView>.Node,
        from source: BaseTerminalController,
        with destPane: PaneView,
        in destination: BaseTerminalController
    ) {
        guard pane !== destPane else { return }
        guard let destNode = destination.surfaceTree.root?.node(view: destPane) else { return }

        if source === destination {
            guard let swapped = try? source.surfaceTree.swapping(node, with: destNode) else {
                logger.warning("failed to swap panes")
                return
            }
            commit(in: source, tree: swapped, focus: pane)
            return
        }

        // A cross-window swap is an EXCHANGE: each pane leaves one tree and
        // arrives in the other, so both controllers keep their pane count and
        // neither window can be emptied. `canMove` therefore does not apply.
        guard let newSourceTree = try? source.surfaceTree.replacing(
                node: node, with: .leaf(view: destPane)),
              let newDestTree = try? destination.surfaceTree.replacing(
                node: destNode, with: .leaf(view: pane))
        else {
            logger.warning("failed to swap panes across windows")
            return
        }
        crossWindowCommit(
            pane: pane, alsoRelocated: [destPane],
            source: source, sourceTree: newSourceTree,
            destination: destination, destinationTree: newDestTree)
    }

    private static func insertAtTopLevel(
        pane: PaneView,
        node: SplitTree<PaneView>.Node,
        from source: BaseTerminalController,
        in destination: BaseTerminalController,
        side: SplitTree<PaneView>.NewDirection
    ) {
        let sourceTree = source.surfaceTree.removing(node)

        // The tree the pane is being wrapped around: the destination's, minus
        // the pane itself when it is already in there.
        let baseTree = source === destination ? sourceTree : destination.surfaceTree
        guard baseTree.root != nil else {
            // The destination had nothing but this pane. Its top level is
            // already the pane; there is nothing to insert beside.
            return
        }

        let wrapped = baseTree.insertingAtTopLevel(view: pane, side: side)

        if source === destination {
            commit(in: source, tree: wrapped, focus: pane)
            return
        }
        guard canMove(pane: pane, from: source) else { return }
        crossWindowCommit(
            pane: pane,
            source: source, sourceTree: sourceTree,
            destination: destination, destinationTree: wrapped)
    }

    private static func moveToNewTab(
        pane: PaneView,
        node: SplitTree<PaneView>.Node,
        from source: BaseTerminalController,
        near destination: BaseTerminalController,
        index: Int
    ) {
        guard canMove(pane: pane, from: source) else { return }
        guard let destWindow = destination.window else { return }
        let ghostty = source.ghostty

        source.undoManager?.beginUndoGrouping()
        source.undoManager?.setActionName(undoActionName)
        defer { source.undoManager?.endUndoGrouping() }

        source.replaceSurfaceTree(source.surfaceTree.removing(node))

        let controller = TerminalController(ghostty, withSurfaceTree: SplitTree(view: pane))
        guard let newWindow = controller.window else { return }

        if let tabGroup = destWindow.tabGroup {
            tabGroup.insertWindow(newWindow, at: min(max(index, 0), tabGroup.windows.count))
        } else {
            destWindow.addTabbedWindowSafely(newWindow, ordered: .above)
        }

        // Present on the next turn of the run loop: AppKit has to finish
        // settling the tab group before the new tab can be selected, the same
        // reason `TerminalController.newTab` defers its own presentation.
        DispatchQueue.main.async {
            controller.showWindow(nil)
            newWindow.makeKeyAndOrderFront(nil)
        }

        finishRelocation(of: [pane], into: controller)
    }

    private static func moveToNewWindow(
        pane: PaneView,
        node: SplitTree<PaneView>.Node,
        from source: BaseTerminalController,
        at point: CGPoint?
    ) {
        guard canMove(pane: pane, from: source) else { return }
        let ghostty = source.ghostty

        source.undoManager?.beginUndoGrouping()
        source.undoManager?.setActionName(undoActionName)
        defer { source.undoManager?.endUndoGrouping() }

        source.replaceSurfaceTree(source.surfaceTree.removing(node))

        let controller = TerminalController.newWindow(
            ghostty,
            tree: SplitTree(view: pane),
            position: point.map { NSPoint(x: $0.x, y: $0.y) },
            confirmUndo: false)

        finishRelocation(of: [pane], into: controller)
    }

    // MARK: Commit

    private static func commit(
        in controller: BaseTerminalController,
        tree: SplitTree<PaneView>,
        focus: PaneView
    ) {
        controller.replaceSurfaceTree(
            tree,
            moveFocusTo: focus.surfaceView,
            moveFocusFrom: controller.focusedSurface,
            undoAction: undoActionName)
        if focus.surfaceView == nil {
            DispatchQueue.main.async { Ghostty.moveFocus(to: focus) }
        }
    }

    /// Move panes between two controllers as ONE undoable step.
    ///
    /// The source is updated FIRST so the destination's arrival is the last
    /// word, then `finishRelocation` states outright that the relocated panes
    /// are alive. See its comment for why the ordering alone is not enough.
    private static func crossWindowCommit(
        pane: PaneView,
        alsoRelocated: [PaneView] = [],
        source: BaseTerminalController,
        sourceTree: SplitTree<PaneView>,
        destination: BaseTerminalController,
        destinationTree: SplitTree<PaneView>
    ) {
        source.undoManager?.beginUndoGrouping()
        source.undoManager?.setActionName(undoActionName)
        defer { source.undoManager?.endUndoGrouping() }

        source.replaceSurfaceTree(sourceTree, moveFocusFrom: source.focusedSurface)
        commit(in: destination, tree: destinationTree, focus: pane)

        finishRelocation(of: [pane] + alsoRelocated, into: destination)
    }

    /// Declare that these panes MOVED rather than closed, and carry the mode
    /// to wherever the pane landed.
    ///
    /// `SessionCloseIntentPolicy` reads a leaf leaving a tree as "the user
    /// closed it" and marks its agent session CLOSE-on-free. That default is
    /// right for a close and wrong for a move, and no ordering of the two
    /// controllers' updates can fix every case: a cross-window SWAP has each
    /// pane departing one tree and arriving in the other, so whichever
    /// controller is updated last, the other one's departing pane is left
    /// marked. A pane that is alive on screen would then have its session
    /// terminated when the view is finally freed.
    ///
    /// So the coordinator — which is the one thing that knows this was a move
    /// — says so explicitly, and ordering stops being load-bearing.
    private static func finishRelocation(
        of panes: [PaneView],
        into destination: BaseTerminalController
    ) {
        for pane in panes {
            pane.setSessionCloseIntent(false)
            pane.clearSessionDetachPin()
            ClosingSessions.shared.unmark(pane.surfaceView?.boundRemoteSessionID)
        }

        // The mode follows the pane: you are still rearranging, and the window
        // you are now looking at should still be rearrangeable.
        destination.enterRearrangeModeIfNeeded()
    }

    // MARK: Lookup

    /// Map a resolved window reference back to its controller.
    static func controller(for ref: PaneDropWindowRef) -> BaseTerminalController? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            if PaneDropWindowRef(controller) == ref { return controller }
        }
        return nil
    }
}

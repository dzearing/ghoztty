import AppKit

/// The pane sidebar's operations on a window: stash, restore, exchange,
/// close, kill. See `docs/design/pane-sidebar.md`.
///
/// Every one is an ordinary tree replacement through `replaceSurfaceTree`, so
/// undo works (stash state is part of the tree value) and the session close
/// policy sees the change — which, because a stashed pane never leaves the
/// tree, never reads a stash as a close (`PaneStashSessionSafetyTests`).
extension BaseTerminalController {
    /// The pane that has keyboard focus in this window, of either kind.
    var focusedPane: PaneView? {
        if let viewer = focusedViewerPane { return viewer }
        guard let focusedSurface else { return nil }
        return surfaceTree.first { $0.surfaceView === focusedSurface }
    }

    // MARK: Stash / restore

    /// Stash `pane` at `index` in the stash (default: the top). Stashing a
    /// stashed pane moves it within the stash.
    ///
    /// Refused — with a beep, and `false` — when it would leave nothing on
    /// screen. Focus, when the stashed pane had it, moves to the neighbor a
    /// close would have picked.
    @discardableResult
    func stashPane(_ pane: PaneView, at index: Int? = nil) -> Bool {
        let wasStashed = surfaceTree.isStashed(pane)
        let newTree: SplitTree<PaneView>
        do {
            newTree = try surfaceTree.stashing(pane, at: index)
        } catch {
            NSSound.beep()
            return false
        }

        // Decide focus against the CURRENT layout, before the pane leaves it.
        let nextFocus: PaneView? = (!wasStashed && focusedPane === pane)
            ? surfaceTree.root?.node(view: pane).flatMap { findNextFocusTargetAfterClosing(node: $0) }
            : nil

        replaceSurfaceTree(
            newTree,
            moveFocusTo: nextFocus?.surfaceView,
            moveFocusFrom: focusedSurface,
            undoAction: wasStashed ? "Reorder Stashed Panes" : "Stash Pane")
        if let nextFocus, nextFocus.surfaceView == nil {
            DispatchQueue.main.async { Ghostty.moveFocus(to: nextFocus) }
        }
        return true
    }

    /// Put a stashed `pane` back in the slot it left. With `focus`, the
    /// restored pane takes keyboard focus (the UI's restore); without it,
    /// focus stays where it is (a CLI restore under the `--focus` policy).
    func restorePane(_ pane: PaneView, focus: Bool = true) {
        if surfaceTree.isStashed(pane) {
            replaceSurfaceTree(
                surfaceTree.restoring(pane),
                moveFocusTo: focus ? pane.surfaceView : nil,
                moveFocusFrom: focusedSurface,
                undoAction: "Restore Pane")
        }
        if focus {
            // A viewer has no surface for replaceSurfaceTree to focus, and an
            // already-visible pane needs focusing too.
            DispatchQueue.main.async { Ghostty.moveFocus(to: pane) }
        }
    }

    /// Option-click on a stashed row: `pane` takes the focused pane's slot,
    /// and the focused pane takes `pane`'s place in the stash.
    func exchangeStashedPane(_ pane: PaneView) {
        guard let focused = focusedPane ?? surfaceTree.visibleLeaves.first,
              focused !== pane,
              let swapped = try? surfaceTree.exchanging(stashed: pane, with: focused)
        else {
            restorePane(pane)
            return
        }
        replaceSurfaceTree(
            swapped,
            moveFocusTo: pane.surfaceView,
            moveFocusFrom: focusedSurface,
            undoAction: "Swap Pane")
        if pane.surfaceView == nil {
            DispatchQueue.main.async { Ghostty.moveFocus(to: pane) }
        }
    }

    /// Restore the top of the stash (the `restore_stashed_pane` action).
    func restoreTopStashedPane() {
        guard let pane = surfaceTree.stashedViews.first else {
            NSSound.beep()
            return
        }
        restorePane(pane)
    }

    /// Stash the pane with keyboard focus (the `stash_pane` action).
    func stashFocusedPane() {
        guard let pane = focusedPane else {
            NSSound.beep()
            return
        }
        stashPane(pane)
    }

    /// Bring `pane` forward: restore it if stashed, raise its window, and give
    /// it keyboard focus. What clicking another window's row does, and what
    /// "focus this target" means for a stashed pane (`ghoztty://focus`, the
    /// `--focus` idempotent hits) — raising a pane you can't see raises nothing.
    func revealPane(_ pane: PaneView) {
        if surfaceTree.isStashed(pane) {
            restorePane(pane, focus: false)
        }
        if let surface = pane.surfaceView {
            focusSurface(surface)
        } else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { Ghostty.moveFocus(to: pane) }
        }
    }

    /// A new split beside a STASHED pane would be invisible too, so the
    /// anchor comes back first (`+split` anchored at a stashed pane, or a
    /// split from one). Part of the split's own change — no separate undo.
    func restoreSplitAnchor(_ anchor: PaneView) {
        guard surfaceTree.isStashed(anchor) else { return }
        surfaceTree = surfaceTree.restoring(anchor)
    }

    // MARK: Sidebar visibility

    /// The pin: flat panel ⇄ raised mini rail. Unpinning leaves the card open
    /// under the pointer (it was just clicked) until the pointer leaves.
    func togglePaneSidebarPin() {
        setPaneSidebarPinned(!paneSidebarState.isPinned)
    }

    func setPaneSidebarPinned(_ pinned: Bool) {
        let state = paneSidebarState
        guard state.isPinned != pinned else { return }
        state.isPinned = pinned
        state.isHoverOpen = !pinned
        syncPaneSidebarLayout()
    }

    /// Ctrl+Cmd+S: hide or show the sidebar entirely.
    func togglePaneSidebar() {
        paneSidebarState.isHidden.toggle()
        paneSidebarState.isHoverOpen = false
        syncPaneSidebarLayout()
    }

    /// The pin and hidden flags are layout: persist them with the window.
    func syncPaneSidebarLayout() {
        window?.invalidateRestorableState()
        if sessionLayoutEntryID != nil {
            SessionLayoutManifest.shared.scheduleSync(self)
        }
    }

    // MARK: Close / kill

    /// The sidebar's right-click → Close Pane: the ordinary interactive
    /// close, confirmation and remote Disconnect included.
    func closePaneFromSidebar(_ pane: PaneView) {
        guard let node = surfaceTree.root?.node(view: pane) else { return }
        // The same widening `ghosttyDidCloseSurface` applies at the
        // interactive caller: confirm a running process, and confirm any
        // remote pane even when idle.
        let confirm = pane.needsConfirmQuit || !disconnectableViews(in: [pane]).isEmpty
        closeSurface(node, withConfirmation: confirm)
    }

    /// Trash mode: kill `pane` now. No confirmation, and no undo window —
    /// the tree is replaced WITHOUT registering an undo, so nothing retains
    /// the pane and its surface (and the process or agent session behind it)
    /// is freed as soon as the layout lets go of it, rather than when an undo
    /// window expires. That is what "just kill the terminal" means.
    func killPane(_ pane: PaneView) {
        guard let node = surfaceTree.root?.node(view: pane) else { return }

        // A window's last pane: killing it is closing the window, which has
        // its own path (and its own confirmation bypass is the point here).
        guard surfaceTree.count > 1 else {
            window?.close()
            return
        }

        let nextFocus: PaneView? = focusedPane === pane
            ? findNextFocusTargetAfterClosing(node: node)
            : nil

        // Assigning directly is what skips the undo registration. The
        // `surfaceTreeDidChange` bookkeeping still runs: the pane is marked
        // CLOSE-on-free, so its agent session ends rather than detaching.
        surfaceTree = surfaceTree.removing(node)

        if let nextFocus {
            DispatchQueue.main.async { Ghostty.moveFocus(to: nextFocus) }
        }
    }
}

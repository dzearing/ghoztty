import AppKit
import OSLog

/// Every collapse/expand, with its cause, at `.notice` (persisted): the
/// sidebar must never change mode on its own, and when someone sees it do so
/// this is how the cause is found.
private let paneSidebarLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.dzearing.ghoztty", category: "PaneSidebar")

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
            ? surfaceTree.root?.node(view: pane).flatMap { focusTargetAfterRemoving($0, leaving: newTree) }
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

    /// The button at the top of the bar: the full list ⇄ the icon rail.
    func togglePaneSidebarExpanded() {
        setPaneSidebarExpanded(!paneSidebarState.isExpanded, cause: "toggle")
    }

    /// `cause` names who asked, for the log: "button", "edge drag",
    /// "divider drag", ….
    func setPaneSidebarExpanded(_ expanded: Bool, cause: String = "unspecified") {
        let state = paneSidebarState
        guard state.isExpanded != expanded else { return }
        paneSidebarLog.notice("sidebar \(expanded ? "expanded" : "collapsed", privacy: .public) by \(cause, privacy: .public) in window \(self.window?.title ?? "?", privacy: .public)")
        changingPaneSidebarColumn { state.isExpanded = expanded }
        syncPaneSidebarLayout()
    }

    /// Ctrl+Cmd+S: hide or show the sidebar entirely.
    func togglePaneSidebar() {
        changingPaneSidebarColumn { paneSidebarState.isHidden.toggle() }
        syncPaneSidebarLayout()
    }

    /// The sidebar's column width now, as its container lays it out.
    var paneSidebarColumn: CGFloat {
        let windowWidth = window?.contentView?.bounds.width ?? .greatestFiniteMagnitude
        let state = paneSidebarState
        return PaneSidebarState.columnWidth(
            for: state.mode(windowWidth: windowWidth), panelWidth: state.width,
            elevated: ghostty.config.macosPaneStyle == .elevated)
    }

    /// Make a change that moves the sidebar's column, telling the grid first
    /// so it glides over rather than snapping (`PaneStackState.noteColumnShift`).
    /// The sidebar animates its own width to match (`PaneSidebarContainer`).
    /// This window only: the flags are shared (`PaneSidebarSharedState`), but
    /// another window takes the change when it is next key
    /// (`PaneSidebarState.catchUp`), so a collapse stays as quick as one
    /// window's.
    private func changingPaneSidebarColumn(_ change: () -> Void) {
        let before = paneSidebarColumn
        change()
        paneStackState.noteColumnShift(paneSidebarColumn - before)
        // The card glides from this turn too, with the grid.
        let windowWidth = window?.contentView?.bounds.width ?? .greatestFiniteMagnitude
        paneSidebarHost?.noteModeChange(to: paneSidebarState.mode(windowWidth: windowWidth))
    }

    /// The sidebar's order of its panes and its identity in the all-windows
    /// list are the window's layout: persist them with it. (The flags are
    /// shared, and kept in the defaults — `PaneSidebarSharedState`; the
    /// window still records them, for an older build reading its state.)
    func syncPaneSidebarLayout() {
        window?.invalidateRestorableState()
        if sessionLayoutEntryID != nil {
            SessionLayoutManifest.shared.scheduleSync(self)
        }
    }

    // MARK: Sidebar order

    /// This window's grid panes in the sidebar's order (`PaneSidebarOrder`).
    var paneSidebarPanes: [PaneView] {
        let visible = surfaceTree.visibleLeaves
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        return PaneSidebarOrder.arranged(visible.map(\.id), by: paneSidebarState.order)
            .compactMap { byID[$0] }
    }

    /// The order as persisted: only panes still in the window, and nothing
    /// at all until the list has been reordered.
    var paneSidebarPersistedOrder: [UUID] {
        let existing = Set(surfaceTree.map(\.id))
        return paneSidebarState.order.filter(existing.contains)
    }

    /// Put `pane`, which must be on the grid, at `index` of the sidebar's
    /// list. The list only: the grid does not change.
    func placeInPaneSidebar(_ pane: PaneView, at index: Int) {
        let visible = surfaceTree.visibleLeaves.map(\.id)
        guard visible.contains(pane.id) else { return }
        let state = paneSidebarState
        let order = PaneSidebarOrder.moving(
            pane.id, to: index, visible: visible, order: state.order,
            existing: Set(surfaceTree.map(\.id)))
        guard order != state.order else { return }
        state.order = order
        syncPaneSidebarLayout()
    }

    // MARK: Close

    /// The sidebar's × (and right-click → Close Pane) on a pane of THIS
    /// window or another: close it outright — no confirmation, no remote
    /// Disconnect offer, and no focus taken. Its processes end and its agent
    /// session is marked CLOSE-on-free like any close, so the session really
    /// ends (`SessionCloseIntentPolicy`). Undoable, as any close.
    ///
    /// A window's last pane closes the window (`closeWindowFromSidebar`):
    /// `TerminalController.closeSurface` would route the root to
    /// `closeTab`/`closeWindow`, which confirm.
    func closePaneFromSidebar(_ pane: PaneView) {
        guard let node = surfaceTree.root?.node(view: pane) else { return }
        switch PaneSidebarClosePolicy.paneClose(leafCount: surfaceTree.root?.leaves().count ?? 0) {
        case .removePane: closeSurface(node, withConfirmation: false)
        case .closeWindow: closeWindowFromSidebar()
        }
    }

    /// An all-windows window row's ×: close this window (this tab, in a tab
    /// group) without asking and without raising it — not through
    /// `performClose`/`windowShouldClose`, which confirm. `windowWillClose`
    /// marks every pane's session CLOSE-on-free, so they end rather than
    /// detach. The close runs on the next turn, so a window can close itself
    /// from its own sidebar without tearing down the button mid-action.
    func closeWindowFromSidebar() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            if let terminal = self as? TerminalController {
                terminal.closeTabImmediately()
            } else {
                self.window?.close()
            }
        }
    }

    /// A project group header's ×: every window in it, as `closeWindowFromSidebar`.
    static func closeWindowsFromSidebar(_ controllers: [BaseTerminalController]) {
        for controller in controllers { controller.closeWindowFromSidebar() }
    }
}

/// How the sidebar closes things: every close from it — a pane's, a window's,
/// a project group's — is unconfirmed and takes no focus.
enum PaneSidebarClosePolicy {
    enum PaneClose: Equatable {
        /// Take the pane out of its window's tree.
        case removePane
        /// It is the window's only pane (stashed ones count): close the window.
        case closeWindow
    }

    static func paneClose(leafCount: Int) -> PaneClose {
        leafCount > 1 ? .removePane : .closeWindow
    }
}

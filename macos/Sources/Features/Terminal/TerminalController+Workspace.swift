import AppKit
import SwiftUI
import GhosttyKit

/// Single-window mode: how a `TerminalController` gives up the one window
/// and takes it back (`WorkspaceHost` decides when). See
/// docs/reference/window-modes.md.
extension TerminalController {
    /// The SwiftUI root every terminal window shows.
    func makeContentContainer() -> TerminalViewContainer {
        TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
        }
    }

    /// The content view, on show or parked.
    var contentContainer: TerminalViewContainer? {
        parkedContainer ?? terminalViewContainer
    }

    // MARK: Parked content

    /// Make sure a parked workspace's content exists and is laid out at
    /// `size` — the window's content size — with the titlebar's inset it
    /// would have there, so its terminals have the grid they will have on
    /// show and are never sized to a placeholder. A workspace parked from
    /// birth gets its content here; its panes are created already.
    func prepareParkedContent(size: NSSize?, safeArea: NSEdgeInsets?) {
        guard isParked else { return }
        let container: TerminalViewContainer
        if let parkedContainer {
            container = parkedContainer
        } else {
            container = makeContentContainer()
            container.initialContentSize = focusedSurface?.initialSize
            parkedContainer = container
            // A fresh window focuses its only pane; so does a fresh workspace.
            if focusedSurface == nil, case let .leaf(view) = surfaceTree.root {
                focusedSurface = view.surfaceView
            }
        }
        if let safeArea { container.additionalSafeAreaInsets = safeArea }
        let target = size ?? WorkspaceHost.shared.window?.contentView?.frame.size
            ?? container.initialContentSize
            ?? NSSize(width: 800, height: 600)
        if container.frame.size != target {
            container.setFrameSize(target)
        }
        container.needsLayout = true
        container.layoutSubtreeIfNeeded()
        updateSeen()
    }

    /// A parked workspace's tree changed: lay its content out (no window
    /// will).
    func layoutParkedContent() {
        guard isParked, let parkedContainer else { return }
        parkedContainer.needsLayout = true
        parkedContainer.layoutSubtreeIfNeeded()
    }

    // MARK: Hand-off

    /// Give the window up. Its content view comes out whole and is kept;
    /// focus and the window's own per-workspace state (tab color) are
    /// remembered. Returns the window's fullscreen handler, which goes with
    /// the window.
    func surrenderWindow() -> FullscreenStyle? {
        guard !isParked, let window = heldWindow else { return nil }

        parkedFocus = focusedPane
        parkedTabColor = (window as? TerminalWindow)?.tabColor ?? .none
        observeFirstResponder(of: nil)

        if let container = window.contentView as? TerminalViewContainer {
            // Keep the titlebar's inset while out of the window, so the
            // content keeps its layout (and its terminals their grid).
            container.additionalSafeAreaInsets = container.safeAreaInsets
            parkedContainer = container
        }
        window.contentView = nil

        let style = takeFullscreenStyle()
        setParked(true)
        self.window = nil
        // Keeps the title it showed, for `+list` and AppleScript.
        applyTitleToWindow()
        return style
    }

    /// Take the window from the workspace that had it, with its content
    /// and every piece of the window that is this workspace's.
    func adoptWindow(_ window: NSWindow, fullscreen style: FullscreenStyle?) {
        setParked(false)
        self.window = window
        window.delegate = self

        let container: TerminalViewContainer
        if let parkedContainer {
            container = parkedContainer
        } else {
            // Never laid out (shown as it opens): what a fresh window does.
            container = makeContentContainer()
            container.initialContentSize = focusedSurface?.initialSize
            if focusedSurface == nil, case let .leaf(view) = surfaceTree.root {
                focusedSurface = view.surfaceView
            }
        }
        parkedContainer = nil
        container.additionalSafeAreaInsets = NSEdgeInsetsZero
        window.contentView = container
        observeFirstResponder(of: window)
        giveFullscreenStyle(style)

        if let terminalWindow = window as? TerminalWindow {
            terminalWindow.tabColor = parkedTabColor
            terminalWindow.remoteMachine = remoteMachine
            terminalWindow.remoteConnectionState = remoteConnectionState
            terminalWindow.surfaceIsZoomed = surfaceTree.zoomed != nil
        }
        WorkspaceHost.shared.windowStateDidChange()
        window.representedURL = focusedSurface?.pwd.map { URL(fileURLWithPath: $0) }
        syncAppearance()
        applyTitleToWindow()
        applyPendingWindowTitle()
    }

    /// The window went to another workspace: nothing here draws, nothing
    /// here has focus.
    func windowDidPark() {
        updateSeen()
        syncFocusToSurfaceTree()
        publishFocusedPane()
    }

    /// The window came to this workspace: draw, take focus where it was,
    /// catch the sidebar up, and fade the old workspace's shade out over
    /// this one's.
    func windowDidUnpark(key: Bool, from leavingShade: PaneDeskVariant?) {
        updateSeen()
        paneSidebarState.catchUp()
        paneSidebarState.shared.clearClicked(
            windowID: paneSidebarState.windowID, panes: Set(surfaceTree.map(\.id)))

        if leavingShade != deskVariant {
            let entrance = PaneDeskEntrance(from: leavingShade)
            deskEntrance = entrance
            DispatchQueue.main.asyncAfter(deadline: .now() + PaneDeskEntrance.duration + 0.05) { [weak self] in
                if self?.deskEntrance == entrance { self?.deskEntrance = nil }
            }
        }

        let focus = parkedFocus.flatMap { pane in surfaceTree.contains(where: { $0 === pane }) ? pane : nil }
            ?? focusedPane
        parkedFocus = nil
        if let focus {
            let target = paneOnShow(focus)
            let responder: NSView? = target.surfaceView ?? target.viewerView
            if let window, let responder, responder.window === window {
                // Now, before the content's first layout in the window: with
                // no first responder there, SwiftUI's focused value reports
                // the LAST terminal, which became the focused surface and
                // brought its stacked run out — then the restore put the
                // first run back, every blade gliding out and back in.
                window.makeFirstResponder(responder)
            } else if key {
                // Not laid out yet (a workspace shown as it opens).
                Ghostty.moveFocus(to: target)
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.syncFocusToSurfaceTree()
            self?.publishFocusedPane()
        }
    }

    /// Become able to load a window of its own (there is none to share).
    func leavePark() {
        guard isParked else { return }
        setParked(false)
    }

    /// Show this workspace's own window: the first workspace's, or one
    /// promoted after the window closed under the others.
    func presentOwnWindow(inBackground: Bool) {
        if heldWindow == nil {
            // A workspace that once held the window (and gave it up) is
            // "loaded" to AppKit with no window: load a new one.
            windowWillLoad()
            loadWindow()
            if heldWindow != nil { windowDidLoad() }
        }
        guard let window = window as? TerminalWindow else { return }
        applyInitialFrame()
        if inBackground {
            Self.orderInBackground(window)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The last workspace closes the window itself.
    func closePhysicalWindow() {
        guard let window = heldWindow, !isParked else { return }
        window.close()
    }

    /// A parked workspace closes: everything a window's close does, with no
    /// window (`didClose(window:)`).
    func workspaceWillClose() {
        guard isParked else { return }
        didClose(window: nil)
        parkedContainer = nil
        parkedFocus = nil
    }

    // MARK: Tabs

    /// `goto_tab` in single-window mode: the workspaces in the sidebar's
    /// order. 1-based index, or previous/next/last.
    func gotoWorkspace(_ tabIndex: Int32, host: WorkspaceHost) {
        let order = Self.sidebarOrder(host.workspaces)
        guard !order.isEmpty else { return }
        let target: TerminalController?
        switch tabIndex {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: target = host.neighbor(offset: -1, in: order)
        case GHOSTTY_GOTO_TAB_NEXT.rawValue: target = host.neighbor(offset: 1, in: order)
        case GHOSTTY_GOTO_TAB_LAST.rawValue: target = order.last
        default:
            guard tabIndex >= 1 else { return }
            target = order[min(Int(tabIndex - 1), order.count - 1)]
        }
        if let target { host.show(target) }
    }

    /// `controllers` as the sidebar's all-windows list orders them.
    static func sidebarOrder(_ controllers: [TerminalController]) -> [TerminalController] {
        let byID = Dictionary(
            controllers.map { ($0.paneSidebarState.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        let titled = controllers.map {
            (id: $0.paneSidebarState.windowID, title: PaneSidebarText.windowTitle(of: $0))
        }
        return PaneSidebarWindowGrouping
            .sections(titled, order: PaneSidebarSharedState.shared.windowOrder,
                      opened: openedOrders(controllers))
            .flatMap { $0.windows.compactMap { byID[$0.id] } }
    }
}

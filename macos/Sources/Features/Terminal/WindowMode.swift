import AppKit
import SwiftUI
import GhosttyKit
import OSLog

/// `macos-window-mode`: every terminal window its own `NSWindow`
/// (`separate`), or all of them workspaces of one (`single`).
///
/// Read once, when the app starts: a window's controller is built for one
/// mode or the other, so a change in the config takes effect at the next
/// launch — where the windows that were open come back in the new mode
/// (the session layout is the same either way). See
/// docs/reference/window-modes.md.
@MainActor
enum WindowMode {
    private static var latched: Ghostty.Config.MacOSWindowMode?

    /// Tests only: the mode, whatever the config says.
    static var overrideForTesting: Ghostty.Config.MacOSWindowMode?

    static var current: Ghostty.Config.MacOSWindowMode {
        if let overrideForTesting { return overrideForTesting }
        if let latched { return latched }
        guard let delegate = NSApp.delegate as? AppDelegate else { return .separate }
        let mode = delegate.ghostty.config.macosWindowMode
        latched = mode
        return mode
    }

    static var isSingle: Bool { current == .single }
}

/// Single-window mode: the one window, and the workspaces that take turns
/// in it.
///
/// A workspace is what a window is in `separate` mode — a
/// `TerminalController` with its split tree, pane layout, stash, name,
/// title, gradient and focus — and the rule is that it stays exactly that:
/// **every workspace keeps its own controller; only the `NSWindow` is
/// shared.** The window belongs to the workspace on show (`active`). Every
/// other workspace is **parked**: its controller's `window` is nil, its
/// content view is out of the window and kept by the controller, and its
/// terminals are told they cannot be seen. Switching hands the window from
/// one controller to the other and swaps the content view — nothing is
/// rebuilt, no process is touched, no second `NSWindow` exists.
///
/// So to the rest of the app a parked workspace is a terminal window that
/// has no `NSWindow` right now. Code that goes from a controller to its
/// window finds none and skips its window work; code that goes the other
/// way — "every terminal window", "the window this pane is in" — must ask
/// here (`BaseTerminalController.everyController`, `.owner(of:)`,
/// `TerminalController.all`) rather than `NSApp.windows` or
/// `view.window?.windowController`, which only know the workspace on show.
@MainActor
final class WorkspaceHost {
    static let shared = WorkspaceHost()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.dzearing.ghoztty",
        category: "WindowMode")

    /// Every open workspace, the one on show first, then most recently
    /// shown first. Strong: a parked controller has no window to keep it.
    private(set) var workspaces: [TerminalController] = []

    /// The workspace that has the window.
    private(set) weak var active: TerminalController?

    /// The workspace that will load the window, before there is one: the
    /// first controller made while no workspace has it.
    private weak var loader: TerminalController?

    /// A controller being built will be the loader (`startsParked` said
    /// so) and has not been admitted yet.
    private var loaderReserved = false

    /// The one window, once a workspace has loaded it.
    var window: NSWindow? {
        guard let active, !active.isParked, active.isWindowLoaded else { return nil }
        return active.window
    }

    /// Posted (object: the workspace now on show) after a switch.
    static let didSwitchNotification = Notification.Name("com.dzearing.ghoztty.workspaceDidSwitch")

    private init() {}

    // MARK: Membership

    /// Asked by a controller being built, before anything can touch its
    /// window: whether it starts parked. All but the first do; the first
    /// loads the window, as a controller always has.
    func startsParked() -> Bool {
        if active == nil && loader == nil && !loaderReserved {
            loaderReserved = true
            return false
        }
        return true
    }

    /// The controller joins, as `startsParked` told it.
    func admit(_ controller: TerminalController, parked: Bool) {
        workspaces.removeAll { $0 === controller }
        workspaces.append(controller)
        if !parked {
            loaderReserved = false
            loader = controller
        }
    }

    func manages(_ controller: BaseTerminalController) -> Bool {
        workspaces.contains { $0 === controller }
    }

    /// The workspace's window loaded (the loader's, or one promoted after
    /// the window closed under the others).
    func didLoadWindow(_ controller: TerminalController) {
        guard manages(controller) else { return }
        if loader === controller { loader = nil }
        guard active == nil else { return }
        active = controller
        moveToFront(controller)
        refreshWindowActivity()
    }

    private func moveToFront(_ controller: TerminalController) {
        guard let index = workspaces.firstIndex(where: { $0 === controller }), index != 0 else { return }
        workspaces.remove(at: index)
        workspaces.insert(controller, at: 0)
    }

    // MARK: Presenting

    /// A new workspace's first presentation: `showWindow` when it should
    /// come forward, else in the background — which, with a workspace
    /// already on show, is staying parked.
    func present(_ controller: TerminalController, activate: Bool) {
        guard manages(controller) else { return }
        if activate {
            show(controller)
            return
        }
        if !controller.isParked {
            // The loader: the window, shown without taking focus.
            controller.presentOwnWindow(inBackground: true)
            return
        }
        if window == nil && loader == nil {
            // Nothing has the window and nothing is about to: this one
            // takes it.
            promote(controller, inBackground: true)
            return
        }
        prepareParked(controller)
    }

    /// Give a parked workspace a window of its own: there is none, and no
    /// loader to make one.
    private func promote(_ controller: TerminalController, inBackground: Bool) {
        loader = controller
        controller.leavePark()
        controller.presentOwnWindow(inBackground: inBackground)
    }

    /// A parked workspace's content at the size it would have on show, so
    /// its terminals are never sized to a placeholder.
    private func prepareParked(_ controller: TerminalController) {
        guard controller.isParked else { return }
        let shown = active?.contentContainer
        controller.prepareParkedContent(
            size: shown?.frame.size,
            safeArea: shown?.safeAreaInsets)
    }

    /// Put `controller` on show in the window. `makeKey`: bring the window
    /// forward too (a click, `--focus`); false leaves it where it is (the
    /// workspace on show closed and this one takes its place).
    ///
    /// Refused — false — while a sheet is up on the window: the sheet
    /// belongs to the workspace on show and has to be answered there.
    /// `force` is for the close that the sheet itself just confirmed.
    @discardableResult
    func show(_ controller: TerminalController, makeKey: Bool = true, force: Bool = false) -> Bool {
        guard manages(controller) else { return false }

        // No window yet: whoever is to load it does, then this one takes it.
        guard let from = active, let window = self.window else {
            if controller.isParked {
                if let loader, loader !== controller {
                    loader.presentOwnWindow(inBackground: true)
                    guard self.window != nil else { return false }
                    return show(controller, makeKey: makeKey, force: force)
                }
                promote(controller, inBackground: !makeKey)
            } else {
                controller.presentOwnWindow(inBackground: !makeKey)
            }
            return true
        }

        if from === controller {
            if makeKey { window.makeKeyAndOrderFront(nil) }
            return true
        }

        if window.attachedSheet != nil && !force {
            Self.logger.notice("workspace switch refused: a sheet is up on the window")
            NSSound.beep()
            return false
        }

        let wasKey = window.isKeyWindow
        // A workspace laid out before (parked a while) is brought to the
        // window's size; one never laid out (Cmd-N's) is laid out once, in
        // the window — laying it out off screen first doubled its cost.
        if controller.parkedContainer != nil {
            prepareParked(controller)
        }

        // Out with the old: it keeps its content view, focus and state.
        let leavingShade = from.deskVariant
        let style = from.surrenderWindow()
        controller.adoptWindow(window, fullscreen: style)

        active = controller
        moveToFront(controller)

        from.windowDidPark()
        controller.windowDidUnpark(key: wasKey || makeKey, from: leavingShade)
        refreshWindowActivity()

        if makeKey { window.makeKeyAndOrderFront(nil) }

        // Which workspace is on show is part of the saved layout.
        for workspace in [from, controller] where workspace.sessionLayoutEntryID != nil {
            SessionLayoutManifest.shared.scheduleSync(workspace)
        }
        PaneRoster.shared.changed()
        NotificationCenter.default.post(name: Self.didSwitchNotification, object: controller)
        Self.logger.info("workspace switch: \(from.windowName, privacy: .public) -> \(controller.windowName, privacy: .public)")
        return true
    }

    /// The workspace `offset` places from the one on show, in `order` —
    /// the sidebar's — wrapping (next/previous tab).
    func neighbor(offset: Int, in order: [TerminalController]) -> TerminalController? {
        guard let active, let index = order.firstIndex(where: { $0 === active }), order.count > 1 else {
            return nil
        }
        let count = order.count
        return order[((index + offset) % count + count) % count]
    }

    // MARK: Closing

    /// Close a workspace. The one on show hands the window to the next
    /// most recently shown; the last one closes the window itself.
    /// Returns false when the window closed with it.
    @discardableResult
    func close(_ controller: TerminalController) -> Bool {
        guard manages(controller) else { return true }

        if controller === active || (!controller.isParked && controller.isWindowLoaded) {
            if let next = workspaces.first(where: { $0 !== controller }), self.window != nil {
                show(next, makeKey: false, force: true)
            } else {
                // The last workspace: the window goes with it
                // (`windowDidClose`, from its `windowWillClose`).
                controller.closePhysicalWindow()
                return false
            }
        }

        if loader === controller { loader = nil }
        workspaces.removeAll { $0 === controller }
        controller.workspaceWillClose()
        refreshWindowActivity()
        windowStateDidChange()
        PaneRoster.shared.changed()
        return true
    }

    /// The window itself closed, with `controller` on show. Every other
    /// workspace is still open: the next one loads a window of its own
    /// (unless the app is on its way out).
    func windowDidClose(_ controller: TerminalController) {
        workspaces.removeAll { $0 === controller }
        if loader === controller { loader = nil }
        guard active === controller || active == nil else { return }
        active = nil

        let delegate = NSApp.delegate as? AppDelegate
        guard delegate?.isQuitting != true, delegate?.isSigningOut != true,
              let next = workspaces.first else { return }
        DispatchQueue.main.async { [weak self, weak next] in
            guard let self, let next, self.window == nil, self.manages(next) else { return }
            self.promote(next, inBackground: false)
        }
    }

    // MARK: Restoration

    /// What AppKit restoration saves of the window changed: which
    /// workspaces there are, or one's tree. The window is restorable while
    /// any workspace is (`TerminalController.window(_:willEncodeRestorableState:)`).
    func windowStateDidChange() {
        guard let window else { return }
        window.isRestorable = workspaces.contains(where: \.isAppKitRestorable)
        window.invalidateRestorableState()
    }

    // MARK: Activity

    /// The window's `AXWindowActivityState` is the most urgent of its
    /// workspaces': a parked workspace waiting on a question is still this
    /// window waiting on one.
    func refreshWindowActivity() {
        guard let terminalWindow = window as? TerminalWindow else { return }
        let states = workspaces.map(\.activityState)
        let rolledUp: Ghostty.ActivityState =
            states.contains(.needsInput) ? .needsInput : states.contains(.busy) ? .busy : .idle
        if terminalWindow.activityState != rolledUp {
            terminalWindow.activityState = rolledUp
        }
    }

    // MARK: Size

    private var resizeWork: DispatchWorkItem?

    /// The window was resized: bring the parked workspaces to its size once
    /// it settles, so each is already laid out when it is next shown.
    func windowDidResize() {
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for workspace in self.workspaces where workspace.isParked {
                self.prepareParked(workspace)
            }
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Tests

    /// Tests only: forget every workspace (the controllers are the test's
    /// to close).
    func resetForTesting() {
        resizeWork?.cancel()
        resizeWork = nil
        workspaces.removeAll()
        active = nil
        loader = nil
        loaderReserved = false
    }
}

/// How the window's gradient gets from the workspace that left to the one
/// that came: the old one drawn over the new and faded out
/// (`PaneDeskBackground`).
struct PaneDeskEntrance: Equatable {
    /// The gradient of the workspace that was on show (nil: ocean).
    let from: PaneDeskVariant?
    let id = UUID()

    static let duration: TimeInterval = 0.35
}

// MARK: - Controllers, parked or not

extension BaseTerminalController {
    /// The host of this workspace, in single-window mode; nil for a window
    /// of its own (separate mode, the Quick Terminal).
    var workspaceHost: WorkspaceHost? {
        guard let controller = self as? TerminalController,
              WorkspaceHost.shared.manages(controller) else { return nil }
        return WorkspaceHost.shared
    }

    /// Raise this window — in single-window mode, put this workspace on
    /// show in the one window, and raise that. What every "go to this
    /// window" means (a sidebar click, `--focus`, `ghoztty://focus`).
    func bringForward() {
        if let host = workspaceHost, let controller = self as? TerminalController {
            host.show(controller)
        } else {
            window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Every open terminal window's controller — parked workspaces
    /// included, which `NSApp.windows` cannot see. Closed windows are left
    /// out (`windowHasClosed`). Order undefined.
    static var everyController: [BaseTerminalController] {
        dedup(
            NSApp.windows.compactMap { $0.windowController as? BaseTerminalController }
                + WorkspaceHost.shared.workspaces)
    }

    /// `everyController`, front to back: windows as AppKit orders them,
    /// then the parked workspaces, most recently shown first.
    static var everyControllerFrontToBack: [BaseTerminalController] {
        dedup(
            NSApp.orderedWindows.compactMap { $0.windowController as? BaseTerminalController }
                + WorkspaceHost.shared.workspaces)
    }

    private static func dedup(_ controllers: [BaseTerminalController]) -> [BaseTerminalController] {
        var seen = Set<ObjectIdentifier>()
        return controllers.filter { !$0.windowHasClosed && seen.insert(ObjectIdentifier($0)).inserted }
    }

    /// The window `pane` is in, parked or not. `pane.window?.windowController`
    /// only finds the workspace on show.
    static func owner(of pane: PaneView) -> BaseTerminalController? {
        if let controller = pane.contentView.window?.windowController as? BaseTerminalController,
           controller.surfaceTree.contains(where: { $0 === pane }) {
            return controller
        }
        return everyController.first { $0.surfaceTree.contains(where: { $0 === pane }) }
    }

    /// `owner(of:)` for a terminal.
    static func owner(of surface: Ghostty.SurfaceView) -> BaseTerminalController? {
        if let controller = surface.window?.windowController as? BaseTerminalController,
           controller.surfaceTree.contains(surface) {
            return controller
        }
        return everyController.first { $0.surfaceTree.contains(surface) }
    }
}

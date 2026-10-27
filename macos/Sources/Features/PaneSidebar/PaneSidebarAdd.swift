import AppKit
import GhosttyKit

/// The sidebar's + buttons: a new window (the header's), a new window in a
/// project group (a group header's), a new pane (a window row's). All three
/// are MANUAL surfaces, so they focus like Cmd-N / Cmd-D — never the CLI's
/// background-by-default policy.
extension BaseTerminalController {
    /// The header's +, and a group header's (from the group's first window,
    /// titled into it): exactly Cmd-N from `parent`'s focused pane — its
    /// inherited config (so its working directory, per
    /// `window-inherit-working-directory`), a random gradient, and a remote
    /// parent's machine. `title` pins the new window's title, as
    /// `+new-window --title` does.
    static func newWindowFromSidebar(
        _ ghostty: Ghostty.App,
        from parent: BaseTerminalController?,
        title: String? = nil
    ) {
        var config: Ghostty.SurfaceConfiguration?
        if let surface = parent?.focusedSurface?.surface {
            config = Ghostty.SurfaceConfiguration(
                from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_WINDOW))
        }
        TerminalController.newWindowInheritingRemote(
            ghostty,
            withBaseConfig: PaneDeskVariant.forNewWindow(config, style: ghostty.config.macosPaneStyle),
            from: parent?.window
        ) { controller in
            if let title { controller.setWindowTitle(title) }
        }
    }

    /// A project group header's +: a new window titled into the group under
    /// a free placeholder name (`PaneSidebarNewWindowName`), opened as Cmd-N
    /// from `first` — the group's first window as listed — so it starts in
    /// that window's focused pane's directory (on its machine, if remote).
    /// Names are checked against every window at click time, not the list's
    /// last render, so two quick clicks never share one.
    static func newWindowInGroupFromSidebar(
        _ ghostty: Ghostty.App,
        project: String,
        from first: BaseTerminalController?
    ) {
        let titles = NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .map { PaneSidebarText.windowTitle(of: $0) }
        newWindowFromSidebar(
            ghostty, from: first,
            title: PaneSidebarNewWindowName.title(project: project, existing: titles))
    }

    /// A window row's +: split this window's focused pane the way the user
    /// last split one by hand (`PaneSplitMemory`), as Cmd-D would — raising
    /// the window first, so the new pane is focused where the user sees it.
    func addPaneFromSidebar() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        splitFocusedPane(PaneSplitMemory.lastManual)
    }

    /// Split the focused pane as the Split menu items and keybinds do: a
    /// viewer pane directly, a terminal through the core (so it inherits the
    /// pane's config and comes back as `ghosttyNewSplit`).
    func splitFocusedPane(_ direction: SplitTree<PaneView>.NewDirection) {
        if let pane = focusedViewerPane {
            PaneSplitMemory.noteManualSplit(direction)
            newTerminalSplit(atPane: pane, direction: direction, baseConfig: splitConfigFromViewer(pane))
            return
        }
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: direction.ghosttyDirection)
    }
}

/// The direction of the last split made by hand — a keybind, the Split menu,
/// the palette, a pane's context menu, the sidebar's + — app-wide, for the
/// window row's + to repeat. Programmatic splits (`ghoztty +split`,
/// AppleScript, App Intents) call `newSplit` directly and never get here, so
/// an agent laying out panes doesn't skew it. Defaults to right.
@MainActor
enum PaneSplitMemory {
    private(set) static var lastManual: SplitTree<PaneView>.NewDirection = .right

    static func noteManualSplit(_ direction: SplitTree<PaneView>.NewDirection) {
        lastManual = direction
    }

    /// Tests only: back to the default.
    static func reset() { lastManual = .right }
}

extension SplitTree<PaneView>.NewDirection {
    var ghosttyDirection: ghostty_action_split_direction_e {
        switch self {
        case .left: GHOSTTY_SPLIT_DIRECTION_LEFT
        case .right: GHOSTTY_SPLIT_DIRECTION_RIGHT
        case .down: GHOSTTY_SPLIT_DIRECTION_DOWN
        case .up: GHOSTTY_SPLIT_DIRECTION_UP
        }
    }
}

/// A project group's +: the new window's title — `<project>: new`, or the
/// first free `new-2`, `new-3`, … — so it lands in the group under a name
/// no other window has.
enum PaneSidebarNewWindowName {
    static let placeholder = "new"

    static func title(project: String, existing: [String]) -> String {
        let taken = Set(existing)
        let base = "\(project): \(placeholder)"
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

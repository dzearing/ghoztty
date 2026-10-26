import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // Window-level title override (pins the titlebar over any tab/pane
        // title). Optional so version-7 archives decode fine (missing ⇒ nil).
        let windowTitleOverride: String?

        // The pane sidebar's layout flags. The STASH itself rides in
        // `surfaceTree` (SplitTree encodes it). Optional: older archives
        // decode with nil and take the defaults for new windows.
        // `paneSidebarPinned` keeps the name it had when the expanded panel
        // was called "pinned": true is expanded, false collapsed — the same
        // meaning, so archives from either side of the rename decode as-is.
        let paneSidebarPinned: Bool?
        let paneSidebarHidden: Bool?
        // The sidebar's own order of the panes (`PaneSidebarState.order`), as
        // pane ids. Optional/additive like the flags.
        let paneSidebarOrder: [UUID]?

        // The window's own gradient seed (`--color=random`, elevated style).
        let deskVariant: PaneDeskVariant?

        init(
            focusedSurface: String?,
            surfaceTree: SplitTree<ViewType>,
            effectiveFullscreenMode: FullscreenMode?,
            tabColor: TerminalTabColor?,
            titleOverride: String?,
            windowTitleOverride: String? = nil,
            paneSidebarPinned: Bool? = nil,
            paneSidebarHidden: Bool? = nil,
            paneSidebarOrder: [UUID]? = nil,
            deskVariant: PaneDeskVariant? = nil,
        ) {
            self.focusedSurface = focusedSurface
            self.surfaceTree = surfaceTree
            self.effectiveFullscreenMode = effectiveFullscreenMode
            self.tabColor = tabColor
            self.titleOverride = titleOverride
            self.windowTitleOverride = windowTitleOverride
            self.paneSidebarPinned = paneSidebarPinned
            self.paneSidebarHidden = paneSidebarHidden
            self.paneSidebarOrder = paneSidebarOrder
            self.deskVariant = deskVariant
        }
    }
}

extension TerminalRestorableState.InternalState where ViewType == PaneView {
    init(from controller: TerminalController) {
        // Window state is only ever encoded on the main thread.
        let sidebar = MainActor.assumeIsolated {
            (controller.paneSidebarState.isExpanded, controller.paneSidebarState.isHidden,
             controller.deskVariant, controller.paneSidebarPersistedOrder)
        }
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: (controller.window as? TerminalWindow)?.tabColor,
            titleOverride: controller.titleOverride,
            windowTitleOverride: controller.windowTitleOverride,
            paneSidebarPinned: sidebar.0,
            paneSidebarHidden: sidebar.1,
            paneSidebarOrder: sidebar.3,
            deskVariant: sidebar.2,
        )
    }
}

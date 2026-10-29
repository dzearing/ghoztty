import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The drag payload for a pane. Its contents are only a type marker —
    /// the authoritative reference to the dragged pane is
    /// `PaneDragSession.shared.pane`, which is safe because pane drags are
    /// `withinApplication` only.
    static let ghosttyPaneId = UTType(exportedAs: "com.dzearing.ghoztty.paneId")
}

extension NSPasteboard.PasteboardType {
    static let ghosttyPaneId = NSPasteboard.PasteboardType(UTType.ghosttyPaneId.identifier)
}

/// The one in-flight pane drag, app-wide.
///
/// A drag crosses windows, so no window can own it. The drag SOURCE feeds it
/// screen points (`NSDraggingSource` reports those continuously and across
/// every window for free); it resolves them through `PaneDropResolver` and
/// publishes the result; every window's overlay observes it and draws the
/// feedback for its own frame.
///
/// Resolution deliberately happens on the MOVE feed rather than in a drop
/// destination: a destination sees only its own view, which can express
/// neither a window edge nor the tab bar (a private view in the titlebar,
/// outside the SwiftUI tree) nor which of two overlapping windows won.
@MainActor
final class PaneDragSession: ObservableObject {
    static let shared = PaneDragSession()

    /// The pane being dragged, or nil when no drag is in flight.
    @Published private(set) var pane: PaneView?

    /// What would happen if the pane were released right now.
    @Published private(set) var target: PaneDropTarget?

    /// The window whose tab is currently being dwelt on, for the pulse.
    @Published private(set) var hoveredTab: (window: PaneDropWindowRef, index: Int)?

    private weak var source: BaseTerminalController?
    private var candidates: [PaneDropCandidate] = []
    /// The drag is a strip's: it has the targets of a pane put away in its
    /// row (`PaneDropResolver.resolveBlade`), not a pane's.
    private(set) var isBlade = false
    /// The drag is a pane-sidebar row's, moved up and down its list: it only
    /// ever means a place in that list or its tray (`listPoint`), wherever it
    /// is let go — never the grid, another window, or a new one.
    private(set) var isListDrag = false
    private var dwellTimer: Timer?
    private var dwellKey: String?

    /// How long the pointer must rest on a tab before that tab is selected so
    /// the drag can continue into its layout.
    static let tabDwellInterval: TimeInterval = 0.5

    var isDragging: Bool { pane != nil }

    /// True when `pane` is the one being dragged — the source pane dims and
    /// stops being its own drop target for the duration.
    func isDragging(_ candidate: PaneView) -> Bool {
        pane === candidate
    }

    // MARK: Lifecycle

    func begin(pane: PaneView, from controller: BaseTerminalController, isBlade: Bool = false,
               isListDrag: Bool = false) {
        self.pane = pane
        self.source = controller
        self.isBlade = isBlade
        self.isListDrag = isListDrag
        self.target = nil
        self.hoveredTab = nil
        // As for a sidebar item drag: the rows and tiles it passes don't
        // light up under the pointer.
        HoverTrackingView.isHeld = true
        refreshCandidates()
    }

    func update(screenPoint: CGPoint) {
        guard let pane else { return }

        // Windows move, resize, and get created mid-drag (a dwell switches
        // tabs), so the geometry is re-read rather than snapshotted at begin.
        refreshCandidates()

        // Published only when it changes: every window's pane sidebar
        // observes this session, and a same-value set still redraws them all
        // on every pointer move.
        if isListDrag {
            let target = listTarget(screenPoint: screenPoint, dragged: pane.id)
            if target != self.target { self.target = target }
            return
        }

        let target = PaneDropResolver.resolve(
            screenPoint: screenPoint,
            candidates: candidates,
            dragged: pane.id,
            blade: isBlade ? bladeGeometry(of: pane) : nil)
        if target != self.target { self.target = target }

        if case .tile(let frame) = target {
            TileDropPreview.shared.show(frame)
        } else {
            TileDropPreview.shared.hide()
        }
        updateTabCaret()
        // A strip has no tab-bar targets, so nothing to dwell on either.
        if !isBlade { updateDwell(screenPoint: screenPoint) }
    }

    /// Finish the drag. `commit` is false when the user cancelled (Escape).
    func end(commit: Bool) {
        defer { reset() }
        guard commit, let pane, let source, let target else { return }
        PaneMoveCoordinator.apply(target, pane: pane, from: source)
    }

    /// A list drag's target: the pointer held to its own window's sidebar —
    /// at the bar's middle, and inside its top and bottom — and resolved
    /// against that sidebar alone. So letting go beside the bar, over the
    /// grid or past the window, is the place in the list (or tray) level
    /// with the pointer, as the row the pointer is dragging shows it.
    private func listTarget(screenPoint: CGPoint, dragged: UUID) -> PaneDropTarget? {
        guard let source,
              let own = candidates.first(where: { $0.window == PaneDropWindowRef(source) }),
              let sidebar = own.sidebar
        else { return nil }
        let rect = sidebar.rect
        let point = CGPoint(
            x: rect.midX,
            y: Swift.min(Swift.max(screenPoint.y, rect.minY + 1), rect.maxY - 1))
        return PaneDropResolver.sidebarHit(
            screenPoint: point,
            candidates: [PaneDropCandidate(
                window: own.window, zOrder: 0, contentRect: own.contentRect,
                paneRects: own.paneRects,
                sidebar: .init(rect: rect, paneRows: sidebar.paneRows, stashRows: sidebar.stashRows,
                               trayTop: sidebar.trayTop))],
            dragged: dragged)
    }

    private func reset() {
        cancelDwell()
        removeTabCaret()
        TileDropPreview.shared.hide()
        pane = nil
        source = nil
        isBlade = false
        isListDrag = false
        target = nil
        hoveredTab = nil
        candidates = []
        HoverTrackingView.isHeld = false
    }

    // MARK: Feedback queries

    /// The target as it applies to one window, for that window's overlay.
    func target(for controller: BaseTerminalController) -> PaneDropTarget? {
        guard let target, target.window == PaneDropWindowRef(controller) else { return nil }
        return target
    }

    // MARK: Tab bar caret

    /// The insertion caret drawn between tab buttons while a `.newTab` drop
    /// is pending.
    ///
    /// It is a plain `NSView` added to the private `NSTabBar` rather than a
    /// SwiftUI overlay because the tab bar lives in the titlebar, outside the
    /// window's content view and therefore outside every SwiftUI hierarchy
    /// this app owns. Adding a subview is the only way to paint there, and it
    /// is removed the moment the target changes, so nothing survives the drag.
    private var tabCaret: NSView?

    private func updateTabCaret() {
        guard case .newTab(let windowRef, let index) = target,
              let controller = PaneMoveCoordinator.controller(for: windowRef),
              let window = controller.window,
              let tabBarView = window.tabBarView
        else {
            removeTabCaret()
            return
        }

        let buttons = window.tabButtonsInVisualOrder()
        // Before the button at `index`, or after the last one when the drop
        // would append.
        let x: CGFloat = if index < buttons.count {
            buttons[index].frame.minX
        } else {
            buttons.last?.frame.maxX ?? tabBarView.bounds.minX
        }

        let caret = tabCaret ?? {
            let view = NSView(frame: .zero)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            view.layer?.cornerRadius = 1.5
            tabCaret = view
            return view
        }()

        if caret.superview !== tabBarView {
            caret.removeFromSuperview()
            tabBarView.addSubview(caret)
        }
        caret.frame = NSRect(
            x: max(tabBarView.bounds.minX, x - 1.5),
            y: tabBarView.bounds.minY + 2,
            width: 3,
            height: max(0, tabBarView.bounds.height - 4))
    }

    private func removeTabCaret() {
        tabCaret?.removeFromSuperview()
        tabCaret = nil
    }

    // MARK: Dwell

    private func updateDwell(screenPoint: CGPoint) {
        let hit = PaneDropResolver.hoveredTab(screenPoint: screenPoint, candidates: candidates)
        hoveredTab = hit

        guard let hit else {
            cancelDwell()
            return
        }

        // Restart only when the pointer moves to a DIFFERENT tab, so resting
        // on one tab is one continuous dwell rather than a timer reset per
        // mouse-moved event.
        let key = "\(hit.window)#\(hit.index)"
        guard key != dwellKey else { return }
        cancelDwell()
        dwellKey = key

        dwellTimer = Timer.scheduledTimer(
            withTimeInterval: Self.tabDwellInterval,
            repeats: false
        ) { _ in
            Task { @MainActor in
                PaneDragSession.shared.selectDwelledTab(hit)
            }
        }
    }

    private func selectDwelledTab(_ hit: (window: PaneDropWindowRef, index: Int)) {
        guard isDragging else { return }
        guard let controller = PaneMoveCoordinator.controller(for: hit.window),
              let window = controller.window,
              let tabGroup = window.tabGroup,
              hit.index < tabGroup.windows.count
        else { return }
        tabGroup.selectedWindow = tabGroup.windows[hit.index]
        // The revealed tab is a different controller with a different
        // layout, so the next move resolves against fresh geometry.
        refreshCandidates()
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        dwellKey = nil
    }

    // MARK: Geometry

    /// Where a strip being dragged can go: the slots of the row it is
    /// minimized in, read off the cards and strips on screen; and the screens.
    private func bladeGeometry(of pane: PaneView) -> PaneBladeDrag? {
        guard let source, let window = source.window,
              let stack = source.paneStackState.stackMinimizing(pane.id)
        else { return nil }
        let tabs = PaneStackTabView.all(in: window)
        let panes = Dictionary(uniqueKeysWithValues: source.surfaceTree.visibleLeaves.map { ($0.id, $0) })
        var items: [(rect: CGRect, panes: Set<UUID>)] = []
        for item in stack.items {
            let rects = item.compactMap { id -> CGRect? in
                let view: NSView? = tabs[id] ?? panes[id]?.contentView
                guard let view, view.window === window else { return nil }
                return window.convertToScreen(view.convert(view.bounds, to: nil))
            }
            guard let first = rects.first else { return nil }
            items.append((rects.dropFirst().reduce(first) { $0.union($1) }, Set(item)))
        }
        return PaneBladeDrag(
            window: PaneDropWindowRef(source),
            slots: PaneBladeDrag.slots(items: items, direction: stack.direction, dragged: pane.id),
            screens: NSScreen.screens.map(\.visibleFrame))
    }

    private func refreshCandidates() {
        var result: [PaneDropCandidate] = []
        for (index, window) in NSApp.orderedWindows.enumerated() {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            guard let candidate = Self.candidate(for: controller, zOrder: index) else { continue }
            result.append(candidate)
        }
        candidates = result
    }

    /// Read one window's live geometry in screen coordinates.
    ///
    /// Returns nil for a window with nothing droppable on screen: hidden, or
    /// a background tab (whose panes are not mounted, so a drop onto them
    /// would target something invisible).
    private static func candidate(
        for controller: BaseTerminalController,
        zOrder: Int
    ) -> PaneDropCandidate? {
        guard let window = controller.window, window.isVisible else { return nil }
        if let tabGroup = window.tabGroup,
           let selected = tabGroup.selectedWindow,
           selected !== window {
            return nil
        }

        var paneRects: [(id: UUID, rect: CGRect)] = []
        // A pane tucked into a stack shows only its tab, and that is what a
        // drop can land on: the rest of it is under the cards in front.
        let tabs = PaneStackTabView.all(in: window)
        // Only panes ON SCREEN are drop targets: a stashed pane is mounted
        // (hidden, in its slot) but nothing can land on it.
        for pane in controller.surfaceTree.visibleLeaves {
            let view = tabs[pane.id] ?? pane.contentView
            // A pane that is not mounted (zoomed out, hero mode) has no
            // window and no meaningful frame.
            guard view.window === window else { continue }
            let inWindow = view.convert(view.bounds, to: nil)
            paneRects.append((id: pane.id, rect: window.convertToScreen(inWindow)))
        }
        guard let first = paneRects.first else { return nil }

        // The content rect is the union of the panes rather than the window's
        // own content view: that IS the split-tree area by definition, so the
        // edge band lands on the splits and not on a titlebar accessory.
        let contentRect = paneRects.dropFirst().reduce(first.rect) { $0.union($1.rect) }

        var tabBarRect: CGRect?
        var tabButtonRects: [CGRect] = []
        if let tabBarView = window.tabBarView, let tabBarWindow = tabBarView.window {
            tabBarRect = tabBarWindow.convertToScreen(tabBarView.convert(tabBarView.bounds, to: nil))
            tabButtonRects = window.tabButtonsInVisualOrder().map { button in
                tabBarWindow.convertToScreen(button.convert(button.bounds, to: nil))
            }
        }

        return PaneDropCandidate(
            window: PaneDropWindowRef(controller),
            zOrder: zOrder,
            contentRect: contentRect,
            paneRects: paneRects,
            tabBarRect: tabBarRect,
            tabButtonRects: tabButtonRects,
            sidebar: controller.paneSidebarHost?.dropGeometry())
    }
}

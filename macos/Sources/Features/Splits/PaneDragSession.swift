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

    func begin(pane: PaneView, from controller: BaseTerminalController) {
        self.pane = pane
        self.source = controller
        self.target = nil
        self.hoveredTab = nil
        refreshCandidates()
    }

    func update(screenPoint: CGPoint) {
        guard let pane else { return }

        // Windows move, resize, and get created mid-drag (a dwell switches
        // tabs), so the geometry is re-read rather than snapshotted at begin.
        refreshCandidates()

        target = PaneDropResolver.resolve(
            screenPoint: screenPoint,
            candidates: candidates,
            dragged: pane.id)

        updateTabCaret()
        updateDwell(screenPoint: screenPoint)
    }

    /// Finish the drag. `commit` is false when the user cancelled (Escape).
    func end(commit: Bool) {
        defer { reset() }
        guard commit, let pane, let source, let target else { return }
        PaneMoveCoordinator.apply(target, pane: pane, from: source)
    }

    private func reset() {
        cancelDwell()
        removeTabCaret()
        pane = nil
        source = nil
        target = nil
        hoveredTab = nil
        candidates = []
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
        for pane in controller.surfaceTree {
            let view = pane.contentView
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
            tabButtonRects: tabButtonRects)
    }
}

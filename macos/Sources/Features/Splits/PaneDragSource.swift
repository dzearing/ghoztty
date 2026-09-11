import AppKit
import SwiftUI

/// The grabbable region that starts a pane drag.
///
/// One drag source serves both entry points — the persistent header in
/// rearrange mode and the hover-revealed grab handle outside it — because the
/// mode changes affordances, never behavior. Whatever starts the drag, the
/// same `PaneDragSession` resolves it and the same `PaneMoveCoordinator`
/// applies it.
struct PaneDragSource: NSViewRepresentable {
    let pane: PaneView

    /// Reflects whether a drag session is currently active.
    @Binding var isDragging: Bool

    /// Reflects whether the mouse is hovering this region.
    @Binding var isHovering: Bool

    func makeNSView(context: Context) -> PaneDragSourceView {
        let view = PaneDragSourceView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: PaneDragSourceView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: PaneDragSourceView) {
        view.pane = pane
        view.onDragStateChanged = { dragging in
            isDragging = dragging
        }
        view.onHoverChanged = { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

/// The `NSView` that owns the drag lifecycle.
///
/// `NSDraggingSession` is kept as the transport rather than a hand-rolled
/// mouse loop because it already provides the snapshot preview, Escape
/// cancellation, spring-back, and — the part that matters most here —
/// a continuous screen-point feed that spans every window on the desktop.
/// That feed is what makes cross-window dragging work without any window
/// needing to know about the drag.
final class PaneDragSourceView: NSView, NSDraggingSource {
    /// Scale factor applied to the pane snapshot for the drag preview image.
    private static let previewScale: CGFloat = 0.2

    var pane: PaneView?
    var onDragStateChanged: ((Bool) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    /// Whether we are inside a drag (between `willBegin` and `endedAt`).
    private var isTracking: Bool = false

    private var escapeMonitor: Any?
    private var dragCancelledByEscape: Bool = false

    deinit {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        // Get the mouse event before the window's own drag handler, or
        // grabbing a header would move the WINDOW.
        true
    }

    override func mouseDown(with event: NSEvent) {
        // Deliberately not calling super: consuming mouseDown keeps the
        // window drag handler out of it. The drag starts in mouseDragged.
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isTracking ? .closedHand : .openHand)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    override func mouseDragged(with event: NSEvent) {
        guard !isTracking, let pane else { return }

        // A lone pane in the only terminal window has nowhere to go: every
        // target would either be itself or a new window holding the same pane.
        // Refusing to start that drag is clearer than starting one that can
        // only be cancelled. A lone pane with ANOTHER window open is very much
        // draggable — that is how you undo a pop-out.
        guard let controller = pane.contentView.window?.windowController
                as? BaseTerminalController else { return }
        let otherTerminalWindows = NSApp.windows.contains { window in
            window.isVisible
                && window.windowController !== controller
                && window.windowController is BaseTerminalController
        }
        guard controller.surfaceTree.isSplit || otherTerminalWindows else { return }

        // The payload is a type marker only. The authoritative reference to
        // the dragged pane lives in `PaneDragSession`, which is safe because
        // pane drags never leave the application.
        let item = NSPasteboardItem()
        item.setString(pane.id.uuidString, forType: .ghosttyPaneId)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)

        if let snapshot = pane.dragSnapshot {
            let imageSize = NSSize(
                width: snapshot.size.width * Self.previewScale,
                height: snapshot.size.height * Self.previewScale)
            let scaled = NSImage(size: imageSize)
            scaled.lockFocus()
            snapshot.draw(
                in: NSRect(origin: .zero, size: imageSize),
                from: NSRect(origin: .zero, size: snapshot.size),
                operation: .copy,
                fraction: 1.0)
            scaled.unlockFocus()

            // Centre the preview on the pointer, matching macOS tab dragging.
            let mouseLocation = convert(event.locationInWindow, from: nil)
            let origin = NSPoint(
                x: mouseLocation.x - imageSize.width / 2,
                y: mouseLocation.y - imageSize.height / 2)
            draggingItem.setDraggingFrame(
                NSRect(origin: origin, size: imageSize),
                contents: scaled)
        }

        MainActor.assumeIsolated {
            PaneDragSession.shared.begin(pane: pane, from: controller)
        }
        onDragStateChanged?(true)

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)

        // Required so `endedAt` fires immediately for a drag released outside
        // any registered destination — which is every drop over the tab bar,
        // and every drop into empty space.
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    // MARK: NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        isTracking = true
        dragCancelledByEscape = false
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dragCancelledByEscape = true
            }
            return event
        }
        MainActor.assumeIsolated {
            PaneDragSession.shared.update(screenPoint: screenPoint)
        }
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        NSCursor.closedHand.set()
        MainActor.assumeIsolated {
            PaneDragSession.shared.update(screenPoint: screenPoint)
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }

        // `endedAt` is the SINGLE commit site, whatever `operation` says. A
        // drop over the tab bar lands outside every registered destination
        // and reports `[]`, and a drop over a pane reports `.move`; both mean
        // the same thing here, because the target was resolved from the move
        // feed and not from whoever happened to accept the drag.
        let cancelled = dragCancelledByEscape
        MainActor.assumeIsolated {
            PaneDragSession.shared.end(commit: !cancelled)
        }

        isTracking = false
        onDragStateChanged?(false)
    }
}

extension PaneView {
    /// A snapshot of the pane's mounted content, for the drag preview.
    var dragSnapshot: NSImage? {
        let view = contentView
        guard !view.bounds.isEmpty,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

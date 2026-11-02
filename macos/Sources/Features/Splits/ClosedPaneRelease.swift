import AppKit

/// Frees a closed terminal pane's core — its process (or agent session), threads
/// and render targets — once the close can no longer be undone.
///
/// Freeing used to wait for the pane's view to deinit, and a closed pane's
/// view is not let go of promptly: the last split closed in a window stays
/// referenced — through a tree node, from memory `leaks` cannot attribute
/// (SwiftUI's graph) — until that window's tree next changes shape. Its shell
/// kept running and its terminal kept its memory until some later split or
/// close (docs/reference/memory.md). Releasing on the close's own clock does
/// not depend on who still holds the view.
///
/// The undo window (`undo-timeout`) is the line: until it passes, an undo
/// puts the pane back live, process and all; after it, nothing can. A pane
/// found in any window's tree by then (undone, moved to another window) is
/// left alone.
@MainActor
enum ClosedPaneRelease {
    static func schedule(_ pane: PaneView, undoWindow: Duration) {
        guard let surface = pane.surfaceView else { return }
        let close = UUID()
        pane.pendingRelease = close
        // Just past the undo's own expiry (`ExpiringUndoManager`), so the
        // close cannot be undone by the time the pane is looked for.
        let delay = undoWindow.timeInterval + 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak pane, weak surface] in
            guard let pane, pane.pendingRelease == close else { return }
            pane.pendingRelease = nil
            guard !isInAnyWindow(pane) else { return }
            surface?.releaseClosedSurface()
        }
    }

    private static func isInAnyWindow(_ pane: PaneView) -> Bool {
        NSApp.windows.contains { window in
            guard let controller = window.windowController as? BaseTerminalController else { return false }
            return controller.surfaceTree.root?.node(view: pane) != nil
        }
    }
}

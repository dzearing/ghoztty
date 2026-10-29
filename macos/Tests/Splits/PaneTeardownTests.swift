import AppKit
import GhosttyKit
import ScreenCaptureKit
import Testing
@testable import Ghostty

/// What closing gives back. A closed window's panes — their terminals, render
/// targets and agent sessions — must actually be freed, and nothing a pane
/// leaves running (an animation clock, a detached viewer) may outlive it.
///
/// Terminals run `/bin/cat` (no shell, no session agent), as in
/// `PaneSidebarWindowTests`.
@MainActor
@Suite(.serialized)
struct PaneTeardownTests {
    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await settle(0.1)
        }
        return condition()
    }

    private func terminalPane(_ app: ghostty_app_t) -> PaneView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        return PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
    }

    private final class Weak {
        weak var object: AnyObject?
        init(_ object: AnyObject?) { self.object = object }
    }

    /// The grid hands its stack state a closure that lays the grid out again
    /// (`PaneStackState.noteGrid`), and that closure captured the state
    /// itself: the state retained itself, and through the tree every pane.
    /// Every closed window kept its terminals, their renderer threads and
    /// three window-sized GPU render targets each, for the rest of the app's
    /// life (~85 MB a window).
    @Test func closingAWindowFreesItsPanes() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var refs: [Weak] = []
        do {
            let a = terminalPane(app), b = terminalPane(app)
            let tree = try SplitTree<PaneView>(view: a).inserting(view: b, at: a, direction: .right)
            let controller = TerminalController.newWindow(ghostty, tree: tree)
            _ = await poll(timeout: 10) { controller.window?.isVisible == true }
            // Rendered at least once: the grid has noted its layout closure.
            await settle(1.0)
            #expect(controller.paneStackState.layoutGrid != nil)
            refs = [Weak(a), Weak(b), Weak(a.surfaceView), Weak(b.surfaceView),
                    Weak(controller.paneStackState), Weak(controller)]
            controller.close()
        }
        // The close's undo (`undo-timeout`, 5s by default) may hold the tree
        // until it expires; past that, nothing should.
        let freed = await poll(timeout: 12) { refs.allSatisfy { $0.object == nil } }
        #expect(freed, "still alive: \(refs.compactMap { $0.object.map { String(describing: type(of: $0)) } })")
    }

    /// A viewer built for a split that cannot go in (its anchor left the
    /// tree) is detached: otherwise its chrome's SwiftUI host — mounted in
    /// `init` — holds it back, and with it its web view and app-wide event
    /// monitor, forever.
    @Test func aViewerThatFailsToInsertIsFreed() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let a = terminalPane(app)
        let controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: a))
        defer { controller.close() }
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }

        let ref: Weak
        do {
            let stray = terminalPane(app) // never in this window's tree
            let viewer = ViewerView(location: "about:blank")
            ref = Weak(viewer)
            let pane = controller.newViewerSplit(atPane: stray, direction: .right, viewer: viewer)
            #expect(pane == nil)
        }
        #expect(await poll(timeout: 5) { ref.object == nil }, "the viewer that never went in is still alive")
    }

    /// The sidebar card's collapse/expand glide steps on a 120Hz timer that
    /// only its own end stopped. Freed mid-glide (sidebar hidden, window
    /// closed) it fired a no-op 120 times a second forever; now the timer
    /// stops itself once its glide is gone.
    @Test func aSidebarGlideFreedMidGlideStopsItsTimer() async throws {
        var timer: Timer?
        do {
            let glide = PaneSidebarCardGlide()
            glide.update(mode: .expanded, width: 240)
            glide.update(mode: .collapsed, width: 56) // a mode change: glides
            timer = Mirror(reflecting: glide).children.first { $0.label == "timer" }?.value as? Timer
            #expect(timer?.isValid == true, "the glide started its clock")
        }
        #expect(await poll(timeout: 1) { timer?.isValid == false }, "the freed glide's timer still runs")
    }

    private func capture(_ window: NSWindow) async throws -> CGImage {
        let content = try await SCShareableContent.currentProcess
        let scWindow = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let cfg = SCStreamConfiguration()
        cfg.width = Int(scWindow.frame.width * 2)
        cfg.height = Int(scWindow.frame.height * 2)
        cfg.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: cfg)
    }

    /// The share of sampled pixels whose brightness differs by more than a
    /// hair: 0 for the same picture, near 1 for a blank one against text.
    private func changed(_ a: CGImage, _ b: CGImage) -> Double {
        let ra = NSBitmapImageRep(cgImage: a), rb = NSBitmapImageRep(cgImage: b)
        var n = 0, d = 0
        for y in stride(from: 0, to: min(ra.pixelsHigh, rb.pixelsHigh), by: 7) {
            for x in stride(from: 0, to: min(ra.pixelsWide, rb.pixelsWide), by: 7) {
                guard let ca = ra.colorAt(x: x, y: y), let cb = rb.colorAt(x: x, y: y) else { continue }
                n += 1
                if abs(ca.brightnessComponent - cb.brightnessComponent) > 0.06 { d += 1 }
            }
        }
        return n == 0 ? 1 : Double(d) / Double(n)
    }

    /// Occluded, a terminal frees its swap chain's render targets (three
    /// window-sized IOSurfaces) — and must still show what it showed when it
    /// comes back, before anything redraws: the layer keeps the surface on
    /// screen. Then the next output draws into fresh targets.
    @Test func anOccludedTerminalComesBackShowingItsLastFrame() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'ls -la /; cat'"
        let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: pane))
        defer { controller.close() }
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 700, height: 500))
        await settle(1.5)
        let surface = try #require(pane.surface)
        let shown = try await capture(window)

        ghostty_surface_set_occlusion(surface, false)
        await settle(0.5)
        ghostty_surface_set_occlusion(surface, true)
        await settle(0.5)
        let back = try await capture(window)
        #expect(changed(shown, back) < 0.01, "the terminal came back showing something else")

        // New output redraws: the targets are re-created at full size.
        try #require(pane.surfaceView).surfaceModel?.sendText("redrawn after occlusion\r")
        await settle(0.8)
        let redrawn = try await capture(window)
        #expect(changed(back, redrawn) > 0, "nothing drew after the terminal came back")
    }

    /// This process's physical footprint (what Activity Monitor shows), MB.
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// What occlusion gives back: every terminal of four large windows frees
    /// its three render targets while occluded, so the footprint drops by
    /// most of what the windows' targets cost (~3 x width x height x 4 bytes
    /// each). Writes the numbers to /tmp/ghoztty-occlusion-footprint.txt.
    @Test func occludedTerminalsGiveBackTheirRenderTargets() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var controllers: [TerminalController] = []
        defer { controllers.forEach { $0.close() } }
        var panes: [PaneView] = []
        for _ in 0..<4 {
            var config = Ghostty.SurfaceConfiguration()
            config.command = "/bin/sh -c 'ls -la /; cat'"
            let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
            let controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: pane))
            _ = await poll(timeout: 10) { controller.window?.isVisible == true }
            controller.window?.setContentSize(NSSize(width: 1200, height: 800))
            controllers.append(controller)
            panes.append(pane)
        }
        await settle(2)
        let surfaces = panes.compactMap { $0.surface }
        #expect(surfaces.count == 4)
        // Three cycles of occlude / show + redraw: the drop each time, and no
        // growth from cycle to cycle (targets re-created, the old ones freed).
        var log: [String] = []
        var drops: [Double] = []
        var shownAt: [Double] = []
        for cycle in 0..<3 {
            // Each terminal draws something new, so it is on fresh targets.
            panes.forEach { $0.surfaceView?.surfaceModel?.sendText("cycle \(cycle)\r") }
            await settle(1.5)
            let shown = footprintMB()
            surfaces.forEach { ghostty_surface_set_occlusion($0, false) }
            await settle(1.5)
            let hidden = footprintMB()
            surfaces.forEach { ghostty_surface_set_occlusion($0, true) }
            drops.append(shown - hidden)
            shownAt.append(shown)
            log.append("cycle \(cycle): shown \(Int(shown)) MB, occluded \(Int(hidden)) MB")
        }
        // Three 1200x800-point targets per terminal; the layer keeps the one
        // on screen alive, so at least two are given back.
        let scale = controllers.first?.window?.backingScaleFactor ?? 1
        let perTarget = 1200 * 800 * scale * scale * 4 / 1_048_576
        log.append("scale \(scale), ~\(Int(perTarget)) MB per target")
        try? (log.joined(separator: "\n") + "\n")
            .write(toFile: "/tmp/ghoztty-occlusion-footprint.txt", atomically: true, encoding: .utf8)
        for drop in drops {
            #expect(drop > 4 * 2 * perTarget * 0.66, "occluding 4 terminals gave back only \(drop) MB")
        }
        #expect(shownAt[2] - shownAt[0] < 4 * perTarget,
                "showing again grew the footprint: \(shownAt)")
    }
}

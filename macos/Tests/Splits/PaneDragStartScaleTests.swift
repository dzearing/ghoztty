import AppKit
import GhosttyKit
import SwiftUI
import Testing
@testable import Ghostty

/// Starting a pane drag at the scale of a busy Mac: 19 windows of 2–4 panes,
/// several of them HTML viewers, every pane sidebar shown, expanded, and
/// listing all windows. A drag that started in a blink with three windows
/// took seconds there.
///
/// `NSDraggingSession` waits on the physical button, so these time the half
/// of the drag before it (`PaneDragSourceView.prepareDrag`) and how long the
/// main thread stays busy after it — the redraw the drag's start sets off —
/// which is when the ghost can first appear under the pointer.
@MainActor
@Suite(.serialized)
final class PaneDragStartScaleTests {
    static let windowCount = 19

    private var opened: [TerminalController] = []
    private var docs: [URL] = []
    private let sidebar = PaneSidebarSharedState.shared
    private let saved: (hidden: Bool, expanded: Bool, all: Bool)

    init() {
        saved = (sidebar.isHidden, sidebar.isExpanded, sidebar.showsAllWindows)
    }

    deinit {
        MainActor.assumeIsolated {
            for controller in opened.reversed() where !controller.windowHasClosed {
                controller.forceCloseWindow()
            }
            for controller in opened {
                for pane in controller.surfaceTree { pane.surfaceView?.releaseClosedSurface() }
            }
            SessionLayoutManifest.shared.flushWrites()
            for doc in docs { try? FileManager.default.removeItem(at: doc) }
            sidebar.isHidden = saved.hidden
            sidebar.isExpanded = saved.expanded
            sidebar.showsAllWindows = saved.all
            WindowMode.overrideForTesting = nil
            WorkspaceHost.shared.resetForTesting()
        }
    }

    // MARK: Setup

    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await settle(0.05)
        }
        return condition()
    }

    private var ghostty: Ghostty.App {
        get throws { try #require((NSApp.delegate as? AppDelegate)?.ghostty) }
    }

    private func terminal() throws -> PaneView {
        let app = try #require(try ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        return PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
    }

    private func viewer() throws -> PaneView {
        let doc = FileManager.default.temporaryDirectory
            .appendingPathComponent("drag-scale-\(UUID().uuidString).html")
        let rows = (1...200).map { "<p>Paragraph \($0) of a page with some text in it.</p>" }.joined()
        try "<html><body><h1>Viewer</h1>\(rows)</body></html>".write(to: doc, atomically: true, encoding: .utf8)
        docs.append(doc)
        return PaneView(viewer: ViewerView(location: doc.path))
    }

    /// Window `i` has 2–4 panes; every fourth holds an HTML viewer.
    private func tree(_ index: Int) throws -> SplitTree<PaneView> {
        let first = try terminal()
        var tree = SplitTree<PaneView>(view: first)
        var last = first
        for slot in 1..<(2 + index % 3) {
            let pane = (index % 4 == 0 && slot == 1) ? try viewer() : try terminal()
            tree = try tree.inserting(view: pane, at: last, direction: slot % 2 == 1 ? .right : .down)
            last = pane
        }
        return tree
    }

    /// Opens the 19 windows, background ones first, and returns the last —
    /// the one the drag starts in.
    private func openWindows(
        count: Int = windowCount, sidebarHidden: Bool = false, allWindows: Bool = true
    ) async throws -> TerminalController {
        sidebar.isHidden = sidebarHidden
        sidebar.isExpanded = true
        sidebar.showsAllWindows = allWindows
        for index in 0..<count {
            let controller = TerminalController.newWindow(
                try ghostty, tree: try tree(index), activate: index == count - 1)
            opened.append(controller)
            if controller.isParked {
                _ = await poll(timeout: 5) { controller.contentContainer != nil }
            } else {
                _ = await poll(timeout: 10) { controller.window?.isVisible == true }
                let window = try #require(controller.window)
                window.setContentSize(NSSize(width: 1100, height: 700))
                window.setFrameOrigin(NSPoint(x: 40 + CGFloat(index * 12), y: 40 + CGFloat(index * 8)))
            }
        }
        let source = try #require(opened.last)
        source.window?.makeKeyAndOrderFront(nil)
        await settle(3)
        return source
    }

    private func sources(in view: NSView) -> [PaneDragSourceView] {
        ((view as? PaneDragSourceView).map { [$0] } ?? []) + view.subviews.flatMap { sources(in: $0) }
    }

    private func grip(of pane: PaneView, in window: NSWindow) throws -> PaneDragSourceView {
        let root = try #require(window.contentView?.superview)
        return try #require(sources(in: root).first {
            $0.pane === pane && $0.showsGrabCursor && !$0.isBlade && !$0.isListDrag
        })
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    // MARK: Measuring

    /// How long the main thread stays busy from now: a background thread pings
    /// it until a ping comes straight back, and the time to that one is how
    /// long anything on screen — the ghost included — had to wait.
    private func busyUntilIdle() async -> Double {
        let start = ContinuousClock.now
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                while true {
                    let sent = ContinuousClock.now
                    DispatchQueue.main.sync {}
                    let back = ContinuousClock.now - sent
                    if back < .milliseconds(4) || ContinuousClock.now - start > .seconds(20) {
                        continuation.resume(returning: Self.ms(ContinuousClock.now - start))
                        return
                    }
                }
            }
        }
    }

    nonisolated private static func ms(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Times one drag start in `source`: the prepare half, and the main
    /// thread's busy spell after it. Ends the drag (cancelled) after.
    private func timeDragStart(in source: TerminalController) async throws -> (prepare: Double, busy: Double) {
        let window = try #require(source.window)
        let pane = try #require(source.surfaceTree.visibleLeaves.last)
        let grip = try grip(of: pane, in: window)
        let at = grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil)

        _ = await busyUntilIdle()
        grip.mouseDown(with: try mouseEvent(.leftMouseDown, at: at, in: window))
        let started = ContinuousClock.now
        let item = grip.prepareDrag(with: try mouseEvent(
            .leftMouseDragged, at: NSPoint(x: at.x + 12, y: at.y - 12), in: window))
        let prepare = Self.ms(ContinuousClock.now - started)
        #expect(item != nil)
        let busy = await busyUntilIdle()

        PaneDragSession.shared.end(commit: false)
        _ = await busyUntilIdle()
        return (prepare, busy)
    }

    // MARK: Tests

    @Test func aDragStartsFastAmongNineteenWindows() async throws {
        let source = try await openWindows()
        var runs: [(prepare: Double, busy: Double)] = []
        for _ in 0..<3 { runs.append(try await timeDragStart(in: source)) }
        let report = runs.map { String(format: "prepare %.1fms, busy after %.1fms", $0.prepare, $0.busy) }
        print("DRAG-START separate x\(Self.windowCount): \(report.joined(separator: " | "))")
        let worst = runs.map { $0.prepare + $0.busy }.max() ?? 0
        #expect(worst < 150, "\(report)")
    }

    @Test func aDragStartsFastAmongNineteenWorkspaces() async throws {
        WindowMode.overrideForTesting = .single
        WorkspaceHost.shared.resetForTesting()
        let source = try await openWindows()
        var runs: [(prepare: Double, busy: Double)] = []
        for _ in 0..<3 { runs.append(try await timeDragStart(in: source)) }
        let report = runs.map { String(format: "prepare %.1fms, busy after %.1fms", $0.prepare, $0.busy) }
        print("DRAG-START single x\(Self.windowCount): \(report.joined(separator: " | "))")
        let worst = runs.map { $0.prepare + $0.busy }.max() ?? 0
        #expect(worst < 150, "\(report)")
    }
}

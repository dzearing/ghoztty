import AppKit
import GhosttyKit
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import Ghostty

/// The pane banner's collapse/expand, in a REAL terminal window, recorded at
/// the display's frame rate.
@MainActor
@Suite(.serialized)
struct BannerCollapseWindowTests {
    private func settle(_ seconds: TimeInterval = 0.4) async {
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

    /// Collapsing and expanding the banner never moves content laid out to
    /// the bottom: its bottom rows hold still, the card covers or uncovers
    /// rows at the top as it animates, and the terminal is resized ONCE per
    /// toggle, at the start, while a frozen copy of its frame stands in. It used to jump to its final place at the start (a gap under a
    /// growing card, rows showing through a shrinking one), draw the old grid
    /// at the new size, and — when a stale frame landed after a fresh one —
    /// stay that way: wrong rows, the cursor gone, until something printed.
    /// Recorded at the display's frame rate (frames in /tmp/banner-collapse).
    @Test func collapsingAndExpandingNeverMovesTheTerminal() async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sh -c 'i=1; while [ $i -le 60 ]; do echo line $i; i=$((i+1)); done; cat'"
        let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: pane))
        defer { controller.close() }
        controller.paneSidebarState.isHidden = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 900, height: 600))
        await settle(1.5)
        let view = try #require(pane.surfaceView)
        view.paneBanner = "## Collapse me\n| a | b |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |"
        window.makeFirstResponder(view)
        await settle(1.5)
        let surface = try #require(pane.surface)
        func rows() -> Int { Int(ghostty_surface_size(surface).rows) }
        // The terminal's bottom edge, which must hold still: its last rows
        // (the newest output and the cursor) in every frame.
        let bottom = view.convert(view.bounds, to: nil)
        let probe = CGRect(x: bottom.minX, y: bottom.minY, width: 160, height: 70)
        func pixels(_ image: CGImage) -> [Double] {
            let scale = CGFloat(image.width) / window.frame.width
            let rep = NSBitmapImageRep(cgImage: image)
            var out: [Double] = []
            for y in stride(from: probe.minY + 1, to: probe.maxY, by: 2) {
                for x in stride(from: probe.minX + 1, to: probe.maxX, by: 2) {
                    let c = rep.colorAt(x: Int(x * scale), y: Int((window.frame.height - y) * scale))?
                        .usingColorSpace(.sRGB)
                    out.append(Double((c?.redComponent ?? 0) + (c?.greenComponent ?? 0) + (c?.blueComponent ?? 0)) / 3 * 255)
                }
            }
            return out
        }

        let dir = "/tmp/banner-collapse"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var log: [String] = []
        for phase in ["collapse", "expand"] {
            let recorder = WindowFrameRecorder()
            try await recorder.start(window, scale: 2)
            await settle(0.2)
            let start = CACurrentMediaTime()
            var changes: [(CFTimeInterval, Int)] = [(0, rows())]
            withAnimation(Ghostty.SurfacePaneBanner.toggleAnimation) { view.paneBannerCollapsed.toggle() }
            while CACurrentMediaTime() - start < 1.0 {
                if rows() != changes.last?.1 { changes.append((CACurrentMediaTime() - start, rows())) }
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
            let frames = await recorder.stop()
            let report = "\(phase): " + changes.map { String(format: "t=%.3f rows=%d", $0.0, $0.1) }.joined(separator: ", ")
            log.append(report)

            #expect(changes.count == 2, "resized more than once: \(report)")
            if changes.count == 2 {
                #expect(phase == "collapse" ? changes[1].1 > changes[0].1 : changes[1].1 < changes[0].1)
                #expect(changes[1].0 < Ghostty.SurfacePaneBanner.toggleDuration, "resized late: \(report)")
            }

            // The last frame before the click: the first can catch the
            // window's glass before it has sampled the desk behind it.
            let before = try #require(frames.last { $0.0 < start } ?? frames.first)
            let reference = pixels(before.1)
            var worst = 0.0
            for (n, f) in frames.enumerated() where f.0 >= before.0 {
                let ms = Int((f.0 - start) * 1000)
                let moved = zip(pixels(f.1), reference).reduce(0.0) { $0 + abs($1.0 - $1.1) } / Double(reference.count)
                worst = max(worst, moved)
                #expect(moved < 3, "\(phase) frame \(n) at \(ms)ms: the bottom rows moved (\(moved))")
                try NSBitmapImageRep(cgImage: f.1).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: String(format: "%@/%@-f%03d-%+05dms.png", dir, phase, n, ms)))
            }
            log.append("  \(frames.count) frames, worst bottom-row change \(worst)")
            #expect(frames.count > 20, "\(phase) recorded only \(frames.count) frames")
            await settle(0.5)
        }
        try? log.joined(separator: "\n").write(toFile: "\(dir)/log.txt", atomically: true, encoding: .utf8)
    }

    /// A shell prompt at the TOP of the screen rides the card's edge: the
    /// grid adds or drops rows at its bottom, so the text moves exactly as
    /// far as the card does, frame by frame, and is never blanked. It used to
    /// jump a row at the click, vanish for a frame (the prompt is cleared on
    /// resize for the shell to redraw) and come back, then jump again once
    /// the card had finished. Frames in /tmp/banner-collapse-prompt.
    /// Both a plain local shell and one run by the session agent (the
    /// default, `session-persistence`): the agent's shell redraws its prompt
    /// a round trip later.
    @Test(arguments: [false, true])
    func aPromptAtTheTopRidesTheCardsEdge(agent: Bool) async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        let deep = NSTemporaryDirectory() + "banner-collapse-a-rather-long-directory-name/and-another-long-one-to-wrap"
        try? FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        // A login shell (shell integration, so the prompt is cleared and
        // redrawn on resize), its prompt wrapping in a narrow pane.
        config.workingDirectory = deep
        let controller: TerminalController
        if agent {
            try #require(ghostty.config.sessionPersistence)
            controller = TerminalController.newWindow(ghostty, withBaseConfig: config)
        } else {
            let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
            controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: pane))
        }
        defer { controller.close() }
        controller.paneSidebarState.isHidden = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 500, height: 600))
        await settle(3)
        let view = try #require(controller.surfaceTree.root?.leaves().first?.surfaceView)
        view.paneBanner = "sjdfklsfasdjl\njkdlfjklads"
        window.makeFirstResponder(view)
        await settle(1.5)

        // The top of the first line of terminal text, in window points from
        // the top: the brightest rows in a band at the terminal's left edge,
        // left of where the card's own text starts.
        let surfaceFrame = view.convert(view.bounds, to: nil)
        let band = (surfaceFrame.minX + 3)...(surfaceFrame.minX + 10)
        func firstLine(_ image: CGImage) -> CGFloat? {
            let scale = CGFloat(image.width) / window.frame.width
            let rep = NSBitmapImageRep(cgImage: image)
            // From the card's top (the banner sits above the terminal), below
            // the window's own chrome.
            let top = window.frame.height - surfaceFrame.maxY - 70
            for py in Int(top * scale)..<Int(window.frame.height * 0.6 * scale) {
                for x in stride(from: band.lowerBound, through: band.upperBound, by: 0.5) {
                    guard let c = rep.colorAt(x: Int(x * scale), y: py)?.usingColorSpace(.sRGB) else { continue }
                    if (c.redComponent + c.greenComponent + c.blueComponent) / 3 > 0.55 { return CGFloat(py) / scale }
                }
            }
            return nil
        }

        let dir = "/tmp/banner-collapse-prompt" + (agent ? "-agent" : "")
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var log: [String] = []
        for phase in ["collapse", "expand"] {
            let recorder = WindowFrameRecorder()
            try await recorder.start(window, scale: 2)
            await settle(0.2)
            let start = CACurrentMediaTime()
            withAnimation(Ghostty.SurfacePaneBanner.toggleAnimation) { view.paneBannerCollapsed.toggle() }
            await settle(1.0)
            let frames = await recorder.stop()
            var ys: [CGFloat] = []
            for (n, f) in frames.enumerated() {
                let ms = Int((f.0 - start) * 1000)
                try NSBitmapImageRep(cgImage: f.1).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: String(format: "%@/%@-f%03d-%+05dms.png", dir, phase, n, ms)))
                let y = firstLine(f.1)
                #expect(y != nil, "\(phase) frame \(n) at \(ms)ms: the terminal's text is gone")
                if let y { ys.append(y) }
            }
            log.append("\(phase): " + ys.map { String(format: "%.1f", $0) }.joined(separator: " "))
            // Moves one way only (up on collapse, down on expand), in steps
            // no bigger than the card's, and covers the card's whole travel.
            let up = phase == "collapse"
            for (a, b) in zip(ys, ys.dropFirst()) {
                #expect(up ? b <= a + 0.5 : b >= a - 0.5, "\(phase): the text went back (\(a) → \(b)): \(log.last!)")
                #expect(abs(b - a) < 12, "\(phase): the text jumped (\(a) → \(b)): \(log.last!)")
            }
            if let first = ys.first, let last = ys.last {
                #expect(abs(last - first) > 10, "\(phase): the text did not follow the card: \(log.last!)")
            }
            #expect(frames.count > 20, "\(phase) recorded only \(frames.count) frames")
            await settle(0.5)
        }
        try? log.joined(separator: "\n").write(toFile: "\(dir)/log.txt", atomically: true, encoding: .utf8)
    }

    /// Resizing a window never blanks the prompt either: a resize clears the
    /// prompt for the shell to redraw, and the renderer holds the last frame
    /// until the redraw is in (`Terminal.flags.awaiting_prompt_redraw`). It
    /// used to show the cleared prompt for the shell's round trip — through
    /// the session agent, several frames per resize. Frames in
    /// /tmp/banner-collapse-resize.
    @Test(arguments: [false, true])
    func aResizeNeverBlanksThePrompt(agent: Bool) async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        let deep = NSTemporaryDirectory() + "banner-collapse-a-rather-long-directory-name/and-another-long-one-to-wrap"
        try? FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        config.workingDirectory = deep
        let controller: TerminalController
        if agent {
            try #require(ghostty.config.sessionPersistence)
            controller = TerminalController.newWindow(ghostty, withBaseConfig: config)
        } else {
            let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
            controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: pane))
        }
        defer { controller.close() }
        controller.paneSidebarState.isHidden = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 500, height: 600))
        await settle(3)
        let view = try #require(controller.surfaceTree.root?.leaves().first?.surfaceView)
        window.makeFirstResponder(view)
        await settle(0.5)

        // Any terminal text in a band at the terminal's top left, which the
        // prompt (at the top, wrapped) always covers.
        func hasText(_ image: CGImage) -> Bool {
            let frame = view.convert(view.bounds, to: nil)
            let scale = CGFloat(image.width) / window.frame.width
            let rep = NSBitmapImageRep(cgImage: image)
            // From the window's top: a capture taken mid-resize can catch the
            // window drawn without its titlebar, the content higher up.
            let top = window.frame.height - frame.maxY
            for y in stride(from: 0, to: top + 60, by: 0.5) {
                for x in stride(from: frame.minX + 3, to: frame.minX + 60, by: 1) {
                    guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { continue }
                    if (c.redComponent + c.greenComponent + c.blueComponent) / 3 > 0.55 { return true }
                }
            }
            return false
        }

        // The window's own titlebar text was drawn.
        func hasChrome(_ image: CGImage) -> Bool {
            let scale = CGFloat(image.width) / window.frame.width
            let rep = NSBitmapImageRep(cgImage: image)
            for y in stride(from: 4, to: 24, by: 0.5) {
                for x in stride(from: 40, to: window.frame.width - 40, by: 2) {
                    guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { continue }
                    if (c.redComponent + c.greenComponent + c.blueComponent) / 3 > 0.55 { return true }
                }
            }
            return false
        }

        let dir = "/tmp/banner-collapse-resize" + (agent ? "-agent" : "")
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let recorder = WindowFrameRecorder()
        try await recorder.start(window, scale: 2)
        await settle(0.2)
        let start = CACurrentMediaTime()
        for height in [520, 600, 480, 640, 560] {
            window.setContentSize(NSSize(width: 500, height: height))
            await settle(0.4)
        }
        let frames = await recorder.stop()
        for (n, f) in frames.enumerated() {
            let ms = Int((f.0 - start) * 1000)
            try NSBitmapImageRep(cgImage: f.1).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: String(format: "%@/f%03d-%+05dms.png", dir, n, ms)))
            // A capture can catch the window mid-resize with nothing drawn
            // in it at all (no titlebar either): not the terminal's doing.
            if !hasText(f.1) && hasChrome(f.1) {
                Issue.record("frame \(n) at \(ms)ms: the prompt is blank")
            }
        }
        #expect(frames.count > 40, "recorded only \(frames.count) frames")
    }

    /// A resize reflows a shell's prompt as it happens: at a prompt a resize
    /// is not debounced (only a running program, which may repaint on every
    /// SIGWINCH, is), and the next one waits only for the shell's redraw of
    /// the last. It used to wait out the 100ms debounce, and a drag reflowed
    /// only every 350ms, its cap. Measured on the grid itself: the widest
    /// row (the wrapped prompt fills its rows) against the size the view
    /// asked for.
    @Test(arguments: [false, true])
    func aResizeReflowsThePromptAsItHappens(agent: Bool) async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        let deep = NSTemporaryDirectory() + "banner-collapse-a-rather-long-directory-name/and-another-long-one-to-wrap/and-a-third-one-to-wrap-again"
        try? FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        config.workingDirectory = deep
        let controller: TerminalController
        if agent {
            try #require(ghostty.config.sessionPersistence)
            controller = TerminalController.newWindow(ghostty, withBaseConfig: config)
        } else {
            let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
            controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: pane))
        }
        defer { controller.close() }
        controller.paneSidebarState.isHidden = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 900, height: 400))
        await settle(3)
        let view = try #require(controller.surfaceTree.root?.leaves().first?.surfaceView)
        let surface = try #require(view.surface)

        // Whether the grid is laid out at the width the view asked for: the
        // prompt is one long line, so the cursor's column is its length
        // (plus a constant: the trailing space the read trims) modulo the
        // grid's width. Text reads come back unwrapped.
        func promptLength() -> Int {
            var text = ghostty_text_s()
            let sel = ghostty_selection_s(
                top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
                bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
                rectangle: false)
            guard ghostty_surface_read_text(surface, sel, &text) else { return 0 }
            defer { ghostty_surface_free_text(surface, &text) }
            return String(cString: text.text).components(separatedBy: "\n").map(\.count).max() ?? 0
        }
        func cursorColumn() -> Int {
            var x = 0.0, y = 0.0, w = 0.0, h = 0.0
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
            let cell = Double(ghostty_surface_size(surface).cell_width_px)
            return Int((x * (window.backingScaleFactor)) / cell - 0.5)
        }
        func wanted() -> Int { Int(ghostty_surface_size(surface).columns) }
        await settle(0.5)
        let length = promptLength()
        try #require(length > wanted(), "the prompt does not wrap")
        let trim = ((cursorColumn() - length) % wanted() + wanted()) % wanted()
        func caughtUp() -> Bool { cursorColumn() == (length + trim) % wanted() }
        try #require(caughtUp(), "cursor \(cursorColumn()), prompt \(length), width \(wanted())")

        // How stale the grid is, sampled every 4ms: how long ago the width
        // it is laid out at stopped being the one asked for (0 while it is).
        var asked: [(width: Int, until: CFTimeInterval?)] = [(wanted(), nil)]
        var staleness: [CFTimeInterval] = []
        var widths: Set<Int> = []
        var taken = 0
        func sample() {
            let now = CACurrentMediaTime()
            if asked.last?.width != wanted() {
                asked[asked.count - 1].until = now
                asked.append((wanted(), nil))
            }
            // The most recent width the cursor fits. The grid takes the
            // widths in order, so not one before the last it took: the
            // cursor passes through other columns while the shell redraws.
            let column = cursorColumn()
            guard let index = asked.indices[taken...].last(where: { column == (length + trim) % asked[$0].width })
            else { return }
            taken = index
            widths.insert(asked[index].width)
            staleness.append(asked[index].until.map { now - $0 } ?? 0)
        }
        func hold(_ seconds: TimeInterval) async {
            let end = CACurrentMediaTime() + seconds
            while CACurrentMediaTime() < end {
                sample()
                try? await Task.sleep(nanoseconds: 4_000_000)
            }
        }

        // One step narrower, then a drag back out: 40 steps 16ms apart.
        window.setContentSize(NSSize(width: 500, height: 400))
        await hold(0.6)
        for n in 0..<40 {
            window.setContentSize(NSSize(width: 500 + CGFloat(n) * 10, height: 400))
            await hold(0.016)
        }
        await hold(0.6)
        #expect(caughtUp(), "the grid never caught up")
        let worst = Int((staleness.max() ?? 0) * 1000)
        #expect(widths.count > 10, "reflowed to only \(widths.count) widths")
        #expect(worst < 120, "the grid was up to \(worst)ms stale")
    }
}

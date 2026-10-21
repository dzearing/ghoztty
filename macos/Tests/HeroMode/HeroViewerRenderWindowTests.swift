import AppKit
import Combine
import Network
import ScreenCaptureKit
import GhosttyKit
import Testing
import WebKit
@testable import Ghostty

/// Every viewer kind still PAINTS in hero mode — in a real window, measured on
/// the pixels the window server composites (own-window ScreenCaptureKit
/// capture, which needs no screen-recording grant).
///
/// A viewer in a terminal | viewer window is focused, hero mode is entered
/// (the viewer is the hero), and the hero pane's content area — below its nav
/// bar — must show the page: a known fill for an HTML file, a website and an
/// image; ink (text) for markdown, code and a diff. Then hero is left and the
/// pane must paint in the grid again. Captures land in `/tmp/hero-viewer-snapshots`.
@MainActor
@Suite(.serialized)
struct HeroViewerRenderWindowTests {
    private static let snapshotDir = "/tmp/hero-viewer-snapshots"

    /// The fill the HTML page, the website, and the image are painted with.
    /// Nothing else in the window (desk gradient, glass, chrome) is this red.
    private static let fill: (r: Double, g: Double, b: Double) = (220, 30, 40)

    private func terminalPane(_ app: ghostty_app_t) -> PaneView {
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        return PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
    }

    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hero-viewer-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var redPage: String {
        """
        <!doctype html><html><head><style>
        html, body { margin: 0; height: 100%;
          background: rgb(\(Int(Self.fill.r)), \(Int(Self.fill.g)), \(Int(Self.fill.b))); }
        </style></head><body></body></html>
        """
    }

    @discardableResult
    private func capture(_ window: NSWindow, _ name: String) async throws -> CGImage {
        try? FileManager.default.createDirectory(atPath: Self.snapshotDir, withIntermediateDirectories: true)
        let content = try await SCShareableContent.currentProcess
        let scWindow = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let cfg = SCStreamConfiguration()
        cfg.width = Int(scWindow.frame.width * 2)
        cfg.height = Int(scWindow.frame.height * 2)
        cfg.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow), configuration: cfg)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(Self.snapshotDir)/\(name).png"))
        return image
    }

    /// sRGB 0–255 pixels on a grid over `rect` (window points, top-left origin).
    private func pixels(_ image: CGImage, in rect: CGRect, window: NSWindow) -> [[Double]] {
        let scale = CGFloat(image.width) / window.frame.width
        let rep = NSBitmapImageRep(cgImage: image)
        var out: [[Double]] = []
        for y in stride(from: rect.minY, to: rect.maxY, by: 3) {
            for x in stride(from: rect.minX, to: rect.maxX, by: 3) {
                guard let c = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?
                    .usingColorSpace(.sRGB) else { continue }
                out.append([c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) * 255 })
            }
        }
        return out
    }

    /// Share of the sampled pixels that are the known fill.
    private func fillShare(_ px: [[Double]]) -> Double {
        // Loose on purpose: the capture comes back color-managed (display
        // P3 → sRGB), so the page's red is not returned verbatim.
        let hits = px.filter { $0[0] > 150 && $0[1] < 110 && $0[2] < 110 }
        return Double(hits.count) / Double(max(px.count, 1))
    }

    /// Share of the sampled pixels that stand out from the region's median —
    /// text on a page. A blank (or see-through) pane is ~0.
    private func inkShare(_ px: [[Double]]) -> Double {
        guard !px.isEmpty else { return 0 }
        let lum = px.map { 0.299 * $0[0] + 0.587 * $0[1] + 0.114 * $0[2] }
        let median = lum.sorted()[lum.count / 2]
        return Double(lum.filter { abs($0 - median) > 60 }.count) / Double(lum.count)
    }

    private enum Expect { case fill, ink }

    /// Where to look, in window points with a top-left origin: for ink, a
    /// band of the content below the nav bar, inset clear of the card's
    /// rounded corners; for a fill, the pane's middle, which a best-fit image
    /// covers whatever its aspect.
    private func contentRect(of view: NSView, _ expect: Expect, window: NSWindow) -> CGRect {
        let r = view.convert(view.bounds, to: nil)
        let top = window.frame.height - r.maxY
        switch expect {
        case .ink:
            return CGRect(x: r.minX + 16, y: top + 60, width: r.width - 32, height: min(r.height - 80, 300))
        case .fill:
            return CGRect(x: r.midX - r.width * 0.25, y: top + r.height * 0.4, width: r.width * 0.5, height: r.height * 0.25)
        }
    }

    private func findHeroContainer(_ v: NSView) -> HeroPaneContainer? {
        (v as? HeroPaneContainer) ?? v.subviews.lazy.compactMap(findHeroContainer).first
    }

    private func score(_ expect: Expect, _ px: [[Double]]) -> Double {
        expect == .fill ? fillShare(px) : inkShare(px)
    }

    private func threshold(_ expect: Expect) -> Double {
        expect == .fill ? 0.8 : 0.01
    }

    /// How the viewer becomes the hero.
    private enum Entry {
        /// Focus the viewer, then toggle hero: it is the hero from the start.
        case focused
        /// Toggle hero from the terminal, then step to the viewer: its slot
        /// was laid out off screen and scrolls in.
        case stepped
    }

    /// Opens `viewer` beside a terminal, heroes it, and checks it paints in
    /// the grid, in hero, and in the grid again after leaving.
    ///
    /// `liveSplit` adds the viewer to an open window the way `+split --view=`
    /// does (`newViewerSplit`), instead of building it into the first tree.
    ///
    /// `stackedTerminals` more terminals follow the viewer in the row, enough
    /// that the row cannot fit them side by side and stacks.
    private func check(_ name: String, _ viewer: ViewerView, _ expect: Expect,
                       entry: Entry = .focused, liveSplit: Bool = false,
                       stackedTerminals: Int = 0) async throws {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        // WebKit stops painting a page whose window is fully covered, and a
        // test window can be (it opens behind whatever is in front). What is
        // measured here is whether the pane is mounted and painting where hero
        // mode puts it, not the window's place in the stack.
        let webView = try #require(viewer.webView)
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occlusion) {
            typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(webView.method(for: occlusion), to: Setter.self)(webView, occlusion, false)
        }
        let a = terminalPane(app)
        var tree = SplitTree<PaneView>(view: a)
        if !liveSplit {
            let v = PaneView(viewer: viewer)
            tree = try tree.inserting(view: v, at: a, direction: .right)
            var last = v
            for _ in 0..<stackedTerminals {
                let t = terminalPane(app)
                tree = try tree.inserting(view: t, at: last, direction: .right)
                last = t
            }
        }
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        defer { controller.close() }
        controller.paneSidebarState.isHidden = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 760))
        await settle(1.0)
        if liveSplit {
            #expect(controller.newViewerSplit(atPane: a, direction: .right, viewer: viewer) != nil)
        }
        await settle(2.5)
        let terminal = try #require(a.surfaceView)
        window.makeFirstResponder(entry == .focused ? viewer.webView : terminal)
        await settle(0.5)

        let gridRect = contentRect(of: viewer, expect, window: window)
        let grid = score(expect, pixels(try await capture(window, "\(name)-grid"), in: gridRect, window: window))

        controller.toggleHeroMode(self)
        // The pane announcing a change as hero mode takes it — focus moving,
        // a title, a load — makes the grid hero mode is replacing run one
        // last update. That update must not take the pane back out of the
        // hero (it used to, about one entry in two, and the hero was blank).
        viewer.objectWillChange.send()
        _ = await poll(timeout: 2) { controller.heroModeState.isActive }
        #expect(controller.heroModeState.isActive)
        if entry == .stepped {
            await settle(1.0)
            controller.heroModeState.select(1, leafCount: controller.surfaceTree.visibleLeaves.count)
        }
        #expect(controller.heroModeState.selectedIndex == 1, "the viewer is the hero")
        await settle(2.0)
        let root = try #require(window.contentView)
        let container = try #require(findHeroContainer(root))
        let heroRect = contentRect(of: container, expect, window: window)
        let hero = score(expect, pixels(try await capture(window, "\(name)-hero"), in: heroRect, window: window))
        #expect(viewer.window === window, "the viewer was taken out of the hero")

        var heroChain: [String] = []
        var hnode: NSView? = viewer
        while let n = hnode, n !== root {
            heroChain.append("\(type(of: n)) frame=\(n.frame) hidden=\(n.isHidden) alpha=\(n.alphaValue) layerOpacity=\(n.layer?.opacity ?? -1) layerHidden=\(n.layer?.isHidden ?? false) subviews=\(n.subviews.count)")
            hnode = n.superview
        }
        controller.toggleHeroMode(self)
        _ = await poll(timeout: 2) { !controller.heroModeState.isActive }
        await settle(2.0)
        let afterRect = contentRect(of: viewer, expect, window: window)
        let after = score(expect, pixels(try await capture(window, "\(name)-after"), in: afterRect, window: window))

        var chain: [String] = []
        var node: NSView? = viewer
        while let n = node, n !== root {
            chain.append("\(type(of: n)) frame=\(n.frame) hidden=\(n.isHidden) alpha=\(n.alphaValue) layerOpacity=\(n.layer?.opacity ?? -1) layerHidden=\(n.layer?.isHidden ?? false)")
            node = n.superview
        }
        let report = "\(name): grid \(grid) hero \(hero) after \(after) heroRect \(heroRect)\n"
            + "HERO:\n" + heroChain.joined(separator: "\n") + "\nAFTER:\n" + chain.joined(separator: "\n") + "\n"
        try? report.write(toFile: "\(Self.snapshotDir)/\(name).txt", atomically: true, encoding: .utf8)
        #expect(grid > threshold(expect), "\(report)")
        #expect(hero > threshold(expect), "the hero pane is blank: \(report)")
        #expect(after > threshold(expect), "the pane is blank after leaving hero: \(report)")
    }

    /// The race behind the blank hero is a coin toss per entry, so enter it
    /// many times: after every entry the viewer must still be mounted in
    /// the window, and after every exit, back in the grid.
    @Test func heroEntryNeverLosesTheViewer() async throws {
        let file = try htmlFile(redPage)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        let viewer = ViewerView(location: file.path)
        let a = terminalPane(app)
        let tree = try SplitTree<PaneView>(view: a).inserting(view: PaneView(viewer: viewer), at: a, direction: .right)
        let controller = TerminalController.newWindow(ghostty, tree: tree)
        defer { controller.close() }
        controller.paneSidebarState.isHidden = true
        _ = await poll(timeout: 10) { controller.window?.isVisible == true }
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1200, height: 760))
        await settle(2.5)
        let terminal = try #require(a.surfaceView)

        var lost: [String] = []
        for round in 0..<12 {
            // Alternate entering from either pane.
            window.makeFirstResponder(round.isMultiple(of: 2) ? viewer.webView : terminal)
            await settle(0.2)
            controller.toggleHeroMode(self)
            viewer.objectWillChange.send()
            _ = await poll(timeout: 2) { controller.heroModeState.isActive }
            if round % 2 == 1 { controller.heroModeState.select(1, leafCount: 2) }
            await settle(0.4)
            if viewer.window !== window { lost.append("round \(round): in hero") }
            controller.toggleHeroMode(self)
            _ = await poll(timeout: 2) { !controller.heroModeState.isActive }
            await settle(0.4)
            if viewer.window !== window { lost.append("round \(round): after hero") }
        }
        #expect(lost.isEmpty, "the viewer was taken out of the window: \(lost)")
    }

    private func htmlFile(_ html: String) throws -> URL {
        let dir = try tempDir("html")
        let file = dir.appendingPathComponent("index.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A page that sets no background of its own (most do not) — text on
    /// the white a browser gives it.
    private var plainPage: String {
        "<!doctype html><html><body><h1>Plain page</h1><p>"
            + String(repeating: "An HTML file with no background of its own. ", count: 60)
            + "</p></body></html>"
    }

    @Test func htmlFileSteppedIntoHero() async throws {
        let file = try htmlFile(redPage)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try await check("html-stepped", ViewerView(location: file.path), .fill, entry: .stepped)
    }

    @Test func markdownSteppedIntoHero() async throws {
        let dir = try tempDir("md-stepped")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        let para = String(repeating: "Hero mode renders this markdown paragraph. ", count: 40)
        try "# Heading\n\n\(para)\n".write(to: file, atomically: true, encoding: .utf8)
        try await check("markdown-stepped", ViewerView(location: file.path), .ink, entry: .stepped)
    }

    @Test func htmlFileLiveSplitRendersInHero() async throws {
        let file = try htmlFile(redPage)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try await check("html-live", ViewerView(location: file.path), .fill, liveSplit: true)
    }

    @Test func htmlFileInStackedRowRendersInHero() async throws {
        let file = try htmlFile(redPage)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try await check("html-stacked", ViewerView(location: file.path), .fill, stackedTerminals: 3)
    }

    @Test func plainHTMLFileRendersInHero() async throws {
        let file = try htmlFile(plainPage)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try await check("html-plain", ViewerView(location: file.path), .ink, liveSplit: true)
    }

    @Test func htmlFileRendersInHero() async throws {
        let dir = try tempDir("html")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("index.html")
        try redPage.write(to: file, atomically: true, encoding: .utf8)
        try await check("html", ViewerView(location: file.path), .fill)
    }

    @Test func websiteRendersInHero() async throws {
        let server = try await TinyHTTPServer.start(body: redPage)
        defer { server.stop() }
        try await check("website", ViewerView(location: "http://127.0.0.1:\(server.port)/"), .fill)
    }

    @Test func imageRendersInHero() async throws {
        let dir = try tempDir("image")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("red.png")
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1400, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let ctx = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        NSColor(srgbRed: Self.fill.r / 255, green: Self.fill.g / 255, blue: Self.fill.b / 255, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 2000, height: 1400).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])?.write(to: file)
        try await check("image", ViewerView(location: file.path), .fill)
    }

    @Test func markdownRendersInHero() async throws {
        let dir = try tempDir("md")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.md")
        let para = String(repeating: "Hero mode renders this markdown paragraph. ", count: 40)
        try "# Heading\n\n\(para)\n\n\(para)\n".write(to: file, atomically: true, encoding: .utf8)
        try await check("markdown", ViewerView(location: file.path), .ink)
    }

    @Test func codeRendersInHero() async throws {
        let dir = try tempDir("code")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("main.swift")
        let code = (0..<60).map { "let value\($0) = compute(\($0), \"string literal number \($0)\")" }
            .joined(separator: "\n")
        try code.write(to: file, atomically: true, encoding: .utf8)
        try await check("code", ViewerView(location: file.path), .ink)
    }

    @Test func diffRendersInHero() async throws {
        let dir = try tempDir("diff")
        defer { try? FileManager.default.removeItem(at: dir) }
        func git(_ args: String...) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path, "-c", "user.email=t@t", "-c", "user.name=t"] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
        }
        let file = dir.appendingPathComponent("a.txt")
        try git("init", "-q")
        try (0..<40).map { "original line \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-qm", "init")
        try (0..<40).map { "changed line number \($0) with more words" }.joined(separator: "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        try await check("diff", ViewerView(location: "git-status:", originDirectory: dir.path), .ink)
    }
}

/// Serves one HTML body on 127.0.0.1 for any request.
final class TinyHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(body: String) async throws -> TinyHTTPServer {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        let response = Data((
            "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n" + body).utf8)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let err):
                    resumed = true
                    cont.resume(throwing: err)
                default: break
                }
            }
            listener.start(queue: .global())
        }
        return TinyHTTPServer(listener: listener, port: port)
    }

    func stop() { listener.cancel() }
}

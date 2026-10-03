import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// The viewer nav bar's folder button reveals the file the pane is showing in
/// Finder. It exists only while there IS a file — a website or a diff has
/// nothing to reveal, and a button that can do nothing is a lie — and it
/// follows the pane's current location, not where the pane was opened.
@MainActor
struct ViewerRevealInFinderTests {
    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-reveal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeFile(named name: String, contents: String = "x\n") throws -> URL {
        let file = try makeDir().appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func makeImage() throws -> URL {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let file = try makeDir().appendingPathComponent("shot.png")
        try rep.representation(using: .png, properties: [:])!.write(to: file)
        return file
    }

    private func mountBar(_ viewer: ViewerView) async -> NSHostingView<WebChromeBar> {
        let host = NSHostingView(rootView: WebChromeBar(viewerView: viewer))
        host.frame = NSRect(x: 0, y: 0, width: 700, height: 44)
        await relayout(host)
        return host
    }

    private func relayout(_ host: NSView) async {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try? await Task.sleep(nanoseconds: 200_000_000)
        host.layoutSubtreeIfNeeded()
    }

    private func buttonCount(in view: NSView) -> Int {
        var count = String(describing: type(of: view)).contains("Button") ? 1 : 0
        view.subviews.forEach { count += buttonCount(in: $0) }
        return count
    }

    /// back, forward, reload, home.
    private let navButtons = 4
    /// previous change, next change, layout toggle.
    private let diffButtons = 3

    // MARK: - The gate

    @Test func everyFileModeHasAFileToReveal() throws {
        for file in [
            try makeFile(named: "a.md", contents: "# hi\n"),
            try makeFile(named: "a.swift", contents: "let x = 1\n"),
            try makeFile(named: "a.html", contents: "<p>hi</p>"),
            try makeImage(),
        ] {
            let viewer = ViewerView(location: file.path)
            #expect(viewer.fileURL?.standardizedFileURL == file.standardizedFileURL,
                    "\(file.lastPathComponent) should be revealable")
        }
    }

    @Test func websitesAndDiffsHaveNothingToReveal() {
        for location in ["https://example.invalid/page", ViewerView.blankPage, "git-status:",
                         "git-diff:main...HEAD"] {
            #expect(ViewerView(location: location).fileURL == nil, "\(location)")
        }
    }

    // MARK: - The button

    @Test func theButtonIsPresentForEveryFileMode() async throws {
        for file in [
            try makeFile(named: "a.md", contents: "# hi\n"),
            try makeFile(named: "a.swift", contents: "let x = 1\n"),
            try makeFile(named: "a.html", contents: "<p>hi</p>"),
            try makeImage(),
        ] {
            let host = await mountBar(ViewerView(location: file.path))
            #expect(buttonCount(in: host) == navButtons + 1,
                    "\(file.lastPathComponent) should carry the Reveal in Finder button")
        }
    }

    @Test func theButtonIsAbsentForAWebsite() async {
        let host = await mountBar(ViewerView(location: "https://example.invalid/page"))
        #expect(buttonCount(in: host) == navButtons)
    }

    @Test func theButtonIsAbsentForADiff() async {
        let host = await mountBar(ViewerView(location: "git-status:"))
        #expect(buttonCount(in: host) == navButtons + diffButtons)
    }

    /// The button follows where the pane IS. Typing a URL into a file pane's
    /// address bar takes the button away; typing a path brings it back, now
    /// naming the new file.
    @Test func theButtonFollowsTheAddressBar() async throws {
        let markdown = try makeFile(named: "a.md", contents: "# hi\n")
        let code = try makeFile(named: "b.swift", contents: "let x = 1\n")
        let viewer = ViewerView(location: markdown.path)
        let host = await mountBar(viewer)
        #expect(buttonCount(in: host) == navButtons + 1)

        viewer.navigate(to: "https://example.invalid/page")
        await relayout(host)
        #expect(viewer.fileURL == nil)
        #expect(buttonCount(in: host) == navButtons)

        viewer.navigate(to: code.path)
        await relayout(host)
        #expect(viewer.fileURL?.standardizedFileURL == code.standardizedFileURL)
        #expect(buttonCount(in: host) == navButtons + 1)
    }

    /// The bar is a single flexible row: adding a button must not stop it
    /// compressing to a narrow split (the address field absorbs the slack).
    @Test func aNarrowPaneStillFitsTheBar() async throws {
        let viewer = ViewerView(location: try makeFile(named: "a.md", contents: "# hi\n").path)
        let host = NSHostingView(rootView: WebChromeBar(viewerView: viewer)
            .frame(width: 200, height: 44))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 44)
        await relayout(host)
        #expect(buttonCount(in: host) == navButtons + 1)
        #expect(host.fittingSize.width <= 200 + 0.5,
                "the bar wants \(host.fittingSize.width)pt in a 200pt pane")
    }

    // MARK: - Where the reveal lands

    /// Compared by path: `deletingLastPathComponent` hands back a
    /// trailing-slash directory URL, which `==` treats as a different URL.
    private func describe(_ target: BannerLinkOpener.RevealTarget) -> String {
        switch target {
        case .select(let url): return "select \(url.path)"
        case .openFolder(let url): return "open \(url.path)"
        }
    }

    @Test func anExistingFileIsSelected() throws {
        let file = try makeFile(named: "a.md")
        #expect(describe(BannerLinkOpener.revealTarget(for: file)) == "select \(file.path)")
    }

    /// A viewed file deleted under its pane is ordinary (the pane shows the
    /// error card). Selecting a missing path does nothing visible, so the
    /// reveal opens the folder it lived in instead.
    @Test func aDeletedFileOpensItsFolder() throws {
        let file = try makeFile(named: "a.md")
        try FileManager.default.removeItem(at: file)
        #expect(describe(BannerLinkOpener.revealTarget(for: file))
            == "open \(file.deletingLastPathComponent().path)")
    }

    /// If the folder went too, walk up to the nearest one that survives.
    @Test func aDeletedFolderOpensTheNearestSurvivingAncestor() throws {
        let dir = try makeDir()
        let file = dir.appendingPathComponent("gone/deeper/a.md")
        #expect(describe(BannerLinkOpener.revealTarget(for: file)) == "open \(dir.path)")
    }

    @Test func theWalkStopsAtTheRoot() {
        let target = BannerLinkOpener.revealTarget(
            for: URL(fileURLWithPath: "/nope/a.md"), exists: { _ in false })
        #expect(describe(target) == "open /")
    }
}

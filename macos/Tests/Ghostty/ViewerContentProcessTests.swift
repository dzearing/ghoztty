import AppKit
import Foundation
import Testing
import WebKit
@testable import Ghostty

/// A viewer pane whose WebKit content process dies (WebKit kills them under
/// memory pressure, and a page can run one into the ground) loads its
/// content again rather than staying blank.
@Suite(.serialized)
struct ViewerContentProcessTests {
    /// One script evaluation that always comes back: WebKit never calls the
    /// completion of an evaluation whose content process dies under it, so
    /// awaiting it directly would wait forever.
    @MainActor
    private func evaluate(_ script: String, in viewer: ViewerView) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var resumed = false
            func finish(_ value: String?) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: value)
            }
            viewer.webView.evaluateJavaScript(script) { result, _ in finish(result as? String) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(nil) }
        }
    }

    @MainActor
    private func ready(_ viewer: ViewerView, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await evaluate("document.getElementById('ready') ? 'yes' : 'no'", in: viewer) == "yes" {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    @MainActor
    @Test func aPaneWhoseContentProcessDiesLoadsAgain() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("viewer-crash-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("page.html")
        try "<!doctype html><html><body><p id=ready>Hello</p></body></html>"
            .write(to: file, atomically: true, encoding: .utf8)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil) }
        let viewer = ViewerView(location: file.path)
        viewer.frame = window.contentView!.bounds
        window.contentView!.addSubview(viewer)
        window.orderFront(nil)
        try #require(await ready(viewer), "the page never loaded")

        // WebKit's own test hook for a dead content process.
        let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
        try #require(viewer.webView.responds(to: kill))
        viewer.webView.perform(kill)

        #expect(await ready(viewer), "the pane stayed blank after its content process died")
    }
}

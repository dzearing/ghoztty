import Testing
@testable import Ghostty

/// `+split --name=<n>` used to succeed silently whenever ANY pane held the
/// name — in another window, showing another file — so an agent reported a
/// pane that never opened. Pane names now belong to their window, so only a
/// pane in the window the split lands in collides (`PaneNameScopeWindowTests`
/// drives the cross-window case). These pin what such a collision does: a
/// request the pane already satisfies is reused and says so, anything else
/// fails and says why.
struct SplitNameCollisionTests {
    private func viewer(
        _ location: String,
        home: String? = nil,
        window: String = "window-2"
    ) -> SplitNameCollision.Existing {
        .init(kind: .viewer(location: location, homeLocation: home ?? location), windowName: window)
    }

    /// A different view under a name this window already holds fails: the
    /// pane belongs to whatever opened it, so it is not quietly retargeted.
    @Test func differentViewFails() {
        let result = SplitNameCollision.decide(
            name: "writeup",
            existing: viewer("/Users/me/Documents/old.html", window: "dev"),
            requestedView: "/Users/me/Documents/new.html")
        guard case .conflict(let error) = result else {
            Issue.record("expected a conflict, got \(result)")
            return
        }
        #expect(error.contains("this window ('dev')"))
        #expect(error.contains("/Users/me/Documents/old.html"))
        #expect(error.contains("/Users/me/Documents/new.html"))
        #expect(error.contains("+close --target=writeup"))
    }

    /// Re-running the same launch is the idempotent case: reused, and said.
    @Test func sameViewIsReusedAndSaysWhere() {
        let result = SplitNameCollision.decide(
            name: "doc",
            existing: viewer("/a.md", window: "window-3"),
            requestedView: "/a.md")
        #expect(result == .reuse(message:
            "pane 'doc' already exists in this window ('window-3'), showing /a.md; reused it, no split created"))
    }

    /// A pane the user navigated away from still answers its own launch.
    @Test func homeLocationCountsAsTheSameView() {
        let result = SplitNameCollision.decide(
            name: "site",
            existing: viewer("https://example.com/other/", home: "https://example.com"),
            requestedView: "https://example.com/")
        guard case .reuse = result else {
            Issue.record("expected reuse, got \(result)")
            return
        }
    }

    @Test func fileURLAndPathAreTheSameView() {
        let result = SplitNameCollision.decide(
            name: "doc",
            existing: viewer("file:///tmp/a.md"),
            requestedView: "/tmp/a.md")
        guard case .reuse = result else {
            Issue.record("expected reuse, got \(result)")
            return
        }
    }

    @Test func terminalAgainIsReused() {
        let result = SplitNameCollision.decide(
            name: "logs",
            existing: .init(kind: .terminal, windowName: "dev"),
            requestedView: nil)
        #expect(result == .reuse(message:
            "pane 'logs' already exists in this window ('dev'); reused it, no split created"))
    }

    @Test func kindMismatchFails() {
        let viewerAskedOfTerminal = SplitNameCollision.decide(
            name: "logs",
            existing: .init(kind: .terminal, windowName: "dev"),
            requestedView: "/a.md")
        let terminalAskedOfViewer = SplitNameCollision.decide(
            name: "doc",
            existing: viewer("/a.md"),
            requestedView: nil)
        guard case .conflict = viewerAskedOfTerminal, case .conflict = terminalAskedOfViewer else {
            Issue.record("expected conflicts, got \(viewerAskedOfTerminal) / \(terminalAskedOfViewer)")
            return
        }
    }

    /// Window names are global: a pane never takes one.
    @Test func aWindowNameIsNeverReusedAsAPane() {
        let result = SplitNameCollision.decide(
            name: "window-2",
            existing: .init(kind: .window, windowName: "window-2"),
            requestedView: nil)
        guard case .conflict(let error) = result else {
            Issue.record("expected a conflict, got \(result)")
            return
        }
        #expect(error.contains("name of a window"))
    }

    @Test func createdMessageNamesPaneWindowViewAndWhetherItIsOnShow() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let parsed = IPCServer.parseArguments(["--name=doc", "--view=/a.md"])
        #expect(IPCServer.createdMessage(parsed, .init(paneID: id, windowName: "dev", onShow: true))
            == "created pane 'doc' (\(id.uuidString)) in window 'dev', showing /a.md")
        let unnamed = IPCServer.parseArguments(["--direction=down"])
        #expect(IPCServer.createdMessage(unnamed, .init(paneID: id, windowName: "dev", onShow: nil))
            == "created pane \(id.uuidString) in window 'dev'")
        #expect(IPCServer.createdMessage(unnamed, .init(paneID: id, windowName: "dev", onShow: false))
            .hasSuffix("; it is minimized to a strip, since its row has no room for it on show"))
    }
}

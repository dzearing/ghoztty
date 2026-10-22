import Testing
@testable import Ghostty

/// `+split --name=<n>` used to succeed silently whenever ANY pane held the
/// name — in another window, showing another file — so an agent reported a
/// pane that never opened. These pin the policy: a request the pane already
/// satisfies is reused and says where, anything else fails and says why.
struct SplitNameCollisionTests {
    private func viewer(
        _ location: String,
        home: String? = nil,
        window: String = "window-2",
        inAnchor: Bool = false
    ) -> SplitNameCollision.Existing {
        .init(
            kind: .viewer(location: location, homeLocation: home ?? location),
            windowName: window,
            inAnchorWindow: inAnchor)
    }

    /// The reported bug: a different `--view` under a name held in another
    /// window. It must fail, naming the pane's window and what it shows.
    @Test func differentViewInAnotherWindowFails() {
        let result = SplitNameCollision.decide(
            name: "writeup",
            existing: viewer("/Users/me/Documents/old.html", window: "window-7"),
            requestedView: "/Users/me/Documents/new.html")
        guard case .conflict(let error) = result else {
            Issue.record("expected a conflict, got \(result)")
            return
        }
        #expect(error.contains("window 'window-7'"))
        #expect(error.contains("not the window this split was for"))
        #expect(error.contains("/Users/me/Documents/old.html"))
        #expect(error.contains("/Users/me/Documents/new.html"))
        #expect(error.contains("+close --target=writeup"))
    }

    /// A different view in the caller's own window is not quietly retargeted
    /// either: the pane belongs to whatever opened it.
    @Test func differentViewInTheAnchorWindowFails() {
        let result = SplitNameCollision.decide(
            name: "doc",
            existing: viewer("/a.md", window: "dev", inAnchor: true),
            requestedView: "/b.md")
        guard case .conflict(let error) = result else {
            Issue.record("expected a conflict, got \(result)")
            return
        }
        #expect(error.contains("this window ('dev')"))
    }

    /// Re-running the same launch is the idempotent case: reused, and said.
    @Test func sameViewIsReusedAndSaysWhere() {
        let result = SplitNameCollision.decide(
            name: "doc",
            existing: viewer("/a.md", window: "window-3"),
            requestedView: "/a.md")
        #expect(result == .reuse(message:
            "pane 'doc' already exists in window 'window-3', not the window this split was for, "
                + "showing /a.md; reused it, no split created"))
    }

    /// A pane the user navigated away from still answers its own launch.
    @Test func homeLocationCountsAsTheSameView() {
        let result = SplitNameCollision.decide(
            name: "site",
            existing: viewer("https://example.com/other/", home: "https://example.com", inAnchor: true),
            requestedView: "https://example.com/")
        guard case .reuse = result else {
            Issue.record("expected reuse, got \(result)")
            return
        }
    }

    @Test func fileURLAndPathAreTheSameView() {
        let result = SplitNameCollision.decide(
            name: "doc",
            existing: viewer("file:///tmp/a.md", inAnchor: true),
            requestedView: "/tmp/a.md")
        guard case .reuse = result else {
            Issue.record("expected reuse, got \(result)")
            return
        }
    }

    @Test func terminalAgainIsReused() {
        let result = SplitNameCollision.decide(
            name: "logs",
            existing: .init(kind: .terminal, windowName: "dev", inAnchorWindow: true),
            requestedView: nil)
        #expect(result == .reuse(message:
            "pane 'logs' already exists in this window ('dev'); reused it, no split created"))
    }

    @Test func kindMismatchFails() {
        let viewerAskedOfTerminal = SplitNameCollision.decide(
            name: "logs",
            existing: .init(kind: .terminal, windowName: "dev", inAnchorWindow: true),
            requestedView: "/a.md")
        let terminalAskedOfViewer = SplitNameCollision.decide(
            name: "doc",
            existing: viewer("/a.md", inAnchor: true),
            requestedView: nil)
        guard case .conflict = viewerAskedOfTerminal, case .conflict = terminalAskedOfViewer else {
            Issue.record("expected conflicts, got \(viewerAskedOfTerminal) / \(terminalAskedOfViewer)")
            return
        }
    }

    /// Window names and pane names share one namespace.
    @Test func aWindowNameIsNeverReusedAsAPane() {
        let result = SplitNameCollision.decide(
            name: "window-2",
            existing: .init(kind: .window, windowName: "window-2", inAnchorWindow: false),
            requestedView: nil)
        guard case .conflict(let error) = result else {
            Issue.record("expected a conflict, got \(result)")
            return
        }
        #expect(error.contains("name of a window"))
    }

    @Test func createdMessageNamesPaneWindowAndView() {
        let parsed = IPCServer.parseArguments(["--name=doc", "--view=/a.md"])
        #expect(IPCServer.createdMessage(parsed, in: "dev") == "created pane 'doc' in window 'dev', showing /a.md")
        let unnamed = IPCServer.parseArguments(["--direction=down"])
        #expect(IPCServer.createdMessage(unnamed, in: "dev") == "created a split in window 'dev'")
    }
}

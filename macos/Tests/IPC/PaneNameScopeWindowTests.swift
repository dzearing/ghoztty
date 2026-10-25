import AppKit
import Testing
@testable import Ghostty

/// Pane names belong to the window they were created in. Two agents in two
/// windows both asking for a side pane called `draft` used to collide: the
/// second got exit 0 and "reused it" — a pane in the OTHER window — and
/// reported a side pane the user never saw. These drive the real IPC server
/// against real windows, with `--caller-pane=` set the way the CLI sets it
/// from `$GHOZTTY_PANE_ID`.
@MainActor
@Suite(.serialized)
struct PaneNameScopeWindowTests {
    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private var server: IPCServer {
        get throws { try #require((NSApp.delegate as? AppDelegate)?.ipcServer) }
    }

    /// One terminal running `cat`, in a window of its own.
    private func window(_ name: String) async throws -> (TerminalController, PaneView) {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: pane))
        controller.windowName = name
        controller.paneSidebarState.isHidden = true
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        controller.window?.setContentSize(NSSize(width: 1400, height: 600))
        await settle(0.5)
        return (controller, pane)
    }

    /// Run one command the way the socket does: off the main thread, which
    /// the handlers hop back onto.
    private func run(_ action: String, _ arguments: [String], from caller: PaneView? = nil) async throws -> IPCResponse {
        let server = try self.server
        let request = IPCRequest(action: action, arguments: arguments, callerPane: caller?.id.uuidString)
        return await Task.detached { server.dispatch(request) }.value
    }

    private func viewers(_ controller: TerminalController) -> [PaneView] {
        controller.surfaceTree.filter { $0.viewerView != nil }
    }

    private func terminals(_ controller: TerminalController) -> [PaneView] {
        controller.surfaceTree.filter { $0.surfaceView != nil }
    }

    private func screen(_ pane: PaneView) async throws -> String {
        let response = try await run("read", ["--name=\(pane.id.uuidString)", "--lines=20"])
        guard case .readResult(let result)? = response.data else { return "" }
        return result.text
    }

    /// The reported bug: two windows, the same `+split --name=draft --view=…`
    /// from each. Each window gets its own side pane.
    @Test func theSameNameInTwoWindowsOpensTwoPanes() async throws {
        let (a, paneA) = try await window("scope-a")
        let (b, paneB) = try await window("scope-b")
        defer { a.close(); b.close() }

        let first = try await run("split", ["--name=draft", "--view=about:blank", "--caller-pane=\(paneA.id.uuidString)"])
        #expect(first.success, "\(first.error ?? "")")
        let second = try await run("split", ["--name=draft", "--view=about:blank", "--caller-pane=\(paneB.id.uuidString)"])
        #expect(second.success, "\(second.error ?? "")")
        #expect(second.message?.hasPrefix("created pane 'draft' (") == true, "\(second.message ?? "")")
        #expect(second.message?.contains("in window 'scope-b'") == true, "\(second.message ?? "")")
        #expect(viewers(a).count == 1)
        #expect(viewers(b).count == 1, "window B got its own side pane")

        // Re-running B's launch is still idempotent — in B.
        let again = try await run("split", ["--name=draft", "--view=about:blank", "--caller-pane=\(paneB.id.uuidString)"])
        #expect(again.success)
        #expect(again.message?.contains("this window ('scope-b')") == true, "\(again.message ?? "")")
        #expect(viewers(b).count == 1)
    }

    /// `+close --target=draft` from B closes B's pane, never A's.
    @Test func closeFromAWindowClosesItsOwnPane() async throws {
        let (a, paneA) = try await window("scope-c")
        let (b, paneB) = try await window("scope-d")
        defer { a.close(); b.close() }

        for caller in [paneA, paneB] {
            let response = try await run("split", ["--name=draft", "--view=about:blank", "--caller-pane=\(caller.id.uuidString)"])
            #expect(response.success, "\(response.error ?? "")")
        }
        // The way the CLI sends it: the caller's pane as a request field.
        let close = try await run("close", ["--target=draft"], from: paneB)
        #expect(close.success)
        await settle(0.5)
        #expect(viewers(a).count == 1, "A's pane is untouched")
        #expect(viewers(b).isEmpty, "B's pane closed")
    }

    /// `+send-keys --target=shell` from B types into B's `shell`; with no
    /// caller pane the name is ambiguous and the command says so.
    @Test func sendKeysFromAWindowReachesItsOwnPane() async throws {
        let (a, paneA) = try await window("scope-e")
        let (b, paneB) = try await window("scope-f")
        defer { a.close(); b.close() }

        for caller in [paneA, paneB] {
            let response = try await run("split", ["--name=shell", "--command=/bin/cat", "--caller-pane=\(caller.id.uuidString)"])
            #expect(response.success, "\(response.error ?? "")")
        }
        for _ in 0..<50 where terminals(a).count < 2 || terminals(b).count < 2 { await settle(0.1) }
        let shellA = try #require(terminals(a).first { $0 !== paneA })
        let shellB = try #require(terminals(b).first { $0 !== paneB })
        await settle(2)

        let sent = try await run("send-keys", ["--target=shell", "--keys=marker-for-b\n", "--caller-pane=\(paneB.id.uuidString)"])
        #expect(sent.success, "\(sent.error ?? "")")
        await settle(1)
        #expect(try await screen(shellB).contains("marker-for-b"), "B's shell got the keys")
        #expect(try await !screen(shellA).contains("marker-for-b"), "A's shell did not")

        let ambiguous = try await run("send-keys", ["--target=shell", "--keys=x"])
        #expect(!ambiguous.success)
        #expect(ambiguous.error?.contains("scope-e") == true && ambiguous.error?.contains("scope-f") == true,
                "\(ambiguous.error ?? "")")
    }

    /// A name held only in another window is still reachable from here when
    /// it is the only one — "this window first", not "this window only".
    @Test func aNameOnlyAnotherWindowHoldsIsStillReachable() async throws {
        let (a, paneA) = try await window("scope-g")
        let (b, paneB) = try await window("scope-h")
        defer { a.close(); b.close() }

        let split = try await run("split", ["--name=worker", "--command=/bin/cat", "--caller-pane=\(paneA.id.uuidString)"])
        #expect(split.success)
        for _ in 0..<50 where terminals(a).count < 2 { await settle(0.1) }
        await settle(1.5)
        let sent = try await run("send-keys", ["--target=worker", "--keys=hello-worker\n", "--caller-pane=\(paneB.id.uuidString)"])
        #expect(sent.success, "\(sent.error ?? "")")
    }

    /// The reply is sent after the split, not before it: by the time the
    /// CLI prints "created", the pane exists, and the line names it.
    @Test func theReplySaysWhereThePaneIsAndThatItIsOnShow() async throws {
        let (a, paneA) = try await window("scope-i")
        defer { a.close() }
        let response = try await run("split", ["--view=about:blank", "--caller-pane=\(paneA.id.uuidString)"])
        #expect(response.success)
        let message = try #require(response.message)
        #expect(message.contains("in window 'scope-i'"), "\(message)")
        #expect(message.contains("pane "), "names the pane id: \(message)")
        #expect(!message.contains("minimized"), "\(message)")
        #expect(viewers(a).count == 1, "the pane exists by the time the reply says so")
    }
}

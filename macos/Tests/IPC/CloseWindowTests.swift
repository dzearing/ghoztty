import AppKit
import Testing
@testable import Ghostty

/// `+close` against real windows. A close that raised the "Close Terminal?"
/// confirmation used to answer success while the window sat waiting on a
/// sheet nothing on the IPC path could answer; `--force` closes with no
/// confirmation and no undo window, and ends the panes' processes at once.
@MainActor
@Suite(.serialized)
struct CloseWindowTests {
    private func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private var server: IPCServer {
        get throws { try #require((NSApp.delegate as? AppDelegate)?.ipcServer) }
    }

    /// One terminal running `cat` (a live process, so a close asks first), in
    /// a background window of its own.
    private func window(_ name: String) async throws -> (TerminalController, PaneView) {
        let ghostty = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        let app = try #require(ghostty.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        let pane = PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config))
        let controller = TerminalController.newWindow(ghostty, tree: SplitTree<PaneView>(view: pane), activate: false)
        controller.windowName = name
        for _ in 0..<100 where controller.window?.isVisible != true { await settle(0.1) }
        for _ in 0..<50 where pane.surfaceView?.surfaceModel?.foregroundPID == nil { await settle(0.1) }
        return (controller, pane)
    }

    private func run(_ action: String, _ arguments: [String]) async throws -> IPCResponse {
        let server = try self.server
        let request = IPCRequest(action: action, arguments: arguments, callerPane: nil)
        return await Task.detached { server.dispatch(request) }.value
    }

    private func listed(_ name: String) -> Bool {
        TerminalController.all.contains { $0.windowName == name }
    }

    private func alive(_ pid: Int?) -> Bool {
        guard let pid, pid > 0 else { return false }
        return kill(pid_t(pid), 0) == 0
    }

    private func waitUntil(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await settle(0.1)
        }
        return condition()
    }

    /// The reported bug: a window waiting on its close confirmation. Plain
    /// `+close` now says so (and fails) instead of claiming success; `--force`
    /// takes the sheet down, closes the window and ends its process now.
    @Test func forceClosesAWindowWaitingOnItsConfirmation() async throws {
        let name = "close-confirm"
        var pid: Int?
        do {
            let (controller, pane) = try await window(name)
            pid = pane.surfaceView?.surfaceModel?.foregroundPID
            #expect(alive(pid), "cat never started")
            controller.closeWindow(nil)
            #expect(await waitUntil { controller.window?.attachedSheet != nil },
                    "a live process did not raise the close confirmation")
        }

        let plain = try await run("close", ["--target=\(name)"])
        #expect(!plain.success, "a close stuck on a confirmation reported success")
        #expect(plain.error?.contains("waiting on a close confirmation") == true, "\(plain.error ?? "")")
        #expect(listed(name), "the window should still be there, waiting")

        let forced = try await run("close", ["--target=\(name)", "--force"])
        #expect(forced.success, "\(forced.error ?? "")")
        #expect(await waitUntil { !listed(name) }, "--force left the window open")
        #expect(await waitUntil { !alive(pid) }, "--force left the process running")
    }

    /// No confirmation up at all: `--force` still ends the process at once,
    /// where a plain close leaves it for the undo window.
    @Test func forceEndsALiveWindowsProcessAtOnce() async throws {
        let name = "close-live"
        var pid: Int?
        do {
            let (_, pane) = try await window(name)
            pid = pane.surfaceView?.surfaceModel?.foregroundPID
            #expect(alive(pid))
        }
        let forced = try await run("close", ["--target=\(name)", "--force"])
        #expect(forced.success, "\(forced.error ?? "")")
        #expect(await waitUntil { !listed(name) })
        #expect(await waitUntil { !alive(pid) }, "the process outlived a forced close")
    }

    /// A pane, by its id, in a split window: the pane goes, with its process,
    /// and the rest of the window stays.
    @Test func forceClosesOnePaneOfASplitWindow() async throws {
        let name = "close-pane"
        let (controller, first) = try await window(name)
        defer { controller.closeWindowImmediately() }
        let split = try await run("split", ["--target=\(name)", "--name=second", "--command=/bin/cat"])
        #expect(split.success, "\(split.error ?? "")")
        #expect(await waitUntil { Array(controller.surfaceTree).count == 2 })
        let pid = first.surfaceView?.surfaceModel?.foregroundPID

        let forced = try await run("close", ["--target=\(first.id.uuidString)", "--force"])
        #expect(forced.success, "\(forced.error ?? "")")
        #expect(await waitUntil { Array(controller.surfaceTree).count == 1 }, "the pane is still in the tree")
        #expect(listed(name), "closing one pane closed the whole window")
        #expect(await waitUntil { !alive(pid) }, "the closed pane's process is still running")
    }
}

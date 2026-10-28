import AppKit
import Testing
@testable import Ghostty

/// A window title the user typed outranks any script's: `+rename` (what the
/// skills call) leaves it alone and says so, `+list` reports who set it, and
/// a script may rename the window again once the user clears it.
@MainActor
@Suite(.serialized)
struct UserWindowTitleTests {
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

    private func run(_ action: String, _ arguments: [String]) async throws -> IPCResponse {
        let server = try #require((NSApp.delegate as? AppDelegate)?.ipcServer)
        let request = IPCRequest(action: action, arguments: arguments, callerPane: nil)
        return await Task.detached { server.dispatch(request) }.value
    }

    /// `+list --json`'s window entry for `target`.
    private func listed(_ target: String) async throws -> [String: Any]? {
        let response = try await run("list", ["--json"])
        let data = try #require(response.data)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(data)) as? [String: Any]
        let windows = json?["windows"] as? [[String: Any]] ?? []
        return windows.first { $0["target"] as? String == target }
    }

    @Test func aScriptDoesNotRenameOverTheUser() async throws {
        let target = "user-title-test"
        let opened = try await run("new-window", ["--target=\(target)", "--title=proj: script"])
        #expect(opened.success, "\(opened.error ?? "")")
        var found: TerminalController?
        #expect(await poll(timeout: 5) {
            found = TerminalController.all.first { $0.windowTitleOverride == "proj: script" }
            return found != nil
        })
        let c = try #require(found)

        // A script's title: a script may change it.
        #expect(c.windowTitleSetByUser == false)
        #expect(try await listed(target)?["title_set_by_user"] as? Bool == false)
        let scripted = try await run("rename", ["--target=\(target)", "--title=proj: script (prep)"])
        #expect(scripted.success)
        await settle(0.2)
        #expect(c.windowTitleOverride == "proj: script (prep)")

        // The user renames it (the sidebar's field, Change Window Title).
        c.renameWindowKeepingPlace("proj: mine")
        #expect(c.windowTitleSetByUser)
        #expect(try await listed(target)?["title_set_by_user"] as? Bool == true)
        let refused = try await run("rename", ["--target=\(target)", "--title=proj: mine (ready)"])
        #expect(!refused.success, "a script must not rename over the user")
        #expect(refused.error?.contains("proj: mine") == true, "\(refused.error ?? "")")
        await settle(0.2)
        #expect(c.windowTitleOverride == "proj: mine")
        let cleared = try await run("rename", ["--target=\(target)", "--title="])
        #expect(!cleared.success, "nor clear it")
        #expect(c.windowTitleOverride == "proj: mine")

        // The user clears it: it follows its panes, and scripts may name it.
        c.renameWindowKeepingPlace(nil)
        #expect(!c.windowTitleSetByUser)
        let again = try await run("rename", ["--target=\(target)", "--title=proj: script"])
        #expect(again.success)
        await settle(0.2)
        #expect(c.windowTitleOverride == "proj: script")

        c.close()
        await settle(0.3)
    }

    /// A user title survives a relaunch: it rides with the title in the
    /// window's restorable state.
    @Test func whoSetTheTitleIsRestored() throws {
        let state = TerminalRestorableState.InternalState<PaneView>(
            focusedSurface: nil, surfaceTree: SplitTree(), effectiveFullscreenMode: nil,
            tabColor: nil, titleOverride: nil, windowTitleOverride: "proj: mine", windowTitleSetByUser: true)
        let decoded = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<PaneView>.self, from: JSONEncoder().encode(state))
        #expect(decoded.windowTitleSetByUser == true)
        // An archive from before the flag: a script's title.
        var legacy = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        legacy.removeValue(forKey: "windowTitleSetByUser")
        let old = try JSONDecoder().decode(
            TerminalRestorableState.InternalState<PaneView>.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.windowTitleSetByUser == nil)
    }
}

import AppKit
import SwiftUI
import GhosttyKit
import Testing
@testable import Ghostty

/// A relaunch brings a window back as it was left: every window restored from
/// a session layout entry, through the same code the launch restore runs
/// (`presentRestoredWindow`, `showRestoredFront`), with local terminals in
/// place of agent sessions — in both window modes. See
/// docs/reference/session-persistence.md "What a relaunch restores".
@MainActor
@Suite(.serialized)
final class SessionLayoutRelaunchTests {
    private var opened: [TerminalController] = []

    init() {
        WorkspaceHost.shared.resetForTesting()
    }

    deinit {
        MainActor.assumeIsolated {
            for controller in opened.reversed() where !controller.windowHasClosed {
                controller.forceCloseWindow()
            }
            for controller in opened {
                for pane in controller.surfaceTree { pane.surfaceView?.releaseClosedSurface() }
            }
            WorkspaceHost.shared.resetForTesting()
            WindowMode.overrideForTesting = nil
        }
    }

    // MARK: Helpers

    private var delegate: AppDelegate {
        get throws { try #require(NSApp.delegate as? AppDelegate) }
    }

    private func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// The panes drawn as strips (blades) in `controller`'s content.
    private func strips(_ controller: TerminalController) -> Set<UUID> {
        guard let content = controller.contentContainer else { return [] }
        return Set(all(PaneStackTabView.self, in: content).filter { $0.isStrip }.compactMap { $0.pane?.id })
    }

    private static func leaf(_ title: String = "~") -> SessionLayoutManifest.Leaf {
        SessionLayoutManifest.Leaf(title: title, surfaceID: UUID().uuidString)
    }

    /// `leaves` side by side, left to right, each an even share.
    private static func row(_ leaves: [SessionLayoutManifest.Leaf]) -> SessionLayoutManifest.Node {
        guard leaves.count > 1 else { return .leaf(leaves[0]) }
        return .split(.init(
            direction: .horizontal, ratio: 1 / Double(leaves.count),
            left: .leaf(leaves[0]), right: row(Array(leaves.dropFirst()))))
    }

    /// Restore `entries` as the launch restore does: in order, the frontmost
    /// last, then the front one on show in single-window mode.
    private func restore(_ entries: [SessionLayoutManifest.Entry]) throws -> [TerminalController] {
        let delegate = try delegate
        let app = try #require(delegate.ghostty.app)
        var restored: [TerminalController] = []
        for entry in entries {
            let tree = try #require(entry.tree)
            let windowName = entry.ipcName ?? BaseTerminalController.mintWindowName()
            let root = AppDelegate.makeRestoredRoot(tree: tree, app: app, windowName: windowName) {
                $0.command = "/bin/cat"
            }
            let controller = delegate.presentRestoredWindow(
                entry: entry, tree: tree, root: root,
                windowName: windowName, persistedName: entry.ipcName,
                connection: nil, tabParent: nil, bindLocal: true, reanchorFrame: false)
            opened.append(controller)
            restored.append(controller)
        }
        if let front = restored.last, let entry = entries.last {
            AppDelegate.showRestoredFront(front, entry: entry)
        }
        return restored
    }

    /// The window a restored controller is on show in.
    private func window(of controller: TerminalController) async throws -> NSWindow {
        #expect(await poll(timeout: 10) { controller.window?.isVisible == true })
        let window = try #require(controller.window)
        WindowInUse.setInUseForTesting(window, true)
        return window
    }

    // MARK: Blades

    /// A row of five terminals the user collapsed to three on show comes back
    /// with its two blades, in the window that is on show — blades at the
    /// trailing edge, and at the leading edge. It used to come back side by
    /// side: the content's first appearance let SwiftUI pick a terminal to
    /// focus, the LAST one, a trailing blade; and in `separate` mode AppKit
    /// made the FIRST one first responder as the window came on screen, a
    /// leading blade, which the restore then took for the pane focused last.
    /// Focusing a blade brings it out. (`contentDidAppear`,
    /// `focusOnFirstShow`.) The viewer blade of `aRestoredWindowKeepsItsBlades`
    /// hid this: SwiftUI never picks a viewer.
    @Test(arguments: [Ghostty.Config.MacOSWindowMode.separate, .single])
    func aRestoredRowOfTerminalsKeepsItsBlades(mode: Ghostty.Config.MacOSWindowMode) async throws {
        WindowMode.overrideForTesting = mode
        let frame = SessionLayoutManifest.Frame(NSRect(x: 80, y: 80, width: 1400, height: 700))
        // (run start, blades, focus history), by leaf position.
        let shapes: [(start: Int, blades: [Int], recency: [Int])] = [
            (0, [3, 4], [2, 3, 4, 1, 0]),
            (2, [0, 1], [2, 0, 1, 3, 4]),
        ]
        for shape in shapes {
            // Twice each: the focus SwiftUI picked raced the restore's.
            for _ in 0..<2 {
                var other = SessionLayoutManifest.Entry(id: UUID())
                other.tree = .leaf(Self.leaf())
                other.frame = frame
                var entry = SessionLayoutManifest.Entry(id: UUID())
                entry.tree = Self.row((0..<5).map { _ in Self.leaf() })
                entry.frame = frame
                entry.frontmost = true
                entry.paneStack = .init(
                    rows: [.init(leaves: [0, 1, 2, 3, 4], start: shape.start, count: 3, shares: nil)],
                    recency: shape.recency)

                let restored = try restore([other, entry])
                let front = try #require(restored.last)
                let window = try await window(of: front)
                let ids = front.surfaceTree.root?.leaves().map(\.id) ?? []
                try #require(ids.count == 5)
                let blades = Set(shape.blades.map { ids[$0] })
                #expect(await poll(timeout: 5) { self.strips(front) == blades })
                await settle(1.5)
                #expect(strips(front) == blades,
                        "\(mode) start \(shape.start): blades \(strips(front).compactMap(ids.firstIndex)) on show")
                #expect(front.persistedPaneStack?.rows.first?.start == shape.start, "the collapse is still saved")
                #expect(front.surfaceTree.first { $0.holdsKeyboardFocus }?.id == ids[2],
                        "\(mode) start \(shape.start): the caret is in the pane focused last, not \(String(describing: window.firstResponder))")
                for controller in restored.reversed() { controller.forceCloseWindow() }
                WorkspaceHost.shared.resetForTesting()
                await settle(0.3)
            }
        }
    }

    // MARK: Everything else

    /// Every attribute a window saves comes back with a relaunch, and is
    /// saved again the same: the frame, the split layout and its ratios, a
    /// stashed pane, the window's name and titles, a pane's name, its
    /// user-set title, banner and tint, the window's gradient and tab color,
    /// the pane sidebar's order and identity, and which window was in front.
    /// The pane tint, the user-set pane title and the tab color used to be
    /// lost: the manifest had no place for them.
    @Test(arguments: [Ghostty.Config.MacOSWindowMode.separate, .single])
    func aRelaunchRestoresEveryAttribute(mode: Ghostty.Config.MacOSWindowMode) async throws {
        WindowMode.overrideForTesting = mode
        let suffix = "\(mode)-\(UUID().uuidString.prefix(6))"
        var a = Self.leaf("Build")
        a.ipcName = "pane-a-\(suffix)"
        a.titleSetByUser = true
        a.banner = "## Release\n**Goal** ship it"
        a.tint = "#336699"
        let b = Self.leaf("~/git")
        var c = Self.leaf("stashed")
        c.stashIndex = 0
        let ids = [a, b, c].map { UUID(uuidString: $0.surfaceID!)! }

        var entry = SessionLayoutManifest.Entry(id: UUID())
        entry.frame = .init(NSRect(x: 120, y: 90, width: 1300, height: 760))
        entry.tree = .split(.init(
            direction: .horizontal, ratio: 0.3, left: .leaf(a),
            right: .split(.init(direction: .vertical, ratio: 0.7, left: .leaf(b), right: .leaf(c)))))
        entry.ipcName = "window-\(suffix)"
        entry.titleOverride = "tab title"
        entry.windowTitleOverride = "project"
        entry.windowTitleSetByUser = true
        entry.deskVariant = PaneDeskVariant(seed: 42)
        entry.paneSidebarOrder = [ids[2], ids[0], ids[1]]
        entry.paneSidebarWindowID = UUID()
        entry.tabColor = .purple
        entry.frontmost = true
        entry.paneStack = .init(rows: [], recency: [1, 0])

        let restored = try restore([entry])
        let controller = try #require(restored.first)
        let window = try await window(of: controller)
        await settle(0.8)

        // On the live window.
        #expect(window.frame == entry.frame?.rect, "frame \(window.frame)")
        guard case .split(let outer)? = controller.surfaceTree.root,
              case .split(let inner) = outer.right else {
            Issue.record("the split layout came back as \(String(describing: controller.surfaceTree.root))")
            return
        }
        #expect(outer.direction == .horizontal && abs(outer.ratio - 0.3) < 0.001)
        #expect(inner.direction == .vertical && abs(inner.ratio - 0.7) < 0.001)
        #expect(controller.surfaceTree.root?.leaves().map(\.id) == ids)
        #expect(controller.surfaceTree.stashed == [ids[2]], "the stashed pane is still stashed")
        let ipc = try delegate.ipcServer
        #expect(controller.windowName == entry.ipcName)
        #expect(ipc.registeredWindowName(forController: controller) == entry.ipcName)
        let paneA = try #require(controller.surfaceTree.first { $0.id == ids[0] }?.surfaceView)
        #expect(ipc.registeredPaneName(forSurface: paneA) == a.ipcName)
        #expect(paneA.title == "Build" && paneA.isTitleUserSet, "the user's pane title is still pinned")
        #expect(paneA.paneBanner == a.banner)
        #expect(paneA.backgroundTintNSColor.map(SessionLayoutManifest.tintHex) == "#336699")
        #expect(controller.titleOverride == "tab title")
        #expect(controller.windowTitleOverride == "project" && controller.windowTitleIsUsers)
        #expect(controller.deskVariant == PaneDeskVariant(seed: 42))
        #expect(controller.paneSidebarPersistedOrder == entry.paneSidebarOrder)
        #expect(controller.paneSidebarState.windowID == entry.paneSidebarWindowID)
        #expect(controller.persistedTabColor == .purple)
        #expect(controller.surfaceTree.first { $0.holdsKeyboardFocus }?.id == ids[1], "the pane focused last")

        // Saved again: the same entry, from the live window.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("relaunch-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let manifest = SessionLayoutManifest(fileURL: file)
        manifest.adopt(SessionLayoutManifest.Entry(id: entry.id))
        manifest.sync(controller)
        let saved = try #require(manifest.allEntries().first)
        // The session's own fields are the agent's, not the layout's.
        func stripped(_ node: SessionLayoutManifest.Node?) -> SessionLayoutManifest.Node? {
            switch node {
            case .none: return nil
            case .leaf(var leaf)?:
                leaf.sessionID = nil
                leaf.screenSnapshot = nil
                leaf.screenSnapshotOffset = nil
                return .leaf(leaf)
            case .split(let split)?:
                return .split(.init(
                    direction: split.direction, ratio: split.ratio,
                    left: stripped(split.left)!, right: stripped(split.right)!))
            }
        }
        #expect(stripped(saved.tree) == stripped(entry.tree), "tree \(String(describing: saved.tree))")
        #expect(saved.frame == entry.frame)
        #expect(saved.ipcName == entry.ipcName)
        #expect(saved.titleOverride == entry.titleOverride)
        #expect(saved.windowTitleOverride == entry.windowTitleOverride)
        #expect(saved.windowTitleSetByUser == true)
        #expect(saved.deskVariant == entry.deskVariant)
        #expect(saved.paneSidebarOrder == entry.paneSidebarOrder)
        #expect(saved.paneSidebarWindowID == entry.paneSidebarWindowID)
        #expect(saved.tabColor == .purple)
        if mode == .single {
            #expect(WorkspaceHost.shared.active === controller, "the front window is on show")
            #expect(saved.frontmost == true)
        }
        #expect(saved.paneStack?.recency.first == 1)

        // A pane retitled by the user is saved at once, not only at quit.
        SessionLayoutManifest.shared.adopt(saved)
        defer {
            SessionLayoutManifest.shared.remove(entry.id)
            SessionLayoutManifest.shared.flushWrites()
        }
        paneA.setUserTitle("Renamed")
        let renamed = await poll(timeout: 5) {
            let entry = SessionLayoutManifest.shared.allEntries().first { $0.id == entry.id }
            guard case .split(let split)? = entry?.tree, case .leaf(let leaf) = split.left else { return false }
            return leaf.title == "Renamed" && leaf.titleSetByUser == true
        }
        #expect(renamed, "the retitled pane is saved")
    }

    /// A manifest from before the pane tint, the user-set pane title and the
    /// tab color still loads, and one with them still loads in a build that
    /// predates them (unknown keys are ignored by `Codable`).
    @Test func theNewFieldsAreAdditive() async throws {
        let old = #"[{"id":"6B1C1F0E-8E77-4C29-A8F1-1D4B7E0A9C11","tabIndex":0,"tree":{"leaf":{"_0":{"title":"~"}}}}]"#
        let entries = try JSONDecoder().decode([SessionLayoutManifest.Entry].self, from: Data(old.utf8))
        #expect(entries.first?.tabColor == nil)
        guard case .leaf(let leaf)? = entries.first?.tree else {
            Issue.record("no leaf")
            return
        }
        #expect(leaf.tint == nil && leaf.titleSetByUser == nil)

        // What an older build does with them: a key it does not know is
        // skipped. (A leaf from a newer build still decodes here.)
        let newer = ##"{"title":"x","tint":"#112233","titleSetByUser":true,"someFutureField":[1,2]}"##
        let leafFromNewer = try JSONDecoder().decode(SessionLayoutManifest.Leaf.self, from: Data(newer.utf8))
        #expect(leafFromNewer.title == "x" && leafFromNewer.tint == "#112233")
    }

    // MARK: AppKit restoration

    /// With session persistence off, AppKit restoration brings a window back:
    /// it keeps the same attributes. The window's and a pane's IPC names, a
    /// pane's banner and its tint used to be lost on this path.
    @Test(arguments: [Ghostty.Config.MacOSWindowMode.separate, .single])
    func appKitRestorationKeepsEveryAttribute(mode: Ghostty.Config.MacOSWindowMode) async throws {
        WindowMode.overrideForTesting = mode
        let delegate = try delegate
        let ghostty = delegate.ghostty
        let app = try #require(ghostty.app)
        let ipc = delegate.ipcServer
        let suffix = "\(mode)-\(UUID().uuidString.prefix(6))"
        let windowName = "appkit-window-\(suffix)", paneName = "appkit-pane-\(suffix)"

        // The window as the user left it, archived as AppKit archives it.
        let (archive, ids): (Data, [UUID]) = try await {
            var config = Ghostty.SurfaceConfiguration()
            config.command = "/bin/cat"
            let panes = (0..<3).map { _ in PaneView(surface: Ghostty.SurfaceView(app, baseConfig: config)) }
            var tree = SplitTree<PaneView>(view: panes[0])
            tree = try tree.inserting(view: panes[1], at: panes[0], direction: .right)
            tree = try tree.inserting(view: panes[2], at: panes[1], direction: .down)
            let controller = TerminalController.newWindow(ghostty, tree: tree)
            let window = try await window(of: controller)
            window.setContentSize(NSSize(width: 1300, height: 700))
            await settle(0.5)
            ipc.registerRestoredRemoteWindow(name: windowName, controller: controller)
            let surface = try #require(panes[0].surfaceView)
            ipc.registerRestoredPane(name: paneName, controller: controller, surface: surface)
            surface.setUserTitle("Build")
            surface.paneBanner = "## Release"
            let tint = try #require(NSColor(hex: "#336699"))
            surface.backgroundTintNSColor = tint
            surface.backgroundTint = Color(tint)
            controller.deskVariant = PaneDeskVariant(seed: 7)
            controller.restoreTabColor(.teal)
            controller.paneSidebarState.order = [panes[2].id, panes[0].id, panes[1].id]
            #expect(controller.stashPane(panes[2]))
            controller.setWindowTitle("project")
            let coder = NSKeyedArchiver(requiringSecureCoding: true)
            controller.window(window, willEncodeRestorableState: coder)
            coder.finishEncoding()
            let ids = panes.map(\.id)
            controller.forceCloseWindow()
            for pane in panes { pane.surfaceView?.releaseClosedSurface() }
            return (coder.encodedData, ids)
        }()
        // The names are free again once the window that held them is gone.
        #expect(await poll(timeout: 10) { !ipc.isWindowNameTaken(windowName) })

        let before = Set(TerminalController.all.map(ObjectIdentifier.init))
        let decoder = try NSKeyedUnarchiver(forReadingFrom: archive)
        decoder.requiresSecureCoding = true
        TerminalWindowRestoration.restoreWindow(
            withIdentifier: .init(String(describing: TerminalWindowRestoration.self)),
            state: decoder
        ) { _, _ in }
        await settle(0.5)
        let restored = try #require(TerminalController.all.first { !before.contains(ObjectIdentifier($0)) })
        opened.append(restored)
        // What AppKit does with the window the completion handler hands it.
        if mode == .single { WorkspaceHost.shared.show(restored) } else { restored.showWindow(nil) }
        _ = try await window(of: restored)
        await settle(0.8)

        #expect(restored.surfaceTree.root?.leaves().map(\.id) == ids)
        #expect(restored.surfaceTree.stashed == [ids[2]])
        #expect(ipc.registeredWindowName(forController: restored) == windowName)
        let surface = try #require(restored.surfaceTree.first { $0.id == ids[0] }?.surfaceView)
        #expect(ipc.registeredPaneName(forSurface: surface) == paneName)
        #expect(surface.title == "Build" && surface.isTitleUserSet)
        #expect(surface.paneBanner == "## Release")
        #expect(surface.backgroundTintNSColor.map(SessionLayoutManifest.tintHex) == "#336699")
        #expect(restored.deskVariant == PaneDeskVariant(seed: 7))
        #expect(restored.persistedTabColor == .teal)
        #expect(restored.paneSidebarPersistedOrder == [ids[2], ids[0], ids[1]])
        #expect(restored.windowTitleOverride == "project")
    }
}

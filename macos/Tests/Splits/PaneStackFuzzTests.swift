import AppKit
import Testing
@testable import Ghostty

/// Random sequences of what a user does to a window of stacked rows —
/// collapse, widen, focus, split, close, resize — against `PaneStackState`
/// and `PaneLayout` together, the way the controller drives them, checking
/// the rules a strip lives by after every step:
///
/// - the focused pane is on show;
/// - focusing a pane on show changes no row;
/// - focusing a strip brings out only panes of its own collapsed rows;
/// - adding or removing a pane never brings a strip out, except where the
///   rules say so (the only pane on show closed; a row that stopped being
///   the row the user collapsed);
/// - a pane on show is never under the minimum when there is room.
struct PaneStackFuzzTests {
    /// The controller's side of a window: a tree, its stack state, a size.
    final class Window {
        var tree: SplitTree<MockView>
        let state = PaneStackState()
        var width: CGFloat = 1600
        let height: CGFloat = 2400
        var focused: MockView
        /// Elevated or flat (`Metrics.forStyle`).
        var metrics = PaneLayout.Metrics.forStyle(paneGap: 10)
        var log: [String] = []
        /// A short name for each pane, in creation order, for the log.
        var names: [UUID: String] = [:]

        func name(_ id: UUID) -> String {
            if let n = names[id] { return n }
            let n = String(UnicodeScalar(UInt8(97 + names.count)))
            names[id] = n
            return n
        }

        /// The window as one line: its rows, each item's panes, the run of
        /// a collapsed row in brackets; the strips; the focus.
        var summary: String {
            let rows = PaneLayout.rows(tree.root).map { row -> String in
                let pin = state.pin(for: Set(row.joined()))
                return row.enumerated().map { i, item in
                    let text = item.map(name).joined()
                    guard let pin else { return text }
                    return (pin.start..<(pin.start + pin.count)).contains(i) ? "[\(text)]" : text
                }.joined(separator: " ")
            }
            return rows.joined(separator: " ; ") + "  strips: " + tucked().map(name).sorted().joined()
                + "  focus: " + name(focused.id) + "  w=\(Int(width))"
        }

        init(panes: Int) throws {
            let views = (0..<panes).map { _ in MockView() }
            var tree = SplitTree<MockView>(view: views[0])
            for i in 1..<panes { tree = try tree.inserting(view: views[i], at: views[i - 1], direction: .right) }
            self.tree = SplitTree(root: tree.root?.equalize(), zoomed: nil, stashed: [])
            focused = views[0]
            focus(views[0])
        }

        var panes: [MockView] { tree.root?.leaves() ?? [] }

        /// Lay out as the grid does, noting each stack's items and room.
        @discardableResult
        func layout() -> PaneLayout.Result<MockView> {
            let ranks = Dictionary(uniqueKeysWithValues: state.recency.enumerated().map { ($1, $0) })
            let pins = state.pins, shares = state.shares
            let state = state
            let result = PaneLayout.compute(
                tree.root!, in: CGRect(x: 0, y: 0, width: width, height: height), metrics: metrics,
                rank: { ranks[$0.id] }, pin: { pins[$0] }, shares: { shares[$0] },
                shown: { state.shownRun($0) })
            state.noteStacks(result.stacks)
            return result
        }

        /// The panes minimized by a collapse: tucked in a window wide enough
        /// that no row stacks for want of room (those follow focus, by
        /// design). Notes nothing, so it changes no state.
        func tucked() -> Set<UUID> {
            let ranks = Dictionary(uniqueKeysWithValues: state.recency.enumerated().map { ($1, $0) })
            let pins = state.pins
            let result = PaneLayout.compute(
                tree.root!, in: CGRect(x: 0, y: 0, width: 100_000, height: 100_000), metrics: metrics,
                rank: { ranks[$0.id] }, pin: { pins[$0] })
            return Set(result.leaves.filter { $0.value.isTucked }.map(\.key))
        }

        func focus(_ view: MockView) {
            focused = view
            state.noteFocus(view.id)
            layout()
        }

        /// What `BaseTerminalController.splitDidRestack` does.
        func restack(_ row: PaneLayout.Row<UUID>, _ change: PaneLayout.Restack) {
            state.restack(row, change)
            layout()
            guard let pin = state.pin(for: row.key),
                  let index = row.items.firstIndex(where: { $0.contains(focused.id) })
            else { return }
            let target = min(max(index, pin.start), pin.start + pin.count - 1)
            guard target != index else { return }
            let id = row.items[target].min { (state.rank(of: $0) ?? .max) < (state.rank(of: $1) ?? .max) }
            if let pane = panes.first(where: { $0.id == id }) { focus(pane) }
        }

        /// What `BaseTerminalController.removeSurfaceNode` does.
        func close(_ view: MockView) {
            let node = tree.root!.node(view: view)!
            let newTree = tree.removing(node)
            var next: MockView?
            if focused === view {
                let candidate = tree.root!.leftmostLeaf() === view
                    ? tree.focusTarget(for: .next, from: node)
                    : tree.focusTarget(for: .previous, from: node)
                next = candidate.map { candidate in
                    let id = state.paneOnShow(
                        instead: candidate.id,
                        from: PaneLayout.rows(tree.root), to: PaneLayout.rows(newTree.root))
                    return newTree.root!.leaves().first { $0.id == id } ?? candidate
                }
            }
            let old = PaneLayout.rows(tree.root)
            tree = newTree
            state.rowsDidChange(from: old, to: PaneLayout.rows(tree.root))
            layout()
            if let next { focus(next) }
        }

        /// A split of `view`, focusing the new pane (Cmd-D).
        func split(_ view: MockView, _ direction: SplitTree<MockView>.NewDirection) throws -> MockView {
            let added = MockView()
            let old = PaneLayout.rows(tree.root)
            tree = try tree.inserting(view: added, at: view, direction: direction)
            state.rowsDidChange(from: old, to: PaneLayout.rows(tree.root))
            layout()
            focus(added)
            return added
        }
    }

    @Test(arguments: 0..<1000)
    func randomSequencesKeepStripsMinimized(seed: Int) throws {
        var rng = SplitMix64(seed: UInt64(seed) &* 7919 &+ 17)
        func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }
        let window = try Window(panes: 3 + Int(rng.next() % 4))
        if seed % 2 == 1 { window.metrics = .forStyle(paneGap: nil) }
        window.log.append("start  =>  " + window.summary)

        for step in 0..<50 {
            let before = window.tucked()
            let pinsBefore = window.state.pins
            let rowsBefore = PaneLayout.rows(window.tree.root)
            let result = window.layout()
            let op = rng.next() % 9
            var description = ""
            switch op {
            case 0, 1:
                // Collapse a row from a divider or a grip between cards.
                var rows: [PaneLayout.Row<UUID>] = result.dividers.map(\.row)
                rows += result.stackHandles.filter { if case .between = $0.kind { true } else { false } }.map(\.row)
                guard !rows.isEmpty else { continue }
                let row = pick(rows)
                let side: PaneLayout.Side = pick([.leading, .trailing])
                description = "collapse \(side) of \(row.items.count)-row run \(row.run)"
                window.restack(row, .collapse(side))
            case 2:
                // Widen at a run's edge.
                let grips = result.stackHandles.filter { if case .expand = $0.kind { true } else { false } }
                guard !grips.isEmpty else { continue }
                let grip = pick(grips)
                guard case .expand(let side) = grip.kind else { continue }
                description = "expand \(side)"
                window.restack(grip.row, .expand(side))
            case 3:
                // Focus anything: a pane on show, or a strip.
                let pane = pick(window.panes)
                let wasTucked = before.contains(pane.id)
                // On screen, at the window's real size: what is tucked for
                // want of room as well as by a collapse.
                let onScreen = Set(window.layout().leaves.filter { $0.value.isTucked }.map(\.key))
                description = "focus \(wasTucked ? "strip" : "shown") \(window.panes.firstIndex { $0 === pane }!)"
                window.focus(pane)
                if !onScreen.contains(pane.id) {
                    // A pane on show, focused, changes nothing on screen.
                    let after = Set(window.layout().leaves.filter { $0.value.isTucked }.map(\.key))
                    #expect(after == onScreen,
                            "seed \(seed) step \(step): focusing a pane on show changed the strips\n\(window.log.joined(separator: "\n"))\n=> \(window.summary)")
                }
                if !wasTucked {
                    #expect(window.state.pins == pinsBefore, "seed \(seed) step \(step): \(description) changed a row\n\(window.log.joined(separator: "\n"))")
                } else {
                    // Only panes of collapsed rows it is in come out.
                    let rows = pinsBefore.keys.filter { $0.contains(pane.id) }
                    let out = before.subtracting(window.tucked())
                    let stray = out.filter { id in !rows.contains { $0.contains(id) } }
                    #expect(stray.isEmpty, "seed \(seed) step \(step): \(description) brought out panes of other rows\n\(window.log.joined(separator: "\n"))\n=> \(window.summary)")
                }
            case 4:
                guard window.panes.count > 2 else { continue }
                let pane = rng.next() % 2 == 0 ? window.focused : pick(window.panes)
                let index = window.panes.firstIndex { $0 === pane }!
                description = "close \(pane === window.focused ? "focused " : "")\(index) (\(before.contains(pane.id) ? "strip" : "shown"))"
                window.close(pane)
                let rowsAfter = PaneLayout.rows(window.tree.root)
                let out = before.subtracting([pane.id]).subtracting(window.tucked())
                // Allowed: a row that lost its only pane on show brings out
                // its neighbour, and a row that stopped being a row (or is
                // not the same row any more) lays out afresh. And a column
                // that emptied into its row, when keeping its strips would
                // minimize the focused pane: a run is contiguous, and the
                // focused pane is on show.
                let keysBefore = Set(rowsBefore.map { Set($0.joined()) })
                let merged = rowsAfter.filter { row in
                    !keysBefore.contains(Set(row.joined())) && row.contains { $0.contains(window.focused.id) }
                }
                let excused = out.filter { id in
                    if merged.contains(where: { $0.joined().contains(id) }) { return true }
                    return rowsBefore.contains { row in
                        let key = Set(row.joined())
                        guard key.contains(id), key.contains(pane.id), let pin = pinsBefore[key] else { return false }
                        let run = pin.start..<(pin.start + pin.count)
                        let onlyOnShow = row.indices.filter { run.contains($0) }.allSatisfy { row[$0].contains(pane.id) }
                        let survived = rowsAfter.contains { Set($0.joined()) == key.subtracting([pane.id]) }
                        return onlyOnShow || !survived
                    }
                }
                #expect(out.subtracting(excused).isEmpty,
                        "seed \(seed) step \(step): \(description) brought strips out: \(out.subtracting(excused).map(window.name))\n\(window.log.joined(separator: "\n"))\n=> \(window.summary)")
            case 5:
                guard window.panes.count < 9 else { continue }
                let shown = window.panes.filter { !before.contains($0.id) }
                let pane = pick(shown)
                let direction: SplitTree<MockView>.NewDirection = pick([.right, .right, .down, .left])
                description = "split \(window.panes.firstIndex { $0 === pane }!) \(direction)"
                _ = try window.split(pane, direction)
                let out = before.subtracting(window.tucked())
                #expect(out.isEmpty, "seed \(seed) step \(step): \(description) brought \(out.count) strips out\n\(window.log.joined(separator: "\n"))\n=> \(window.summary)")
            case 6:
                // Close, then undo it: the row comes back as it was.
                guard window.panes.count > 2 else { continue }
                let pane = rng.next() % 2 == 0 ? window.focused : pick(window.panes)
                let tree = window.tree, focused = window.focused, saved = window.state.saved
                description = "close+undo \(window.panes.firstIndex { $0 === pane }!)"
                window.close(pane)
                // What `replaceSurfaceTree`'s undo does.
                let old = PaneLayout.rows(window.tree.root)
                window.tree = tree
                window.state.rowsDidChange(from: old, to: PaneLayout.rows(tree.root))
                window.state.restore(saved)
                window.layout()
                window.focus(focused)
                #expect(window.tucked() == before,
                        "seed \(seed) step \(step): \(description) did not bring the row back\n\(window.log.joined(separator: "\n"))\n=> \(window.summary)")
            case 7:
                // Swap two panes of one row (a rearrange drop on the center).
                let rows = rowsBefore.filter { $0.allSatisfy { $0.count == 1 } && $0.count > 1 }
                guard !rows.isEmpty else { continue }
                let row = pick(rows)
                let i = Int(rng.next() % UInt64(row.count))
                let j = (i + 1 + Int(rng.next() % UInt64(row.count - 1))) % row.count
                guard let a = window.panes.first(where: { $0.id == row[i][0] }),
                      let b = window.panes.first(where: { $0.id == row[j][0] }),
                      let na = window.tree.root?.node(view: a), let nb = window.tree.root?.node(view: b)
                else { continue }
                description = "swap \(window.name(a.id)) \(window.name(b.id))"
                window.state.swap(a.id, b.id)
                let old = PaneLayout.rows(window.tree.root)
                window.tree = try window.tree.swapping(na, with: nb)
                window.state.rowsDidChange(from: old, to: PaneLayout.rows(window.tree.root))
                // The pane dragged (a) takes focus where it lands on show;
                // dropped into a strip's place it stays a strip, and the
                // pane that came out of the strip takes focus instead.
                let minimized = window.tucked()
                if !minimized.contains(a.id) { window.focus(a) }
                else if !minimized.contains(b.id) { window.focus(b) }
                #expect(window.tucked().count == before.count,
                        "seed \(seed) step \(step): \(description) changed how many are minimized\n\(window.log.joined(separator: "\n"))\n=> \(window.summary)")
            default:
                window.width = pick([700, 900, 1100, 1300, 1600, 2000])
                description = "resize to \(window.width)"
                window.layout()
            }
            window.log.append(description + "  =>  " + window.summary)

            let after = window.layout()
            let focusedLeaf = after.leaves[window.focused.id]
            #expect(focusedLeaf?.isTucked == false,
                    "seed \(seed) step \(step): the focused pane is a strip after \(description)\n\(window.log.joined(separator: "\n"))")
            if focusedLeaf?.isTucked == true { return }
            // Every resizer lives in a gutter: on no pane on show, and on
            // no strip.
            let shown = after.leaves.values.compactMap { $0.isTucked ? $0.tab : $0.frame }
            let gutters = after.dividers.map(\.gutter) + after.stackHandles.map(\.gutter)
            for gutter in gutters {
                #expect(!gutter.isEmpty, "seed \(seed) step \(step): an empty gutter after \(description)")
                for rect in shown {
                    let overlap = gutter.intersection(rect)
                    #expect(overlap.isNull || overlap.width < 0.01 || overlap.height < 0.01,
                            "seed \(seed) step \(step): a grip \(gutter) overlaps \(rect) after \(description)")
                }
            }
            // Nothing on show is under its minimum width (there is always
            // room for at least one card: 700pt).
            for (id, leaf) in after.leaves where !leaf.isTucked {
                #expect(leaf.frame.width >= PaneLayout.Metrics.minimumPaneSize.width - 1, "seed \(seed) step \(step): \(id) is \(leaf.frame.width) wide after \(description)")
            }
        }
    }
}

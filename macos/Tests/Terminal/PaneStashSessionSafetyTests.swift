import AppKit
import Testing
@testable import Ghostty

/// Stashing a pane must not end its session.
///
/// `SessionCloseIntentPolicy` reads "a leaf left the tree" as "the user closed
/// it" and marks the agent session CLOSE-on-free, which kills the process when
/// the view is finally freed. A stash takes a pane out of the LAYOUT, so a
/// stash that also took it out of the TREE would terminate the user's Claude
/// Code session and look as if it had worked until the pane came back empty.
///
/// The design (`docs/design/pane-sidebar.md`) answers this structurally — a
/// stashed pane never leaves the tree — and these tests hold it to that by
/// feeding real `SplitTree` stash transitions through the same policy the
/// controller runs (`BaseTerminalController.surfaceTreeDidChange`), over the
/// same leaf list it uses (`SessionCloseIntentPolicy.leaves(of:)`).
struct PaneStashSessionSafetyTests {
    /// The controller's tree-change bookkeeping, minus AppKit: which leaves
    /// would be marked CLOSE-on-free by going from `from` to `to`.
    private func closed(from: SplitTree<MockView>, to: SplitTree<MockView>) -> [MockView] {
        SessionCloseIntentPolicy.plan(
            from: SessionCloseIntentPolicy.leaves(of: from),
            to: SessionCloseIntentPolicy.leaves(of: to),
            sessionID: { $0.id.uuidString }
        ).close
    }

    private func threePanes() throws -> (SplitTree<MockView>, MockView, MockView, MockView) {
        let a = MockView(), b = MockView(), c = MockView()
        var tree = SplitTree<MockView>(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .right)
        tree = try tree.inserting(view: c, at: b, direction: .down)
        return (tree, a, b, c)
    }

    @Test func stashingAPaneMarksNothingClosed() throws {
        let (tree, _, b, _) = try threePanes()
        let stashed = try tree.stashing(b)
        #expect(closed(from: tree, to: stashed).isEmpty)
        #expect(stashed.isStashed(b))
    }

    @Test func restoringAPaneMarksNothingClosed() throws {
        let (tree, _, b, _) = try threePanes()
        let stashed = try tree.stashing(b)
        let restored = stashed.restoring(b)
        #expect(closed(from: stashed, to: restored).isEmpty)
        #expect(!restored.isStashed(b))
    }

    @Test func stashingEverythingButOneMarksNothingClosed() throws {
        let (tree, a, b, c) = try threePanes()
        let one = try tree.stashing(b).stashing(c)
        #expect(closed(from: tree, to: one).isEmpty)
        #expect(one.visibleLeaves.map(\.id) == [a.id])
    }

    @Test func reorderingTheStashMarksNothingClosed() throws {
        let (tree, _, b, c) = try threePanes()
        let stashed = try tree.stashing(b).stashing(c)
        let reordered = try stashed.stashing(b, at: 0)
        #expect(closed(from: stashed, to: reordered).isEmpty)
        #expect(reordered.stashed == [b.id, c.id])
    }

    @Test func restoringAtADropTargetMarksNothingClosed() throws {
        // A drag out of the sidebar is "un-stash, then move within the tree" —
        // both of which keep the pane in it.
        let (tree, a, b, _) = try threePanes()
        let stashed = try tree.stashing(b)
        guard let node = stashed.root?.node(view: b) else {
            Issue.record("stashed pane left the tree"); return
        }
        let moved = try stashed.restoring(b).removing(node)
            .inserting(view: b, at: a, direction: .left)
        #expect(closed(from: stashed, to: moved).isEmpty)
    }

    @Test func layoutOperationsOnTheVisibleTreeKeepTheStash() throws {
        let (tree, _, b, _) = try threePanes()
        let stashed = try tree.stashing(b)
        let equalized = stashed.applyingToVisible { $0.equalized() }
        #expect(closed(from: stashed, to: equalized).isEmpty)
        #expect(equalized.isStashed(b))
    }

    // MARK: - The test must be able to fail

    @Test func closingAStashedPaneStillMarksItClosed() throws {
        // Without this, a policy that marked nothing at all would pass every
        // test above. A real close of a stashed pane IS a close.
        let (tree, _, b, _) = try threePanes()
        let stashed = try tree.stashing(b)
        guard let node = stashed.root?.node(view: b) else {
            Issue.record("stashed pane left the tree"); return
        }
        let after = stashed.removing(node)
        #expect(closed(from: stashed, to: after).map(\.id) == [b.id])
        #expect(after.stashed.isEmpty, "a closed pane leaves the stash too")
    }

    @Test func aStashThatRemovedTheLeafWouldHaveKilledIt() {
        // The hazard, stated: if stashing had been implemented as removal,
        // this is what the controller would have done to the session.
        let a = MockView(), b = MockView()
        let tree = (try? SplitTree<MockView>(view: a).inserting(view: b, at: a, direction: .right))!
        guard let node = tree.root?.node(view: b) else { Issue.record("no node"); return }
        #expect(closed(from: tree, to: tree.removing(node)).map(\.id) == [b.id])
    }
}

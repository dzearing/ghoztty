import AppKit
import Testing
@testable import Ghostty

/// The tree mutations a pane drag performs.
///
/// Every one of them has to preserve LEAF IDENTITY — the rebuilt tree must
/// hold the very same view objects — because that identity is the terminal's
/// process and scrollback and the viewer's rendered page. A mutation that
/// produced equal-but-new leaves would silently restart everything on screen.
struct SplitTreeRearrangeTests {
    private func leaves(_ tree: SplitTree<MockView>) -> [MockView] {
        tree.root?.leaves() ?? []
    }

    /// `a | b` — a horizontal split.
    private func pair() -> (tree: SplitTree<MockView>, a: MockView, b: MockView) {
        let a = MockView()
        let b = MockView()
        let tree = SplitTree<MockView>(
            root: .split(.init(direction: .horizontal, ratio: 0.5,
                               left: .leaf(view: a), right: .leaf(view: b))),
            zoomed: nil)
        return (tree, a, b)
    }

    // MARK: - Top-level insert

    @Test func topLevelLeftPutsTheViewFirstInAHorizontalSplit() {
        let (tree, a, b) = pair()
        let c = MockView()
        let result = tree.insertingAtTopLevel(view: c, side: .left)

        guard case .split(let split) = result.root else {
            Issue.record("expected a split at the root"); return
        }
        #expect(split.direction == .horizontal)
        #expect(split.ratio == 0.5)
        #expect(split.left == .leaf(view: c))
        // The whole previous tree is the other child, untouched.
        #expect(leaves(result) == [c, a, b])
    }

    @Test func topLevelRightPutsTheViewLast() {
        let (tree, a, b) = pair()
        let c = MockView()
        let result = tree.insertingAtTopLevel(view: c, side: .right)

        guard case .split(let split) = result.root else {
            Issue.record("expected a split at the root"); return
        }
        #expect(split.direction == .horizontal)
        #expect(split.right == .leaf(view: c))
        #expect(leaves(result) == [a, b, c])
    }

    @Test func topLevelUpIsAVerticalSplitWithTheViewOnTheLeftBranch() {
        // `.vertical` lays children out top/bottom, so the TOP is `left`.
        // Getting this backwards would put every "drop at the top of the
        // window" pane at the bottom.
        let (tree, a, b) = pair()
        let c = MockView()
        let result = tree.insertingAtTopLevel(view: c, side: .up)

        guard case .split(let split) = result.root else {
            Issue.record("expected a split at the root"); return
        }
        #expect(split.direction == .vertical)
        #expect(split.left == .leaf(view: c))
        #expect(leaves(result) == [c, a, b])
    }

    @Test func topLevelDownIsAVerticalSplitWithTheViewOnTheRightBranch() {
        let (tree, _, _) = pair()
        let c = MockView()
        let result = tree.insertingAtTopLevel(view: c, side: .down)

        guard case .split(let split) = result.root else {
            Issue.record("expected a split at the root"); return
        }
        #expect(split.direction == .vertical)
        #expect(split.right == .leaf(view: c))
    }

    @Test func topLevelSpansTheWholeTreeUnlikeAPaneSplit() {
        // The distinction the window-edge drop exists for: splitting pane `b`
        // nests inside the existing split, while a top-level insert wraps it.
        let (tree, a, b) = pair()
        let c = MockView()

        let nested = try? tree.inserting(view: c, at: b, direction: .right)
        let topLevel = tree.insertingAtTopLevel(view: c, side: .right)

        guard case .split(let nestedSplit) = nested?.root,
              case .split(let topSplit) = topLevel.root else {
            Issue.record("expected splits"); return
        }
        // Nested: the root's right child is itself a split holding b and c.
        #expect(nestedSplit.left == .leaf(view: a))
        if case .split = nestedSplit.right {} else {
            Issue.record("expected the pane split to nest")
        }
        // Top level: the root's right child is c itself.
        #expect(topSplit.right == .leaf(view: c))
    }

    @Test func topLevelIntoAnEmptyTreeJustBecomesTheView() {
        let c = MockView()
        let result = SplitTree<MockView>().insertingAtTopLevel(view: c, side: .left)
        #expect(result.root == .leaf(view: c))
    }

    @Test func topLevelClearsZoom() {
        // A zoom hides most of the window; reshaping its top level makes that
        // hidden state meaningless.
        let (tree, a, b) = pair()
        let zoomed = SplitTree<MockView>(root: tree.root, zoomed: .leaf(view: a))
        let result = zoomed.insertingAtTopLevel(view: MockView(), side: .up)
        #expect(result.zoomed == nil)
        #expect(leaves(result).contains(b))
    }

    @Test func topLevelPreservesLeafIdentity() {
        let (tree, a, b) = pair()
        let result = tree.insertingAtTopLevel(view: MockView(), side: .down)
        let survivors = leaves(result)
        #expect(survivors.contains { $0 === a })
        #expect(survivors.contains { $0 === b })
    }

    // MARK: - The move: remove then re-insert

    @Test func movingAPaneWithinATreeKeepsEveryLeafObject() {
        // Three panes; move the first to the other side of the third.
        let a = MockView(), b = MockView(), c = MockView()
        let tree = SplitTree<MockView>(
            root: .split(.init(direction: .horizontal, ratio: 0.5,
                               left: .leaf(view: a),
                               right: .split(.init(direction: .horizontal, ratio: 0.5,
                                                   left: .leaf(view: b),
                                                   right: .leaf(view: c))))),
            zoomed: nil)

        guard let nodeA = tree.root?.node(view: a) else {
            Issue.record("could not find a"); return
        }
        let without = tree.removing(nodeA)
        #expect(leaves(without) == [b, c])

        guard let moved = try? without.inserting(view: a, at: c, direction: .right) else {
            Issue.record("insert failed"); return
        }
        let survivors = leaves(moved)
        #expect(survivors.count == 3)
        #expect(survivors[0] === b)
        #expect(survivors[1] === c)
        #expect(survivors[2] === a)
    }

    @Test func removingCollapsesTheParentSplitIntoTheSibling() {
        // The panes left behind reclaim the space rather than keeping a gap.
        let (tree, a, b) = pair()
        guard let nodeA = tree.root?.node(view: a) else {
            Issue.record("could not find a"); return
        }
        let result = tree.removing(nodeA)
        #expect(result.root == .leaf(view: b))
        #expect(!result.isSplit)
    }

    @Test func swappingExchangesTwoLeavesInPlaceKeepingBothObjects() {
        let (tree, a, b) = pair()
        guard let nodeA = tree.root?.node(view: a),
              let nodeB = tree.root?.node(view: b),
              let swapped = try? tree.swapping(nodeA, with: nodeB) else {
            Issue.record("swap failed"); return
        }
        let survivors = leaves(swapped)
        #expect(survivors[0] === b)
        #expect(survivors[1] === a)
    }

    @Test func replacingIsHowACrossWindowSwapMovesOneEnd() {
        // Each side of a cross-window swap is a `replacing` on its own tree,
        // since the two panes live in different trees and `swapping` cannot
        // span them.
        let (tree, a, b) = pair()
        let stranger = MockView()
        guard let nodeA = tree.root?.node(view: a),
              let result = try? tree.replacing(node: nodeA, with: .leaf(view: stranger)) else {
            Issue.record("replace failed"); return
        }
        #expect(leaves(result) == [stranger, b])
    }
}

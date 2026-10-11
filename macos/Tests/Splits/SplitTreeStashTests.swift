import AppKit
import Foundation
import Testing
@testable import Ghostty

/// The stash model: `SplitTree.stashed`, the visible projection, and the
/// invariants `SplitTree+Stash.swift` promises.
struct SplitTreeStashTests {
    /// a | (b / c)
    private func threePanes() throws -> (SplitTree<MockView>, MockView, MockView, MockView) {
        let a = MockView(), b = MockView(), c = MockView()
        var tree = SplitTree<MockView>(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .right, ratio: 0.3)
        tree = try tree.inserting(view: c, at: b, direction: .down, ratio: 0.25)
        return (tree, a, b, c)
    }

    private func ids(_ views: [MockView]) -> [UUID] { views.map(\.id) }

    // MARK: Projection

    @Test func stashedLeavesStayInTheTree() throws {
        let (tree, a, b, c) = try threePanes()
        let stashed = try tree.stashing(b)
        #expect(ids(Array(stashed)) == ids([a, b, c]), "the roster is every leaf")
        #expect(ids(stashed.visibleLeaves) == ids([a, c]))
        #expect(ids(stashed.stashedViews) == ids([b]))
    }

    @Test func pruningCollapsesTheParentSplit() throws {
        let (tree, a, b, c) = try threePanes()
        let visible = try tree.stashing(b).visibleTree
        // a | c: the vertical split around b collapsed into c.
        guard case .split(let root) = visible.root else { Issue.record("expected a split"); return }
        #expect(root.direction == .horizontal)
        #expect(root.ratio == 0.3, "the surviving split keeps its ratio")
        #expect(root.left == .leaf(view: a))
        #expect(root.right == .leaf(view: c))
        #expect(visible.stashed.isEmpty)
    }

    @Test func noStashMeansTheVisibleTreeIsTheTree() throws {
        let (tree, _, _, _) = try threePanes()
        #expect(tree.visibleTree.root == tree.root)
    }

    @Test func everythingButOneIsVerticalTabs() throws {
        let (tree, a, b, c) = try threePanes()
        let one = try tree.stashing(b).stashing(c)
        #expect(one.visibleTree.root == .leaf(view: a))
        #expect(!one.isVisiblySplit)
        #expect(one.isSplit, "the full tree is still split")
    }

    // MARK: Restore

    @Test func restoringReturnsTheExactSlotAndRatio() throws {
        let (tree, _, b, _) = try threePanes()
        let restored = try tree.stashing(b).restoring(b)
        #expect(restored.root == tree.root, "ratios and directions survive a round trip")
        #expect(restored.stashed.isEmpty)
    }

    @Test func restoringAnUnstashedPaneIsANoOp() throws {
        let (tree, a, _, _) = try threePanes()
        #expect(tree.restoring(a).root == tree.root)
    }

    // MARK: Order

    @Test func newStashesGoOnTop() throws {
        let (tree, _, b, c) = try threePanes()
        let stashed = try tree.stashing(b).stashing(c)
        #expect(stashed.stashed == [c.id, b.id])
    }

    @Test func stashingAtAnIndexInserts() throws {
        let (tree, _, b, c) = try threePanes()
        let stashed = try tree.stashing(b).stashing(c, at: 1)
        #expect(stashed.stashed == [b.id, c.id])
    }

    @Test func stashingAStashedPaneMovesIt() throws {
        let (tree, _, b, c) = try threePanes()
        let moved = try tree.stashing(b).stashing(c).stashing(b, at: 0)
        #expect(moved.stashed == [b.id, c.id])
    }

    // MARK: Invariant 1: something is always on screen

    @Test func theLastVisiblePaneCannotBeStashed() throws {
        let (tree, a, b, c) = try threePanes()
        let one = try tree.stashing(b).stashing(c)
        #expect(throws: SplitTreeStashError.lastVisiblePane) {
            try one.stashing(a)
        }
    }

    @Test func aLonePaneCannotBeStashed() {
        let a = MockView()
        #expect(throws: SplitTreeStashError.lastVisiblePane) {
            try SplitTree<MockView>(view: a).stashing(a)
        }
    }

    @Test func closingTheLastVisiblePaneRestoresTheTopOfTheStash() throws {
        let (tree, a, b, c) = try threePanes()
        let one = try tree.stashing(b).stashing(c)   // stash: [c, b]
        guard let node = one.root?.node(view: a) else { Issue.record("no node"); return }
        let after = one.removing(node)
        #expect(ids(after.visibleLeaves) == ids([c]))
        #expect(after.stashed == [b.id])
    }

    @Test func aViewNotInTheTreeCannotBeStashed() throws {
        let (tree, _, _, _) = try threePanes()
        #expect(throws: SplitTreeStashError.notInTree) {
            try tree.stashing(MockView())
        }
    }

    // MARK: Invariant 2: the stash names only leaves of the tree

    @Test func structuralEditsCarryTheStash() throws {
        let (tree, a, b, _) = try threePanes()
        let d = MockView()
        let stashed = try tree.stashing(b)
        #expect(try stashed.inserting(view: d, at: a, direction: .down).stashed == [b.id])
        #expect(stashed.insertingAtTopLevel(view: d, side: .left).stashed == [b.id])
        #expect(stashed.equalized().stashed == [b.id])
        #expect(stashed.settingZoomed(nil).stashed == [b.id])
    }

    @Test func withStashDropsIdsThatAreNotLeaves() throws {
        let (tree, _, b, _) = try threePanes()
        let restored = tree.withStash([UUID(), b.id])
        #expect(restored.stashed == [b.id])
    }

    @Test func withStashNeverStashesEverything() throws {
        let (tree, a, b, c) = try threePanes()
        let restored = tree.withStash([a.id, b.id, c.id])
        #expect(restored.visibleLeaves.count == 1)
    }

    // MARK: Invariant 3: zoom

    @Test func stashingTheZoomedPaneUnzooms() throws {
        let (tree, _, b, _) = try threePanes()
        let zoomed = tree.settingZoomed(tree.root?.node(view: b))
        #expect(try zoomed.stashing(b).zoomed == nil)
    }

    @Test func stashingAnotherPaneKeepsTheZoom() throws {
        let (tree, a, b, _) = try threePanes()
        let zoomed = tree.settingZoomed(tree.root?.node(view: a))
        #expect(try zoomed.stashing(b).zoomed == .leaf(view: a))
    }

    // MARK: Layout on the visible tree

    @Test func aRatioChangeOnTheVisibleTreeLiftsToTheFullTree() throws {
        let (tree, a, b, c) = try threePanes()
        let stashed = try tree.stashing(b)
        let moved = stashed.applyingToVisible { visible in
            guard case .split(let s) = visible.root else { return visible }
            return SplitTree(
                root: .split(.init(direction: s.direction, ratio: 0.6, left: s.left, right: s.right)),
                zoomed: nil, stashed: [])
        }
        guard case .split(let root) = moved.root else { Issue.record("expected a split"); return }
        #expect(root.ratio == 0.6, "the visible split's ratio landed on its full-tree split")
        // The collapsed split (b over c) kept ITS ratio, so b comes back the
        // size it left.
        guard case .split(let inner) = root.right else { Issue.record("expected b/c split"); return }
        #expect(inner.ratio == 0.25)
        #expect(inner.left == .leaf(view: b) && inner.right == .leaf(view: c))
        #expect(root.left == .leaf(view: a))
        #expect(moved.stashed == [b.id])
    }

    @Test func aShapeChangingTransformIsIgnored() throws {
        let (tree, a, b, _) = try threePanes()
        let stashed = try tree.stashing(b)
        let result = stashed.applyingToVisible { _ in SplitTree(view: a) }
        #expect(result.root == stashed.root)
    }

    @Test func dividerMovesOnTheVisibleTreeLift() throws {
        let (tree, _, b, _) = try threePanes()
        let stashed = try tree.stashing(b)
        guard let visibleRoot = stashed.visibleTree.root else { Issue.record("empty"); return }
        let moved = try stashed.applyingToVisible {
            try $0.movingDivider(of: visibleRoot, to: 50, in: 100)
        }
        guard case .split(let root) = moved.root else { Issue.record("expected a split"); return }
        #expect(abs(root.ratio - 0.5) < 0.0001)
    }

    @Test func focusNavigationOnTheVisibleTreeSkipsStashedPanes() throws {
        let (tree, a, b, c) = try threePanes()
        let visible = try tree.stashing(b).visibleTree
        guard let node = visible.root?.node(view: a) else { Issue.record("no node"); return }
        #expect(visible.focusTarget(for: .next, from: node) === c)
    }

    // MARK: Exchange

    @Test func exchangingSwapsAStashedPaneWithAVisibleOne() throws {
        let (tree, a, b, c) = try threePanes()
        let stashed = try tree.stashing(b)        // visible: a | c
        let swapped = try stashed.exchanging(stashed: b, with: a)
        #expect(ids(swapped.visibleLeaves) == ids([b, c]), "b took a's slot")
        #expect(swapped.stashed == [a.id], "a took b's place in the stash")
    }

    // MARK: Codable

    @Test func theStashSurvivesEncoding() throws {
        let (tree, _, b, c) = try threePanes()
        let stashed = try tree.stashing(b).stashing(c, at: 1)
        let data = try JSONEncoder().encode(stashed)
        let decoded = try JSONDecoder().decode(SplitTree<MockView>.self, from: data)
        #expect(decoded.stashed == [b.id, c.id])
    }

    @Test func anOlderEncodingDecodesWithNothingStashed() throws {
        let (tree, _, _, _) = try threePanes()
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitTree<MockView>.self, from: data)
        #expect(decoded.stashed.isEmpty)
    }

    // MARK: Identity

    @Test func structuralIdentityChangesWithTheStash() throws {
        let (tree, _, b, _) = try threePanes()
        #expect(tree.structuralIdentity != (try tree.stashing(b)).structuralIdentity)
    }
}

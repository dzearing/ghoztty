import AppKit
import Testing
@testable import Ghostty

/// `PaneLayout`: pane minimums, and the stack a row becomes when its panes
/// can't fit side by side — which panes are on show, where every card sits,
/// and that bringing a card forward moves cards without resizing any.
struct PaneLayoutTests {
    /// Elevated-style numbers: a 10pt gap, 36pt peeks, 300×200 panes.
    private let metrics = PaneLayout.Metrics(
        gap: 10, peek: 36, minimumPaneSize: CGSize(width: 300, height: 200))

    /// `a | b | c | d`, equal columns.
    private func row(_ count: Int = 4) throws -> (SplitTree<MockView>.Node, [MockView]) {
        let views = (0..<count).map { _ in MockView() }
        var tree = SplitTree<MockView>(view: views[0])
        for i in 1..<count {
            tree = try tree.inserting(view: views[i], at: views[i - 1], direction: .right)
        }
        return (try #require(tree.root?.equalize()), views)
    }

    private func layout(
        _ node: SplitTree<MockView>.Node,
        width: CGFloat,
        height: CGFloat = 600,
        focus: [MockView] = [],
        pins: [Set<UUID>: PaneLayout.Pin] = [:]
    ) -> PaneLayout.Result<MockView> {
        let ranks = Dictionary(uniqueKeysWithValues: focus.enumerated().map { ($1.id, $0) })
        return PaneLayout.compute(
            node, in: CGRect(x: 0, y: 0, width: width, height: height),
            metrics: metrics, rank: { ranks[$0.id] }, pin: { pins[$0] })
    }

    private func key(_ views: [MockView]) -> Set<UUID> { Set(views.map(\.id)) }

    private func frames(_ result: PaneLayout.Result<MockView>, _ views: [MockView]) -> [CGRect] {
        views.map { result.leaves[$0.id]?.frame ?? .null }
    }

    // MARK: - Side by side

    @Test func roomyRowsFollowTheirRatios() throws {
        let (node, views) = try row()
        let result = layout(node, width: 1630)

        #expect(frames(result, views).map(\.width) == [400, 400, 400, 400])
        #expect(frames(result, views).map(\.minX) == [0, 410, 820, 1230])
        #expect(result.stacks.isEmpty)
        #expect(result.leaves.values.allSatisfy { !$0.isTucked && $0.tab == nil })
        #expect(result.dividers.count == 3)
    }

    @Test func aRatioThatWouldSqueezeAPaneIsOverriddenNotStored() throws {
        // a | b with b at 10% of 1000pt: b would be 99pt. It gets its 300.
        let a = MockView(), b = MockView()
        let node = SplitTree<MockView>.Node.split(.init(
            direction: .horizontal, ratio: 0.9, left: .leaf(view: a), right: .leaf(view: b)))
        let result = layout(node, width: 1010)

        #expect(frames(result, [a, b]).map(\.width) == [700, 300])
        // The displayed tree carries the ratio on screen; the input is untouched.
        guard case .split(let shown) = result.displayed else { Issue.record("expected a split"); return }
        #expect(abs(shown.ratio - 705.0 / 1010.0) < 0.0001)
        #expect(result.dividers.first?.position == 705)
    }

    @Test func waterFillPinsOnlyWhatFallsShort() {
        let sizes = PaneLayout.waterFill([100, 450, 450], minimums: [300, 300, 300], available: 1000)
        #expect(sizes == [300, 350, 350])
    }

    @Test func waterFillKeepsProportionsAmongTheRest() {
        let sizes = PaneLayout.waterFill([50, 300, 650], minimums: [300, 0, 0], available: 1000)
        #expect(sizes.map { $0.rounded() } == [300, 221, 479])
    }

    // MARK: - Stacking

    @Test func aRowThatCantFitStacksAndShowsWhatFits() throws {
        // 4 × 300 + gaps = 1230 > 760: a stack. Two cards fit side by side
        // with two slivers (2×36 + 2×300 + 10 ≤ 760); three don't.
        let (node, views) = try row()
        let result = layout(node, width: 760)

        let stack = try #require(result.stacks.first)
        #expect(result.stacks.count == 1)
        #expect(stack.run == 0...1, "nothing focused yet: the first cards show")
        #expect(result.dividers.isEmpty, "a stack has no dividers")
        // Every card is the same width, so moving the run never resizes one.
        #expect(Set(frames(result, views).map(\.width)).count == 1)
        #expect(frames(result, views)[0].width == CGFloat(760 - 72 - 10) / 2)
    }

    @Test func theFocusedPaneIsOnShow() throws {
        let (node, views) = try row()
        let result = layout(node, width: 760, focus: [views[3]])

        #expect(result.stacks.first?.run == 2...3)
        #expect(result.leaves[views[3].id]?.isTucked == false)
        #expect(result.leaves[views[0].id]?.isTucked == true)
    }

    @Test func theRunGrowsTowardThePaneFocusedMoreRecently() throws {
        let (node, views) = try row()

        // c focused, b before it: b|c, not c|d.
        #expect(layout(node, width: 760, focus: [views[2], views[1]]).stacks.first?.run == 1...2)
        // c focused, d before it: c|d.
        #expect(layout(node, width: 760, focus: [views[2], views[3]]).stacks.first?.run == 2...3)
    }

    @Test func clickingTheLeftmostCardSlidesTheOthersRight() throws {
        // The user's example: d is on show; the leftmost card is clicked.
        let (node, views) = try row()
        let before = layout(node, width: 600, focus: [views[3]])
        let after = layout(node, width: 600, focus: [views[0], views[3]])

        // 600pt fits one 300pt card plus three slivers: a single-card run.
        #expect(before.stacks.first?.run == 3...3)
        #expect(after.stacks.first?.run == 0...0)

        let w: CGFloat = 600 - 3 * 36
        // Before: a, b, c tucked on the left; d in front.
        #expect(frames(before, views).map(\.minX) == [0, 36, 72, 108])
        // After: a pops into place at the left; b, c, d slide right to be
        // tucked at the far end, each showing its leading edge.
        #expect(frames(after, views).map(\.minX) == [0, w, w + 36, w + 72])
        // Nothing changed size.
        #expect(frames(before, views).map(\.size) == frames(after, views).map(\.size))
    }

    @Test func cardsKeepTheirOrderWhereverTheRunIs() throws {
        let (node, views) = try row(5)
        for focused in views {
            let result = layout(node, width: 900, focus: [focused])
            let xs = frames(result, views).map(\.minX)
            #expect(xs == xs.sorted(), "left stays left (focus \(views.firstIndex(of: focused)!))")
        }
    }

    @Test func thePaintOrderShowsTheRunAndEveryTab() throws {
        // Panes are painted by elevation. Wherever a higher pane overlaps a
        // lower one, the lower one must be tucked — the run is never
        // covered — and every tab must be uncovered.
        let (node, views) = try row(5)
        for width in [420.0, 600, 900, 1200] {
            for focused in views {
                let result = layout(node, width: width, focus: [focused])
                let order = PaneLayout.paintOrder(views, result.leaves)
                let drawn = order.map { v in
                    let leaf = result.leaves[v.id]!
                    if leaf.isSliver { return leaf.tab! }
                    return leaf.clip.map { leaf.frame.intersection($0) } ?? leaf.frame
                }
                for i in order.indices {
                    for j in order.indices where j > i {
                        let overlap = drawn[i].intersection(drawn[j])
                        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
                        let lower = result.leaves[order[i].id]!
                        #expect(lower.isTucked, "a pane on show is under another at \(width)")
                        if let tab = lower.tab {
                            let covered = tab.intersection(drawn[j])
                            #expect(covered.isNull || covered.width <= 0, "a tab is covered at \(width)")
                        }
                    }
                }
            }
        }
    }

    @Test func cardsSitLowerTheFartherTheyAreFromTheRun() throws {
        // a b [c] d e: the run on top, falling away to either side.
        let (node, views) = try row(5)
        let result = layout(node, width: 600, focus: [views[2]])
        #expect(result.stacks.first?.run == 2...2)
        let order = PaneLayout.paintOrder(views, result.leaves).map { views.firstIndex(of: $0)! }
        #expect(order == [0, 1, 4, 3, 2])
        #expect(result.leaves[views[3].id]?.isSliver == true, "past the run a card is its sliver")
        #expect(result.leaves[views[1].id]?.isSliver == false)
        #expect(result.leaves[views[2].id]?.isSliver == false)
    }

    @Test func tabsAreTheVisibleSlivers() throws {
        let (node, views) = try row()
        let result = layout(node, width: 600, focus: [views[1]])

        #expect(result.leaves[views[1].id]?.tab == nil, "the card on show has no tab")
        #expect(result.leaves[views[0].id]?.tab == CGRect(x: 0, y: 0, width: 36, height: 600))
        let w: CGFloat = 600 - 3 * 36
        #expect(result.leaves[views[2].id]?.tab == CGRect(x: 36 + w, y: 0, width: 36, height: 600))
        #expect(result.leaves[views[3].id]?.tab == CGRect(x: 72 + w, y: 0, width: 36, height: 600))
        #expect(result.leaves[views[3].id]?.tabAxis == .horizontal)
    }

    @Test func cardsPastTheRunAreClippedToTheStack() throws {
        let (node, views) = try row()
        let result = layout(node, width: 600, focus: [views[0]])
        let w: CGFloat = 600 - 3 * 36

        let d = try #require(result.leaves[views[3].id])
        #expect(d.frame.maxX > 600, "d hangs past the stack")
        let clip = try #require(d.clip)
        #expect(clip.maxX == 600, "cut at the stack's far end")
        #expect(clip.minX < d.frame.minX && clip.minY < 0 && clip.maxY > 600,
                "and nowhere else, so its shadow falls on the card behind")
        #expect(d.frame.intersection(clip) == CGRect(x: w + 72, y: 0, width: 600 - (w + 72), height: 600))
        #expect(result.leaves[views[0].id]?.clip == nil)
    }

    @Test func aTooNarrowStackShrinksItsSliversBeforeItsCards() throws {
        let (node, views) = try row()
        // 300 + 3 × 36 = 408 > 380: slivers shrink to whole points of
        // (380 - 300) / 3, and the card keeps the rest.
        let result = layout(node, width: 380, focus: [views[0]])

        #expect(result.leaves[views[1].id]?.tab?.width == 26)
        #expect(frames(result, views)[0].width == CGFloat(380 - 3 * 26))
    }

    @Test func columnsStackToo() throws {
        let a = MockView(), b = MockView(), c = MockView()
        var tree = SplitTree<MockView>(view: a)
        tree = try tree.inserting(view: b, at: a, direction: .down)
        tree = try tree.inserting(view: c, at: b, direction: .down)
        let node = try #require(tree.root?.equalize())
        let result = layout(node, width: 800, height: 400, focus: [c])

        let stack = try #require(result.stacks.first)
        #expect(stack.direction == .vertical)
        #expect(stack.run == 2...2)
        #expect(result.leaves[a.id]?.tabAxis == .vertical)
        #expect(result.leaves[a.id]?.tab?.height == 36)
        #expect(result.leaves[c.id]?.frame.height == CGFloat(400 - 2 * 36))
    }

    // MARK: - Nesting

    @Test func anInnerRowStacksBeforeTheOuterOne() throws {
        // a | (b / (c | d)): at 800pt the outer row can't hold a, c and d side
        // by side, but it can hold a beside a STACKED c|d. That shows more
        // than stacking the whole row would.
        let a = MockView(), b = MockView(), c = MockView(), d = MockView()
        let inner = SplitTree<MockView>.Node.split(.init(
            direction: .horizontal, ratio: 0.5, left: .leaf(view: c), right: .leaf(view: d)))
        let column = SplitTree<MockView>.Node.split(.init(
            direction: .vertical, ratio: 0.5, left: .leaf(view: b), right: inner))
        let node = SplitTree<MockView>.Node.split(.init(
            direction: .horizontal, ratio: 0.5, left: .leaf(view: a), right: column))
        let result = layout(node, width: 800, height: 800, focus: [d])

        #expect(result.stacks.count == 1)
        #expect(result.stacks.first?.items == [[c.id], [d.id]])
        #expect(result.leaves[a.id]?.isTucked == false)
        #expect(result.leaves[b.id]?.isTucked == false)
        #expect(result.leaves[c.id]?.isTucked == true)
        #expect(result.leaves[d.id]?.isTucked == false)
    }

    @Test func aStackedCardCanHoldAWholeColumn() throws {
        // (a / b) | c | d in 700pt: a stack of three, whose first card is a column.
        let a = MockView(), b = MockView(), c = MockView(), d = MockView()
        let column = SplitTree<MockView>.Node.split(.init(
            direction: .vertical, ratio: 0.5, left: .leaf(view: a), right: .leaf(view: b)))
        let node = SplitTree<MockView>.Node.split(.init(
            direction: .horizontal, ratio: 1.0 / 3.0, left: column,
            right: .split(.init(direction: .horizontal, ratio: 0.5, left: .leaf(view: c), right: .leaf(view: d)))))
        let result = layout(node, width: 700, height: 600, focus: [d])

        // Both panes of the tucked column are behind, and each shows its
        // share of the column's sliver.
        #expect(result.leaves[a.id]?.isTucked == true)
        #expect(result.leaves[b.id]?.isTucked == true)
        #expect(result.leaves[a.id]?.tab?.height == result.leaves[a.id]?.frame.height)
        #expect(result.leaves[b.id]?.tab?.minY == result.leaves[b.id]?.frame.minY)
        // The column's own divider is under the card in front of it.
        #expect(result.dividers.isEmpty)
    }

    // MARK: - Visible run

    @Test func visibleRunPrefersTheTrailingSideOnATie() {
        #expect(PaneLayout.visibleRun(ranks: [nil, nil, nil, nil], count: 2) == 0...1)
        #expect(PaneLayout.visibleRun(ranks: [nil, 0, nil, nil], count: 2) == 1...2)
    }

    @Test func visibleRunStopsAtTheEnds() {
        #expect(PaneLayout.visibleRun(ranks: [nil, nil, nil, 0], count: 3) == 1...3)
        #expect(PaneLayout.visibleRun(ranks: [0, nil, nil], count: 5) == 0...2)
    }

    // MARK: - Focus history

    @Test func focusHistoryPutsTheNewestFirstOnce() {
        let a = UUID(), b = UUID()
        #expect(PaneStackState.noting(a, in: [b, a]) == [a, b])
        #expect(PaneStackState.noting(a, in: []) == [a])
    }

    // MARK: - Minimums the divider clamps against

    @Test func theDividerClampFallsBackToStackedMinimumsWhenNeeded() throws {
        // a | (b | c) in 700pt: side by side needs 900; with b|c allowed to
        // stack it needs 300 + 336.
        let a = MockView(), b = MockView(), c = MockView()
        let node = SplitTree<MockView>.Node.split(.init(
            direction: .horizontal, ratio: 0.5, left: .leaf(view: a),
            right: .split(.init(direction: .horizontal, ratio: 0.5, left: .leaf(view: b), right: .leaf(view: c)))))
        let moved = node.movingDivider(to: 600, in: 700)

        guard case .split(let split) = moved else { Issue.record("expected a split"); return }
        // The divider moved, stopping where b|c can still stack.
        #expect(abs(split.ratio - (700.0 - 336.0) / 700.0) < 0.0001)
    }

    // MARK: - Adopting the displayed layout

    @Test func aDragStartsFromTheLayoutOnScreen() throws {
        let a = MockView(), b = MockView()
        let tree = SplitTree<MockView>(
            root: .split(.init(direction: .horizontal, ratio: 0.9, left: .leaf(view: a), right: .leaf(view: b))),
            zoomed: nil, stashed: [])
        let result = layout(try #require(tree.root), width: 1010)
        let adopted = tree.adoptingDisplayedLayout(try #require(result.displayed))

        guard case .split(let split) = adopted.root else { Issue.record("expected a split"); return }
        #expect(abs(split.ratio - 705.0 / 1010.0) < 0.0001)
        #expect(adopted.root?.leaves() == [a, b])
    }

    // MARK: - Collapsing a row by hand

    @Test func aCollapsedRowTucksAPaneEvenWithRoomToSpare() throws {
        // a | b | c fits side by side at 1200; the user tucked c away.
        let (node, views) = try row(3)
        let result = layout(node, width: 1200, pins: [key(views): .init(start: 0, count: 2)])

        let stack = try #require(result.stacks.first)
        #expect(stack.run == 0...1)
        #expect(result.leaves[views[2].id]?.isTucked == true)
        #expect(result.leaves[views[2].id]?.tab?.maxX == 1200, "c is a sliver at the far edge")
        // The two on show share the rest, equally.
        let w = (1200 - 36 - 10) / 2
        #expect(frames(result, views).prefix(2).map(\.width) == [CGFloat(w), CGFloat(w)])
    }

    @Test func dividersKnowTheirRow() throws {
        let (node, views) = try row(3)
        let result = layout(node, width: 1200)
        #expect(result.dividers.map(\.index).sorted() == [1, 2])
        #expect(result.dividers.allSatisfy { $0.row.run == 0...2 && $0.row.key == key(views) })
    }

    @Test func squeezingAPaneTucksTheOutermostOnThatSide() {
        // a divider dragged past c's minimum (trailing), or past a's (leading)
        #expect(PaneLayout.Pin.restacking(0...2, of: 3, .collapse(.trailing)) == .init(start: 0, count: 2))
        #expect(PaneLayout.Pin.restacking(0...2, of: 3, .collapse(.leading)) == .init(start: 1, count: 2))
        // down to one card on show, never none
        #expect(PaneLayout.Pin.restacking(1...1, of: 3, .collapse(.leading)) == .init(start: 1, count: 1))
    }

    @Test func widenedAllTheWayARowIsSideBySideAgain() {
        #expect(PaneLayout.Pin.restacking(0...1, of: 3, .expand(.trailing)) == nil)
        #expect(PaneLayout.Pin.restacking(1...1, of: 4, .expand(.leading)) == .init(start: 0, count: 2))
    }

    @Test func clickingAMinimizedPaneRestoresJustThatOne() {
        // a b on show, c d minimized, room for three: c comes back and d
        // stays minimized.
        let pin = PaneLayout.Pin(start: 0, count: 2)
        #expect(pin.restoring(2, fits: 3, of: 4) == .init(start: 0, count: 3))
        #expect(pin.restoring(1, fits: 3, of: 4) == pin, "a pane on show changes nothing")
        // Room for everything: the row is side by side again.
        #expect(PaneLayout.Pin(start: 0, count: 1).restoring(1, fits: 2, of: 2) == nil)
    }

    @Test func withoutRoomTheFarEdgeMinimizesInstead() {
        // a b on show, no room for a third: c in, a out.
        #expect(PaneLayout.Pin(start: 0, count: 2).restoring(2, fits: 2, of: 4) == .init(start: 1, count: 2))
        // From the other side: a in, c out.
        #expect(PaneLayout.Pin(start: 1, count: 2).restoring(0, fits: 2, of: 4) == .init(start: 0, count: 2))
        // The far one of two minimized, with room for one more: the run
        // reaches it and the one between gives way at the far end.
        #expect(PaneLayout.Pin(start: 0, count: 2).restoring(3, fits: 3, of: 4) == .init(start: 1, count: 3))
    }

    @Test func aPaneLeavingTheRunClosesUpOverItsSlot() {
        // a b [c d] e f: c closes. d takes the run alone, between the same strips.
        let pin = PaneLayout.Pin(start: 2, count: 2)
        #expect(pin.removing([2], of: 6) == .init(start: 2, count: 1))
        #expect(pin.removing([3], of: 6) == .init(start: 2, count: 1))
        // A strip closes: the run keeps its panes, shifted when it was before them.
        #expect(pin.removing([0], of: 6) == .init(start: 1, count: 2))
        #expect(pin.removing([5], of: 6) == .init(start: 2, count: 2))
        // Everything left fits in the run: side by side again.
        #expect(PaneLayout.Pin(start: 0, count: 2).removing([2], of: 3) == nil)
        // A row of one is no row.
        #expect(PaneLayout.Pin(start: 0, count: 1).removing([1], of: 2) == nil)
    }

    @Test func theOnlyPaneOnShowClosingBringsOutItsNeighbourBefore() {
        // a b [c] d e: the pane before it comes on show — where the caret
        // goes after a close — and the rest stay strips.
        #expect(PaneLayout.Pin(start: 2, count: 1).removing([2], of: 5) == .init(start: 1, count: 1))
        // Nothing before it: the one after.
        #expect(PaneLayout.Pin(start: 0, count: 1).removing([0], of: 4) == .init(start: 0, count: 1))
    }

    @Test func aPaneJoiningBesideTheRunComesOnShow() {
        // a b [c] d e: a pane lands beside c, on either side, and the run
        // takes it in; the strips stay strips.
        let pin = PaneLayout.Pin(start: 2, count: 1)
        #expect(pin.adding([3], of: 6) == .init(start: 2, count: 2))
        #expect(pin.adding([2], of: 6) == .init(start: 2, count: 2))
        // Among the strips, it is one of them.
        #expect(pin.adding([0], of: 6) == .init(start: 3, count: 1))
        #expect(pin.adding([5], of: 6) == .init(start: 2, count: 1))
        // Inside a run of two: between them.
        #expect(PaneLayout.Pin(start: 1, count: 2).adding([2], of: 5) == .init(start: 1, count: 3))
    }

    @Test func rowsListEveryChainOutermostFirst() throws {
        // a | (b / (c | d))
        let a = MockView(), b = MockView(), c = MockView(), d = MockView()
        let inner = SplitTree<MockView>.Node.split(.init(
            direction: .horizontal, ratio: 0.5, left: .leaf(view: c), right: .leaf(view: d)))
        let column = SplitTree<MockView>.Node.split(.init(
            direction: .vertical, ratio: 0.5, left: .leaf(view: b), right: inner))
        let node = SplitTree<MockView>.Node.split(.init(
            direction: .horizontal, ratio: 0.5, left: .leaf(view: a), right: column))
        let expected: [[[UUID]]] = [
            [[a.id], [b.id, c.id, d.id]],
            [[b.id], [c.id, d.id]],
            [[c.id], [d.id]],
        ]
        #expect(PaneLayout.rows(node) == expected)
        #expect(PaneLayout.rows(SplitTree<MockView>.Node.leaf(view: a)).isEmpty)
    }

    @Test func aStackKnowsHowManyCardsFit() throws {
        let (node, views) = try row(4)
        let collapsed = layout(node, width: 1400, pins: [key(views): .init(start: 0, count: 2)])
        #expect(collapsed.stacks.first?.fits == 4, "fits side by side")
        let narrow = layout(node, width: 760)
        #expect(narrow.stacks.first?.fits == 2)
    }

    @Test func gripsSitBetweenCardsAndAtAWidenableEdge() throws {
        let (node, views) = try row(3)
        let result = layout(node, width: 1200, pins: [key(views): .init(start: 0, count: 2)])
        let kinds = result.stackHandles.map(\.kind)
        #expect(kinds.contains(.between(slot: 0)), "between a and b")
        #expect(kinds.contains(.expand(.trailing)), "where the run meets c")
        #expect(!kinds.contains(.expand(.leading)), "nothing is tucked before the run")

        // Too narrow for a third card: nothing to widen into.
        let narrow = layout(node, width: 700, pins: [key(views): .init(start: 0, count: 2)])
        #expect(!narrow.stackHandles.contains { if case .expand = $0.kind { true } else { false } })
    }

    @Test func theRunsSlotsAreTheUsersToSize() throws {
        // a b on show at 30/70, c tucked: c is the size of the slot it would
        // come forward into (the last), and nothing is under its minimum.
        let (node, views) = try row(3)
        let pins = [key(views): PaneLayout.Pin(start: 0, count: 2)]
        let result = PaneLayout.compute(
            node, in: CGRect(x: 0, y: 0, width: 1200, height: 600), metrics: metrics,
            rank: { _ in nil }, pin: { pins[$0] }, shares: { $0 == key(views) ? [0.3, 0.7] : nil })
        let widths = frames(result, views).map(\.width)
        let run: CGFloat = 1200 - 36 - 10
        #expect(widths[0] == (run * 0.3).rounded(.down))
        #expect(widths[0] + widths[1] == run)
        #expect(widths[2] == widths[1])
        #expect(result.stackHandles.first { $0.kind == .between(slot: 0) }?.row.sizes == Array(widths.prefix(2)))
    }

    @Test func aCollapseKeepsTheSizesOfThePanesStillOnShow() {
        let third: CGFloat = 1.0 / 3
        let collapsed: [CGFloat]? = PaneStackState.shares([300, 600, 300], .collapse(.trailing))
        #expect(collapsed == [third, 2 * third])
        let expanded: [CGFloat]? = PaneStackState.shares([400, 400], .expand(.leading))
        #expect(expanded == [third, third, third])
    }

    @Test func aWindowTooSmallForTheCollapsedRunShowsItsFocusedPart() throws {
        let (node, views) = try row(4)
        let result = layout(node, width: 500, focus: [views[2]], pins: [key(views): .init(start: 1, count: 2)])
        #expect(result.stacks.first?.run == 2...2)
    }
}

struct PaneStackStateTests {
    @Test func collapsingARowLeavesTheRowsNestedInItAlone() {
        // A | (B over C): the column is one item of the row.
        let state = PaneStackState()
        let a = UUID(), b = UUID(), c = UUID()
        state.restack(.init(items: [[b], [c]], run: 0...1), .collapse(.trailing))
        state.restack(.init(items: [[a], [b, c]], run: 0...1), .collapse(.trailing))
        #expect(state.pin(for: [b, c]) == .init(start: 0, count: 1))
        #expect(state.pin(for: [a, b, c]) == .init(start: 0, count: 1))
    }

    @Test func aSwapKeepsTheRowCollapsed() {
        let state = PaneStackState()
        let a = UUID(), b = UUID(), c = UUID(), elsewhere = UUID()
        state.restack(.init(items: [[a], [b], [c]], run: 0...2), .collapse(.trailing))
        #expect(state.pin(for: [a, b, c]) == .init(start: 0, count: 2))

        // c (tucked) swapped with a pane from another row: that pane is now
        // in this row's place, and the row is still collapsed.
        state.swap(c, elsewhere)
        #expect(state.pin(for: [a, b, elsewhere]) == .init(start: 0, count: 2))
        #expect(state.pin(for: [a, b, c]) == nil)
    }

    @Test func closingAPaneOnShowKeepsTheRowCollapsed() {
        // a b [c d] e f: c closes, and d alone is on show between the strips.
        let state = PaneStackState()
        let ids = (0..<6).map { _ in UUID() }
        let before = ids.map { [$0] }
        state.restack(.init(items: before, run: 1...4, sizes: [1, 1, 1, 1]), .collapse(.leading))
        state.restack(.init(items: before, run: 2...4, sizes: [1, 1, 1]), .collapse(.trailing))
        #expect(state.pin(for: Set(ids)) == .init(start: 2, count: 2))

        let after = before.filter { $0 != [ids[2]] }
        state.rowsDidChange(from: [before], to: [after])
        #expect(state.pin(for: Set(ids).subtracting([ids[2]])) == .init(start: 2, count: 1))
        #expect(state.shares[Set(ids).subtracting([ids[2]])] == nil, "one slot needs no shares")
        // Undoing the close brings back the row as it was.
        state.rowsDidChange(from: [after], to: [before])
        #expect(state.pin(for: Set(ids)) == .init(start: 2, count: 2))
    }

    @Test func closingAMinimizedPaneKeepsTheRunAndTheSizesOfItsPanes() {
        let state = PaneStackState()
        let ids = (0..<5).map { _ in UUID() }
        let before = ids.map { [$0] }
        state.restack(.init(items: before, run: 1...4, sizes: [1, 1, 2, 2]), .collapse(.trailing))
        #expect(state.pin(for: Set(ids)) == .init(start: 1, count: 3))
        let key = Set(ids).subtracting([ids[0]])
        state.rowsDidChange(from: [before], to: [Array(before.dropFirst())])
        #expect(state.pin(for: key) == .init(start: 0, count: 3))
        #expect(state.shares[key] == state.shares[Set(ids)])
    }

    @Test func closingAPaneOnShowKeepsTheOthersSizes() throws {
        let state = PaneStackState()
        let ids = (0..<5).map { _ in UUID() }
        let before = ids.map { [$0] }
        // a [b c d] e, sized 1:1:2.
        state.restack(.init(items: before, run: 0...3, sizes: [1, 1, 1, 2]), .collapse(.leading))
        state.rowsDidChange(from: [before], to: [before.filter { $0 != [ids[2]] }])
        let key = Set(ids).subtracting([ids[2]])
        #expect(state.pin(for: key) == .init(start: 1, count: 2))
        let shares = try #require(state.shares[key])
        let expected: [CGFloat] = [1.0 / 3, 2.0 / 3]
        #expect(shares.count == 2)
        #expect(zip(shares, expected).allSatisfy { abs($0 - $1) < 1e-9 })
    }

    @Test func aPaneLeavingAColumnInsideARowKeepsBothCollapsed() {
        // a | (b / c / d), the row and the column each collapsed; c closes.
        let state = PaneStackState()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        state.restack(.init(items: [[b], [c], [d]], run: 0...2), .collapse(.trailing))
        state.restack(.init(items: [[a], [b, c, d], [e]], run: 0...2), .collapse(.trailing))
        state.rowsDidChange(
            from: [[[a], [b, c, d], [e]], [[b], [c], [d]]],
            to: [[[a], [b, d], [e]], [[b], [d]]])
        #expect(state.pin(for: [a, b, d, e]) == .init(start: 0, count: 2), "the row keeps its run")
        #expect(state.pin(for: [b, d]) == .init(start: 0, count: 1), "the column keeps its strip")
    }

    @Test func aRowThatChangedShapeIsNotGuessedAt() {
        // a | (b / (c | d)): b closes, and c | d joins the outer row. That row
        // is not the one the user collapsed; it lays out afresh.
        let state = PaneStackState()
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        state.restack(.init(items: [[a], [b, c, d]], run: 0...1), .collapse(.trailing))
        state.rowsDidChange(from: [[[a], [b, c, d]], [[b], [c, d]], [[c], [d]]], to: [[[a], [c], [d]]])
        #expect(state.pin(for: [a, c, d]) == nil)
    }

    /// a b [c] d e, collapsed by hand to c alone on show.
    private func collapsedToOne() -> (PaneStackState, [UUID], [[UUID]]) {
        let state = PaneStackState()
        let ids = (0..<5).map { _ in UUID() }
        let items = ids.map { [$0] }
        state.restack(.init(items: items, run: 1...3, sizes: [1, 1, 1]), .collapse(.leading))
        state.restack(.init(items: items, run: 2...3, sizes: [1, 1]), .collapse(.trailing))
        #expect(state.pin(for: Set(ids)) == .init(start: 2, count: 1))
        return (state, ids, items)
    }

    @Test func splittingAPaneOnShowAlongTheRowKeepsTheStrips() {
        // c splits right: a b [c x] d e.
        let (state, ids, before) = collapsedToOne()
        let x = UUID()
        var after = before
        after.insert([x], at: 3)
        state.rowsDidChange(from: [before], to: [after])
        #expect(state.pin(for: Set(ids + [x])) == .init(start: 2, count: 2))
        #expect(state.shares[Set(ids + [x])] == nil, "the run gained a slot")
    }

    @Test func splittingAPaneOnShowAcrossTheRowKeepsTheRow() throws {
        // c splits down: a b [c/x] d e — same items, one of them a column now.
        let state = PaneStackState()
        let ids = (0..<5).map { _ in UUID() }
        let before = ids.map { [$0] }
        state.restack(.init(items: before, run: 1...4, sizes: [1, 1, 1, 2]), .collapse(.leading))
        let x = UUID()
        var after = before
        after[2] = [ids[2], x]
        state.rowsDidChange(from: [before], to: [after, [[ids[2]], [x]]])
        #expect(state.pin(for: Set(ids + [x])) == .init(start: 2, count: 3))
        #expect(state.shares[Set(ids + [x])] == state.shares[Set(ids)], "the same slots keep their sizes")
        #expect(state.pin(for: [ids[2], x]) == nil, "the new column is side by side")
    }

    @Test func addingAPaneAtTheFarEndOfTheRunPutsItOnShow() {
        // Before the run, too: x lands between b and c.
        let (state, ids, before) = collapsedToOne()
        let x = UUID()
        var after = before
        after.insert([x], at: 2)
        state.rowsDidChange(from: [before], to: [after])
        #expect(state.pin(for: Set(ids + [x])) == .init(start: 2, count: 2))
    }

    @Test func aPaneAddedAmongTheStripsIsAStripUntilItIsFocused() {
        // x lands between a and b: a x b [c] d e.
        for focusFirst in [false, true] {
            let (state, ids, before) = collapsedToOne()
            // Room for three on show.
            state.noteItems(before, fits: 3)
            state.noteFocus(ids[2])
            let x = UUID()
            var after = before
            after.insert([x], at: 1)
            let key = Set(ids + [x])
            if focusFirst {
                // The focus lands before the tree change is seen.
                state.noteFocus(x)
                state.rowsDidChange(from: [before], to: [after])
            } else {
                state.rowsDidChange(from: [before], to: [after])
                #expect(state.pin(for: key) == .init(start: 3, count: 1), "a strip, unfocused")
                state.noteFocus(x)
            }
            // Focused, it comes out like any strip: the run grows to it.
            #expect(state.pin(for: key) == .init(start: 1, count: 3), "focusFirst: \(focusFirst)")
        }
    }

    @Test func aFocusLandingBeforeOrAfterTheSplitGivesTheSameRow() {
        var pins: [PaneLayout.Pin?] = []
        for focusFirst in [false, true] {
            let (state, ids, before) = collapsedToOne()
            state.noteFocus(ids[2])
            let x = UUID()
            var after = before
            after.insert([x], at: 3)
            if focusFirst { state.noteFocus(x) }
            state.rowsDidChange(from: [before], to: [after])
            // The window has room for one card on show.
            state.noteItems(after, fits: 1)
            if !focusFirst { state.noteFocus(x) }
            pins.append(state.pin(for: Set(ids + [x])))
        }
        #expect(pins[0] == pins[1])
        #expect(pins[0] == .init(start: 2, count: 2))
    }

    @Test func undoingACloseKeepsTheRowsOwnCollapse() {
        // An add whose row already has a collapse of its own (an undone close,
        // a restored stash) brings that back rather than deriving one.
        let (state, ids, before) = collapsedToOne()
        let after = before.filter { $0 != [ids[0]] }
        state.rowsDidChange(from: [before], to: [after])
        #expect(state.pin(for: Set(ids.dropFirst())) == .init(start: 1, count: 1))
        state.rowsDidChange(from: [after], to: [before])
        #expect(state.pin(for: Set(ids)) == .init(start: 2, count: 1))
    }

    @Test func aPaneMovedWithinTheRowKeepsTheSamePanesOnShow() {
        // a b [c] d e: a dropped beside e — b [c] d e a, still c on show.
        let (state, ids, before) = collapsedToOne()
        let after = Array(before.dropFirst()) + [before[0]]
        state.rowsDidChange(from: [before], to: [after])
        #expect(state.pin(for: Set(ids)) == .init(start: 1, count: 1))
    }

    @Test func aSwapWithinTheRowSwapsWhatIsOnShow() {
        // a b [c] d e: e dropped on c trades places with it, and is on show.
        let (state, ids, before) = collapsedToOne()
        state.swap(ids[2], ids[4])
        var after = before
        after.swapAt(2, 4)
        state.rowsDidChange(from: [before], to: [after])
        #expect(state.pin(for: Set(ids)) == .init(start: 2, count: 1))
    }

    @Test func aRowGainingANewColumnIsNotGuessedAt() {
        // a | (b / c) collapsed; a splits down. The new column a / x is not a
        // row anyone collapsed.
        let state = PaneStackState()
        let a = UUID(), b = UUID(), c = UUID(), x = UUID()
        state.restack(.init(items: [[a], [b, c]], run: 0...1), .collapse(.trailing))
        state.rowsDidChange(
            from: [[[a], [b, c]], [[b], [c]]],
            to: [[[a, x], [b, c]], [[a], [x]], [[b], [c]]])
        #expect(state.pin(for: [a, x, b, c]) == .init(start: 0, count: 1))
        #expect(state.pin(for: [a, x]) == nil)
    }

    @Test func focusingAMinimizedPaneWithNoRoomSlidesTheRunToIt() {
        let state = PaneStackState()
        let ids = (0..<4).map { _ in UUID() }
        state.restack(.init(items: ids.map { [$0] }, run: 0...2), .collapse(.trailing))
        state.noteItems(ids.map { [$0] }, fits: 2)
        state.noteFocus(ids[3])
        #expect(state.pin(for: Set(ids)) == .init(start: 2, count: 2), "b minimizes on the far edge")
    }

    @Test func focusingAMinimizedPaneWithRoomRestoresTheSplit() {
        // Two panes, one minimized: clicking it brings the split back.
        let state = PaneStackState()
        let ids = (0..<2).map { _ in UUID() }
        state.restack(.init(items: ids.map { [$0] }, run: 0...1, sizes: [600, 600]), .collapse(.trailing))
        #expect(state.pin(for: Set(ids)) == .init(start: 0, count: 1))
        state.noteItems(ids.map { [$0] }, fits: 2)
        state.noteFocus(ids[1])
        #expect(state.pin(for: Set(ids)) == nil)
        #expect(state.shares[Set(ids)] == nil)
    }
}

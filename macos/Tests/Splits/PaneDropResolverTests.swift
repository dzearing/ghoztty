import Foundation
import Testing
@testable import Ghostty

/// All rects here are SCREEN coordinates: y grows UPWARD, so a pane's top
/// edge is `maxY` and "insert above" means proximity to it. Getting this
/// backwards is the easiest mistake in the whole feature, so the tests state
/// it in their arithmetic rather than trusting a comment.
struct PaneDropResolverTests {
    // Two identities to name windows with. The TOKENS are stored, not just
    // the refs: `PaneDropWindowRef` holds an `ObjectIdentifier` and does not
    // retain, so a temporary `NSObject()` would deallocate and the next
    // allocation could reuse its address — making windowA == windowB.
    private let tokenA = NSObject()
    private let tokenB = NSObject()
    private var windowA: PaneDropWindowRef { PaneDropWindowRef(tokenA) }
    private var windowB: PaneDropWindowRef { PaneDropWindowRef(tokenB) }

    private let paneOne = UUID()
    private let paneTwo = UUID()
    private let dragged = UUID()

    /// A 1000x800 window whose whole content is one pane, plus a second pane
    /// id that is never on screen (so `dragged` can be a stranger).
    private func singlePaneCandidate(
        window: PaneDropWindowRef? = nil,
        zOrder: Int = 0,
        origin: CGPoint = .zero,
        size: CGSize = CGSize(width: 1000, height: 800),
        paneID: UUID? = nil
    ) -> PaneDropCandidate {
        let rect = CGRect(origin: origin, size: size)
        return PaneDropCandidate(
            window: window ?? windowA,
            zOrder: zOrder,
            contentRect: rect,
            paneRects: [(id: paneID ?? paneOne, rect: rect)])
    }

    // MARK: - Pane zones

    @Test func centerIsSwap() {
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 500, y: 400),
            candidates: [singlePaneCandidate()],
            dragged: dragged)
        #expect(target == .swap(window: windowA, pane: paneOne))
    }

    @Test func upperAreaSplitsAbove() {
        // y = 700 of 800 is high on the screen, i.e. near the pane's TOP.
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 500, y: 700),
            candidates: [singlePaneCandidate()],
            dragged: dragged)
        #expect(target == .split(window: windowA, pane: paneOne, direction: .up))
    }

    @Test func lowerAreaSplitsBelow() {
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 500, y: 100),
            candidates: [singlePaneCandidate()],
            dragged: dragged)
        #expect(target == .split(window: windowA, pane: paneOne, direction: .down))
    }

    @Test func leftAreaSplitsLeft() {
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 200, y: 400),
            candidates: [singlePaneCandidate()],
            dragged: dragged)
        #expect(target == .split(window: windowA, pane: paneOne, direction: .left))
    }

    @Test func rightAreaSplitsRight() {
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 800, y: 400),
            candidates: [singlePaneCandidate()],
            dragged: dragged)
        #expect(target == .split(window: windowA, pane: paneOne, direction: .right))
    }

    @Test func paneZonesDivideOnTheDiagonalsNotInPoints() {
        // A wide, short pane. In POINT distance almost everything is nearest
        // the top or bottom; on the diagonals this point is clearly "left".
        let rect = CGRect(x: 0, y: 0, width: 2000, height: 200)
        let zone = PaneDropResolver.paneZone(at: CGPoint(x: 60, y: 100), in: rect)
        #expect(zone == .edge(.left))
    }

    @Test func exactCornerBreaksHorizontalFirst() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(PaneDropResolver.paneZone(at: CGPoint(x: 0, y: 100), in: rect) == .edge(.left))
        #expect(PaneDropResolver.paneZone(at: CGPoint(x: 100, y: 100), in: rect) == .edge(.right))
        #expect(PaneDropResolver.paneZone(at: CGPoint(x: 0, y: 0), in: rect) == .edge(.left))
    }

    // MARK: - The swap rectangle

    @Test func swapRectIsAFractionOfALargePane() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let swap = PaneDropResolver.swapRect(in: rect)
        #expect(swap.width == 340)
        #expect(swap.height == 272)
        #expect(swap.midX == rect.midX)
        #expect(swap.midY == rect.midY)
    }

    @Test func swapRectIsFlooredSoNarrowPanesStayHittable() {
        // 34% of 200 is 68, but 34% of 100 would be 34 — under the floor.
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let swap = PaneDropResolver.swapRect(in: rect)
        #expect(swap.width == 68)
        #expect(swap.height == PaneDropResolver.swapMinimum)
    }

    @Test func swapRectCapBeatsTheFloorOnATinyPane() {
        // The floor would be wider than the pane. The cap has to win, or the
        // swap zone would swallow every edge zone the pane has.
        let rect = CGRect(x: 0, y: 0, width: 50, height: 50)
        let swap = PaneDropResolver.swapRect(in: rect)
        #expect(swap.width == 30) // 60% of 50
        #expect(swap.height == 30)
        #expect(rect.contains(swap))
    }

    @Test func aTinyPaneStillHasEdgeZones() {
        let rect = CGRect(x: 0, y: 0, width: 50, height: 50)
        #expect(PaneDropResolver.paneZone(at: CGPoint(x: 2, y: 25), in: rect) == .edge(.left))
        #expect(PaneDropResolver.paneZone(at: CGPoint(x: 25, y: 25), in: rect) == .center)
    }

    // MARK: - The window edge band

    @Test func windowEdgeBeatsThePaneUnderIt() {
        // 10pt from the window's left edge. The pane fills the window, so
        // without the band this would be a plain left split.
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 10, y: 400),
            candidates: [singlePaneCandidate()],
            dragged: dragged)
        #expect(target == .topLevel(window: windowA, side: .left))
    }

    @Test func eachWindowEdgeInsertsOnItsOwnSide() {
        let candidates = [singlePaneCandidate()]
        func side(_ point: CGPoint) -> PaneDropTarget? {
            PaneDropResolver.resolve(screenPoint: point, candidates: candidates, dragged: dragged)
        }
        #expect(side(CGPoint(x: 5, y: 400)) == .topLevel(window: windowA, side: .left))
        #expect(side(CGPoint(x: 995, y: 400)) == .topLevel(window: windowA, side: .right))
        #expect(side(CGPoint(x: 500, y: 795)) == .topLevel(window: windowA, side: .up))
        #expect(side(CGPoint(x: 500, y: 5)) == .topLevel(window: windowA, side: .down))
    }

    @Test func justInsideTheBandIsThePanesOwnZone() {
        // 40pt in, past the 28pt band: back to the pane's left triangle.
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 40, y: 400),
            candidates: [singlePaneCandidate()],
            dragged: dragged)
        #expect(target == .split(window: windowA, pane: paneOne, direction: .left))
    }

    @Test func bandUsesPointDistanceNotFractions() {
        // 30pt from the left of a very short window, but only 10pt from its
        // bottom. In fractions "left" looks nearer; in points bottom is, and
        // points is what a 28pt band means.
        let rect = CGRect(x: 0, y: 0, width: 2000, height: 400)
        let side = PaneDropResolver.edgeBandSide(for: CGPoint(x: 30, y: 10), in: rect)
        #expect(side == .down)
    }

    @Test func bandCornerBreaksHorizontalFirst() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(PaneDropResolver.edgeBandSide(for: CGPoint(x: 10, y: 10), in: rect) == .left)
        #expect(PaneDropResolver.edgeBandSide(for: CGPoint(x: 990, y: 790), in: rect) == .right)
    }

    @Test func bandIsSuppressedOnATinyWindow() {
        // Under 112pt the band would tile the whole window and no pane zone
        // would ever be reachable.
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(PaneDropResolver.edgeBandSide(for: CGPoint(x: 2, y: 50), in: rect) == nil)
    }

    @Test func bandDoesNotApplyOutsideTheContentRect() {
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(PaneDropResolver.edgeBandSide(for: CGPoint(x: -5, y: 400), in: rect) == nil)
    }

    // MARK: - The tab bar

    private func tabbedCandidate(
        window: PaneDropWindowRef? = nil,
        zOrder: Int = 0
    ) -> PaneDropCandidate {
        PaneDropCandidate(
            window: window ?? windowA,
            zOrder: zOrder,
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
            paneRects: [(id: paneOne, rect: CGRect(x: 0, y: 0, width: 1000, height: 800))],
            tabBarRect: CGRect(x: 0, y: 800, width: 1000, height: 30),
            tabButtonRects: [
                CGRect(x: 0, y: 800, width: 200, height: 30),
                CGRect(x: 200, y: 800, width: 200, height: 30),
                CGRect(x: 400, y: 800, width: 200, height: 30),
            ])
    }

    @Test func droppingOnATabButtonMakesANewTabAtThatIndex() {
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 250, y: 815),
            candidates: [tabbedCandidate()],
            dragged: dragged)
        #expect(target == .newTab(window: windowA, index: 1))
    }

    @Test func droppingOnTabBarBackgroundAppends() {
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 800, y: 815),
            candidates: [tabbedCandidate()],
            dragged: dragged)
        #expect(target == .newTab(window: windowA, index: 3))
    }

    @Test func tabBarOutranksTheContentBeneathIt() {
        // A candidate whose contentRect wrongly overlaps its own tab bar must
        // still resolve to the bar: chrome is not a pane.
        let candidate = PaneDropCandidate(
            window: windowA,
            zOrder: 0,
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 830),
            paneRects: [(id: paneOne, rect: CGRect(x: 0, y: 0, width: 1000, height: 830))],
            tabBarRect: CGRect(x: 0, y: 800, width: 1000, height: 30),
            tabButtonRects: [CGRect(x: 0, y: 800, width: 200, height: 30)])
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 100, y: 815),
            candidates: [candidate],
            dragged: dragged)
        #expect(target == .newTab(window: windowA, index: 0))
    }

    @Test func hoveredTabNamesOnlyRealTabs() {
        let candidates = [tabbedCandidate()]
        let onButton = PaneDropResolver.hoveredTab(
            screenPoint: CGPoint(x: 450, y: 815), candidates: candidates)
        #expect(onButton?.window == windowA)
        #expect(onButton?.index == 2)

        // The bar's background is not a tab, so nothing to dwell into.
        let onBackground = PaneDropResolver.hoveredTab(
            screenPoint: CGPoint(x: 800, y: 815), candidates: candidates)
        #expect(onBackground == nil)
    }

    @Test func hoveredTabIsNilOverContent() {
        let hovered = PaneDropResolver.hoveredTab(
            screenPoint: CGPoint(x: 500, y: 400), candidates: [tabbedCandidate()])
        #expect(hovered == nil)
    }

    // MARK: - Several windows

    @Test func overlappingWindowsResolveFrontmostFirst() {
        let back = singlePaneCandidate(
            window: windowA, zOrder: 1,
            origin: .zero, size: CGSize(width: 1000, height: 800), paneID: paneOne)
        let front = singlePaneCandidate(
            window: windowB, zOrder: 0,
            origin: .zero, size: CGSize(width: 1000, height: 800), paneID: paneTwo)

        // Candidates deliberately supplied back-first: the resolver sorts.
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 500, y: 400),
            candidates: [back, front],
            dragged: dragged)
        #expect(target == .swap(window: windowB, pane: paneTwo))
    }

    @Test func aPointInTheSecondWindowResolvesThere() {
        let first = singlePaneCandidate(
            window: windowA, zOrder: 0,
            origin: .zero, size: CGSize(width: 500, height: 500), paneID: paneOne)
        let second = singlePaneCandidate(
            window: windowB, zOrder: 1,
            origin: CGPoint(x: 1000, y: 0), size: CGSize(width: 500, height: 500), paneID: paneTwo)

        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 1250, y: 250),
            candidates: [first, second],
            dragged: dragged)
        #expect(target == .swap(window: windowB, pane: paneTwo))
    }

    // MARK: - Nothing, and self

    @Test func overNoWindowMakesANewOne() {
        let point = CGPoint(x: 5000, y: 5000)
        let target = PaneDropResolver.resolve(
            screenPoint: point,
            candidates: [singlePaneCandidate()],
            dragged: dragged)
        #expect(target == .newWindow(at: point))
    }

    @Test func noCandidatesAtAllMakesANewWindow() {
        let point = CGPoint(x: 100, y: 100)
        #expect(PaneDropResolver.resolve(
            screenPoint: point, candidates: [], dragged: dragged) == .newWindow(at: point))
    }

    @Test func droppingAPaneOnItselfDoesNothing() {
        let candidate = singlePaneCandidate(paneID: dragged)
        // Center (would be a swap with itself) and an edge (a no-op split).
        #expect(PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 500, y: 400),
            candidates: [candidate], dragged: dragged) == nil)
        #expect(PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 200, y: 400),
            candidates: [candidate], dragged: dragged) == nil)
    }

    @Test func theWindowEdgeStillWorksWhileDraggingTheOnlyPane() {
        // Self-drop is rejected for the PANE's zones, but a top-level insert
        // is a real reshape even when the dragged pane is the one underneath.
        let candidate = singlePaneCandidate(paneID: dragged)
        #expect(PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 5, y: 400),
            candidates: [candidate], dragged: dragged)
            == .topLevel(window: windowA, side: .left))
    }

    @Test func aPointBetweenPanesIsNoTarget() {
        // A 4pt divider gap down the middle: inside the window, on no pane.
        let candidate = PaneDropCandidate(
            window: windowA,
            zOrder: 0,
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
            paneRects: [
                (id: paneOne, rect: CGRect(x: 0, y: 0, width: 498, height: 800)),
                (id: paneTwo, rect: CGRect(x: 502, y: 0, width: 498, height: 800)),
            ])
        #expect(PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 500, y: 400),
            candidates: [candidate], dragged: dragged) == nil)
    }

    // MARK: - Target introspection

    @Test func everyTargetKnowsItsWindowExceptANewOne() {
        #expect(PaneDropTarget.swap(window: windowA, pane: paneOne).window == windowA)
        #expect(PaneDropTarget.newTab(window: windowB, index: 2).window == windowB)
        #expect(PaneDropTarget.newWindow(at: .zero).window == nil)
    }

    // MARK: - A strip's targets

    /// A collapsed row across a 1000x800 window at the origin: strips a and b
    /// on the left, c and d on show, strip e on the right — 10pt gutters,
    /// 36pt strips. b is the strip being dragged.
    private struct Row {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        var items: [(rect: CGRect, panes: Set<UUID>)] {
            [(CGRect(x: 0, y: 0, width: 36, height: 800), [a]),
             (CGRect(x: 46, y: 0, width: 36, height: 800), [b]),
             (CGRect(x: 92, y: 0, width: 400, height: 800), [c]),
             (CGRect(x: 502, y: 0, width: 452, height: 800), [d]),
             (CGRect(x: 964, y: 0, width: 36, height: 800), [e])]
        }
    }

    private let screen = CGRect(x: -500, y: -300, width: 2560, height: 1440)

    private func blade(_ row: Row) -> PaneBladeDrag {
        PaneBladeDrag(
            window: windowA,
            slots: PaneBladeDrag.slots(items: row.items, direction: .horizontal, dragged: row.b),
            screens: [screen])
    }

    private func rowCandidate(_ row: Row) -> PaneDropCandidate {
        PaneDropCandidate(
            window: windowA, zOrder: 0, contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
            paneRects: row.items.map { (id: $0.panes.first!, rect: $0.rect) })
    }

    @Test func aStripHasASlotBetweenEveryTwoOfItsRowsItemsButItsOwn() {
        let row = Row()
        let slots = PaneBladeDrag.slots(items: row.items, direction: .horizontal, dragged: row.b)
        // Before a; [between a and c is where b already is]; c|d; d|e; after e.
        #expect(slots.map(\.beside) == [[row.a], [row.c], [row.d], [row.e]])
        #expect(slots.map(\.side) == [.left, .right, .right, .right])
        // The c|d slot's caret runs down the middle of their gutter.
        #expect(slots[1].caret.midX == 497)
        #expect(slots[1].caret.height == 800)
    }

    @Test func aStripDroppedInAGutterOfItsRowMovesThere() {
        let row = Row()
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 497, y: 400), candidates: [rowCandidate(row)], dragged: row.b, blade: blade(row))
        guard case .reorder(let window, let beside, let side, _) = target else {
            Issue.record("expected a reorder, got \(String(describing: target))")
            return
        }
        #expect(window == windowA && beside == [row.c] && side == .right)
        // A slot reaches a little way into the cards either side of it.
        let near = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 480, y: 400), candidates: [rowCandidate(row)], dragged: row.b, blade: blade(row))
        #expect(near.map { if case .reorder = $0 { true } else { false } } == true)
    }

    @Test func aStripOverAPaneHasNoTargetThere() {
        // No quadrant, no swap: the middle of a card on show means nothing.
        let row = Row()
        #expect(PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 290, y: 400), candidates: [rowCandidate(row)],
            dragged: row.b, blade: blade(row)) == nil)
    }

    @Test func aStripAtTheWindowsEdgeInsertsAtTheTopLevel() {
        let row = Row()
        #expect(PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 290, y: 790), candidates: [rowCandidate(row)],
            dragged: row.b, blade: blade(row)) == .topLevel(window: windowA, side: .up))
    }

    @Test func aStripAtTheScreensEdgeTilesThatHalf() {
        let row = Row()
        let at = { (p: CGPoint) in
            PaneDropResolver.resolve(screenPoint: p, candidates: [rowCandidate(row)], dragged: row.b, blade: blade(row))
        }
        #expect(at(CGPoint(x: -495, y: 500)) == .tile(frame: CGRect(x: -500, y: -300, width: 1280, height: 1440)))
        #expect(at(CGPoint(x: 2055, y: 500)) == .tile(frame: CGRect(x: 780, y: -300, width: 1280, height: 1440)))
        #expect(at(CGPoint(x: 300, y: 1135)) == .tile(frame: CGRect(x: -500, y: 420, width: 2560, height: 720)))
        // Off any edge and off every window: nothing (not a new window).
        #expect(at(CGPoint(x: 1500, y: 500)) == nil)
    }

    @Test func aStripOverAnotherWindowHasOnlyItsEdges() {
        let row = Row()
        let other = PaneDropCandidate(
            window: windowB, zOrder: 0, contentRect: CGRect(x: 1200, y: 0, width: 600, height: 800),
            paneRects: [(id: paneOne, rect: CGRect(x: 1200, y: 0, width: 600, height: 800))])
        let candidates = [rowCandidate(row), other]
        #expect(PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 1500, y: 400), candidates: candidates, dragged: row.b, blade: blade(row)) == nil)
        #expect(PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 1790, y: 400), candidates: candidates, dragged: row.b,
            blade: blade(row)) == .topLevel(window: windowB, side: .right))
    }

    @Test func aColumnsSlotsRunTopToBottom() {
        // Screen coordinates run up: the column's first item is the top one.
        let top = UUID(), middle = UUID(), bottom = UUID()
        let items: [(rect: CGRect, panes: Set<UUID>)] = [
            (CGRect(x: 0, y: 764, width: 800, height: 36), [top]),
            (CGRect(x: 0, y: 310, width: 800, height: 444), [middle]),
            (CGRect(x: 0, y: 0, width: 800, height: 300), [bottom])]
        let slots = PaneBladeDrag.slots(items: items, direction: .vertical, dragged: top)
        #expect(slots.map(\.beside) == [[middle], [bottom]])
        #expect(slots.map(\.side) == [.down, .down])
        #expect(slots[0].caret.midY == 305, "in the gutter between middle and bottom")
    }

    @Test func aStripOfAColumnInARowLeavesItsColumn() {
        // b is one pane of the column [b, x]: the slots name the column by
        // what is left of it.
        let a = UUID(), b = UUID(), x = UUID(), c = UUID()
        let items: [(rect: CGRect, panes: Set<UUID>)] = [
            (CGRect(x: 0, y: 0, width: 36, height: 800), [a]),
            (CGRect(x: 46, y: 0, width: 36, height: 800), [b, x]),
            (CGRect(x: 92, y: 0, width: 900, height: 800), [c])]
        let slots = PaneBladeDrag.slots(items: items, direction: .horizontal, dragged: b)
        #expect(slots.map(\.beside) == [[a], [a], [x], [c]])
    }

    @Test func aStripOnTheSidebarStashes() {
        let row = Row()
        let withSidebar = PaneDropCandidate(
            window: windowA, zOrder: 0, contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
            paneRects: row.items.map { (id: $0.panes.first!, rect: $0.rect) },
            sidebar: .init(rect: CGRect(x: -240, y: 0, width: 240, height: 800)))
        #expect(PaneDropResolver.resolve(
            screenPoint: CGPoint(x: -100, y: 400), candidates: [withSidebar],
            dragged: row.b, blade: blade(row)) == .stash(window: windowA, index: 0))
    }
}

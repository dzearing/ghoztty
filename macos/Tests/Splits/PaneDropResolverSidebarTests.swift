import AppKit
import Foundation
import Testing
@testable import Ghostty

/// The pane sidebar as a drop target: one resolver, a new target, no
/// parallel path (`docs/design/pane-sidebar.md` → Drop resolution).
struct PaneDropResolverSidebarTests {
    // Hold the window tokens: `PaneDropWindowRef` does not retain, and a
    // temporary would let two "different" windows compare equal.
    private let windowToken = NSObject()
    private let otherToken = NSObject()

    private var window: PaneDropWindowRef { PaneDropWindowRef(windowToken) }
    private var other: PaneDropWindowRef { PaneDropWindowRef(otherToken) }

    private let paneA = UUID()
    private let stashedA = UUID()
    private let stashedB = UUID()

    /// A 1000×600 window at the origin: a 240pt sidebar on the left, the
    /// grid (one pane) beside it. Screen coordinates grow UPWARD.
    private func candidate(
        sidebar: PaneDropCandidate.Sidebar?,
        zOrder: Int = 0
    ) -> PaneDropCandidate {
        PaneDropCandidate(
            window: window,
            zOrder: zOrder,
            contentRect: CGRect(x: 240, y: 0, width: 760, height: 600),
            paneRects: [(id: paneA, rect: CGRect(x: 240, y: 0, width: 760, height: 600))],
            sidebar: sidebar)
    }

    private var sidebar: PaneDropCandidate.Sidebar {
        .init(
            rect: CGRect(x: 0, y: 0, width: 240, height: 600),
            // Two stashed rows near the bottom of the list: B above A.
            stashRows: [
                (id: stashedB, rect: CGRect(x: 0, y: 300, width: 240, height: 30)),
                (id: stashedA, rect: CGRect(x: 0, y: 270, width: 240, height: 30)),
            ])
    }

    @Test func aPointOnTheSidebarStashes() {
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 100, y: 100),
            candidates: [candidate(sidebar: sidebar)],
            dragged: paneA)
        #expect(target == .stash(window: window, index: 2), "below both stashed rows: the bottom")
    }

    @Test func theIndexIsTheGapNearestThePointer() {
        let between = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 100, y: 300),   // under B's middle, above A's
            candidates: [candidate(sidebar: sidebar)],
            dragged: paneA)
        #expect(between == .stash(window: window, index: 1))
    }

    @Test func theGridSectionMeansTheTopOfTheStash() {
        let top = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 100, y: 550),
            candidates: [candidate(sidebar: sidebar)],
            dragged: paneA)
        #expect(top == .stash(window: window, index: 0))
    }

    @Test func theDraggedRowDoesNotCountTowardTheIndex() {
        // Reordering: dragging B below A lands at index 1, not 2.
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 100, y: 100),
            candidates: [candidate(sidebar: sidebar)],
            dragged: stashedB)
        #expect(target == .stash(window: window, index: 1))
    }

    @Test func aHiddenSidebarIsNotATarget() {
        // Without a sidebar, the same point is outside the content rect:
        // released over nothing → a new window, exactly as before.
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 100, y: 100),
            candidates: [candidate(sidebar: nil)],
            dragged: paneA)
        #expect(target == .newWindow(at: CGPoint(x: 100, y: 100)))
    }

    @Test func aSidebarOpenOverTheGridBeatsThePaneUnderIt() {
        // The hover-open card floats over the grid's left edge — and over the
        // window-edge band — so the sidebar must win there.
        let floating = PaneDropCandidate.Sidebar(rect: CGRect(x: 240, y: 0, width: 240, height: 600))
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 250, y: 300),
            candidates: [candidate(sidebar: floating)],
            dragged: UUID())
        #expect(target == .stash(window: window, index: 0))
    }

    @Test func theTabBarStillOutranksTheSidebar() {
        let withTabs = PaneDropCandidate(
            window: window,
            zOrder: 0,
            contentRect: CGRect(x: 240, y: 0, width: 760, height: 600),
            paneRects: [(id: paneA, rect: CGRect(x: 240, y: 0, width: 760, height: 600))],
            tabBarRect: CGRect(x: 0, y: 600, width: 1000, height: 28),
            tabButtonRects: [CGRect(x: 0, y: 600, width: 200, height: 28)],
            sidebar: .init(rect: CGRect(x: 0, y: 0, width: 240, height: 628)))
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 100, y: 610),
            candidates: [withTabs],
            dragged: paneA)
        #expect(target == .newTab(window: window, index: 0))
    }

    @Test func anotherWindowsGroupMeansSendItThere() {
        let allWindows = PaneDropCandidate.Sidebar(
            rect: CGRect(x: 0, y: 0, width: 240, height: 600),
            windowGroups: [(window: other, rect: CGRect(x: 0, y: 0, width: 240, height: 120))])
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 100, y: 50),
            candidates: [candidate(sidebar: allWindows)],
            dragged: paneA)
        #expect(target == .joinWindow(window: other))
        #expect(target?.window == other)
    }

    @Test func thisWindowsOwnGroupStashesInstead() {
        let ownGroup = PaneDropCandidate.Sidebar(
            rect: CGRect(x: 0, y: 0, width: 240, height: 600),
            windowGroups: [(window: window, rect: CGRect(x: 0, y: 0, width: 240, height: 600))])
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 100, y: 50),
            candidates: [candidate(sidebar: ownGroup)],
            dragged: paneA)
        #expect(target == .stash(window: window, index: 0))
    }

    @Test func overlappingWindowsResolveByZOrder() {
        // A front window's sidebar covers the back window's grid.
        let backToken = NSObject()
        let back = PaneDropCandidate(
            window: PaneDropWindowRef(backToken),
            zOrder: 1,
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
            paneRects: [(id: UUID(), rect: CGRect(x: 0, y: 0, width: 1000, height: 600))])
        let target = PaneDropResolver.resolve(
            screenPoint: CGPoint(x: 100, y: 300),
            candidates: [back, candidate(sidebar: sidebar, zOrder: 0)],
            dragged: paneA)
        #expect(target?.window == window)
        _ = backToken
    }

    // MARK: Coordinator policy

    @MainActor
    @Test func stashingIsAlwaysAllowedAndJoiningYourOwnWindowIsNot() {
        #expect(PaneMoveCoordinator.allows(.stash(window: window, index: 0),
                                           sourcePaneCount: 1, targetIsSourceWindow: true))
        #expect(PaneMoveCoordinator.allows(.joinWindow(window: other),
                                           sourcePaneCount: 1, targetIsSourceWindow: false))
        #expect(!PaneMoveCoordinator.allows(.joinWindow(window: window),
                                            sourcePaneCount: 3, targetIsSourceWindow: true))
    }
}

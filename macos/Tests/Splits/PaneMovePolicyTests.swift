import Foundation
import Testing
@testable import Ghostty

/// `PaneMoveCoordinator.allows` — which drops are refused outright.
///
/// The regression this suite exists for: popping a pane out to its own window
/// and then dragging it BACK did nothing. The popped-out window holds one
/// pane, and an earlier blanket "a drag never closes a window" guard refused
/// every move out of a single-pane window — so the drop resolved correctly and
/// was then silently thrown away.
@MainActor
struct PaneMovePolicyTests {
    // The TOKENS are stored, not just the refs: `PaneDropWindowRef` wraps an
    // `ObjectIdentifier` without retaining, so temporaries would deallocate
    // and could share an address — collapsing two windows into one.
    private let sourceToken = NSObject()
    private let otherToken = NSObject()
    private var sourceWindow: PaneDropWindowRef { PaneDropWindowRef(sourceToken) }
    private var otherWindow: PaneDropWindowRef { PaneDropWindowRef(otherToken) }
    private let somePane = UUID()

    private func allows(
        _ target: PaneDropTarget,
        panes: Int,
        intoSource: Bool
    ) -> Bool {
        PaneMoveCoordinator.allows(
            target, sourcePaneCount: panes, targetIsSourceWindow: intoSource)
    }

    // MARK: - The regression

    @Test func aLonePaneCanBeDraggedBackIntoAnotherWindow() {
        // Pop out, change your mind, drag it back. Every way of landing in an
        // existing window has to work from a one-pane window.
        #expect(allows(.split(window: otherWindow, pane: somePane, direction: .right),
                       panes: 1, intoSource: false))
        #expect(allows(.swap(window: otherWindow, pane: somePane),
                       panes: 1, intoSource: false))
        #expect(allows(.topLevel(window: otherWindow, side: .left),
                       panes: 1, intoSource: false))
        #expect(allows(.newTab(window: otherWindow, index: 0),
                       panes: 1, intoSource: false))
    }

    @Test func joiningAnExistingWindowIsAlwaysAllowed() {
        for panes in [1, 2, 7] {
            #expect(allows(.split(window: otherWindow, pane: somePane, direction: .up),
                           panes: panes, intoSource: false))
            #expect(allows(.topLevel(window: otherWindow, side: .down),
                           panes: panes, intoSource: false))
        }
    }

    // MARK: - What is still refused

    @Test func aLonePaneCannotDetachIntoANewWindow() {
        // The window would close and another open to hold the same pane:
        // churn, no change. This is upstream's long-standing tear-off guard.
        #expect(!allows(.newWindow(at: .zero), panes: 1, intoSource: false))
    }

    @Test func aPaneFromASplitWindowCanDetachIntoANewWindow() {
        #expect(allows(.newWindow(at: CGPoint(x: 100, y: 100)), panes: 2, intoSource: false))
    }

    @Test func aLonePaneCannotMakeANewTabBesideItsOwnWindow() {
        // Same churn: the source empties and closes as its replacement opens.
        #expect(!allows(.newTab(window: sourceWindow, index: 0), panes: 1, intoSource: true))
    }

    @Test func aLonePaneCanMakeANewTabBesideADifferentWindow() {
        // Joining someone else's tab group is a real relocation.
        #expect(allows(.newTab(window: otherWindow, index: 2), panes: 1, intoSource: false))
    }

    @Test func aSplitWindowCanAlwaysMakeANewTabOfItsOwn() {
        #expect(allows(.newTab(window: sourceWindow, index: 1), panes: 3, intoSource: true))
    }

    // MARK: - Same-window rearranging is never blocked

    @Test func rearrangingWithinAWindowIsAlwaysAllowed() {
        #expect(allows(.split(window: sourceWindow, pane: somePane, direction: .left),
                       panes: 2, intoSource: true))
        #expect(allows(.swap(window: sourceWindow, pane: somePane),
                       panes: 2, intoSource: true))
        #expect(allows(.topLevel(window: sourceWindow, side: .up),
                       panes: 2, intoSource: true))
    }

    // MARK: - The rule, stated once

    @Test func onlyBrandNewSurfacesAreEverRefused() {
        // Every refusal in the whole policy is a lone pane being asked to
        // create a surface to hold itself. Nothing else is ever refused.
        let allTargets: [PaneDropTarget] = [
            .split(window: otherWindow, pane: somePane, direction: .right),
            .swap(window: otherWindow, pane: somePane),
            .topLevel(window: otherWindow, side: .left),
            .newTab(window: otherWindow, index: 0),
            .newTab(window: sourceWindow, index: 0),
            .newWindow(at: .zero),
        ]
        let refused = allTargets.filter { target in
            !allows(target, panes: 1, intoSource: target.window == sourceWindow)
        }
        #expect(refused.count == 2)
        #expect(refused.contains(.newWindow(at: .zero)))
        #expect(refused.contains(.newTab(window: sourceWindow, index: 0)))
    }
}

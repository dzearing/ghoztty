import Foundation
import Testing
@testable import Ghostty

/// Why `PaneMoveCoordinator.finishRelocation` exists.
///
/// `SessionCloseIntentPolicy` reads a leaf leaving a tree as "the user closed
/// it" and marks its agent session CLOSE-on-free. That default is right for a
/// close and wrong for a MOVE, and a cross-window move fires the policy twice
/// — once per controller. These tests pin exactly how far ordering gets you
/// (a plain move: all the way; a swap: not at all), which is why the
/// coordinator ends by declaring the relocated panes alive instead of relying
/// on the order.
struct PaneMoveSessionSafetyTests {
    /// A leaf that remembers the last intent applied to it, the way a real
    /// `SurfaceView` remembers `setSessionCloseIntent`.
    private final class Leaf {
        let name: String
        let sessionID: String?
        var closeIntent: Bool = false

        init(_ name: String, session: String? = nil) {
            self.name = name
            self.sessionID = session
        }
    }

    /// Apply one controller's tree change exactly as
    /// `BaseTerminalController.surfaceTreeDidChange` does.
    private func applyTreeChange(from: [Leaf], to: [Leaf]) {
        let plan = SessionCloseIntentPolicy.plan(
            from: from, to: to, sessionID: { $0.sessionID })
        for leaf in plan.keepAlive { leaf.closeIntent = false }
        for leaf in plan.spared { leaf.closeIntent = false }
        for leaf in plan.close { leaf.closeIntent = true }
    }

    /// What `finishRelocation` asserts once the trees have been swapped in.
    private func finishRelocation(of panes: [Leaf]) {
        for pane in panes { pane.closeIntent = false }
    }

    // MARK: - A plain move between two windows

    @Test func sourceFirstThenDestinationLeavesTheMovedPaneAlive() {
        let moved = Leaf("moved", session: "s1")
        let stayA = Leaf("stayA", session: "s2")
        let stayB = Leaf("stayB", session: "s3")

        // Source loses the pane, THEN the destination gains it.
        applyTreeChange(from: [moved, stayA], to: [stayA])
        applyTreeChange(from: [stayB], to: [stayB, moved])

        #expect(moved.closeIntent == false)
        #expect(stayA.closeIntent == false)
        #expect(stayB.closeIntent == false)
    }

    @Test func destinationFirstWouldKillTheMovedPanesSession() {
        // The bug the ordering rule prevents: the source's "it left my tree"
        // lands last and marks a pane that is alive on screen.
        let moved = Leaf("moved", session: "s1")
        let stayA = Leaf("stayA", session: "s2")
        let stayB = Leaf("stayB", session: "s3")

        applyTreeChange(from: [stayB], to: [stayB, moved])
        applyTreeChange(from: [moved, stayA], to: [stayA])

        #expect(moved.closeIntent == true, "this is the hazard, stated")

        // ...and the coordinator's explicit assertion undoes it regardless
        // of which order the controllers were updated in.
        finishRelocation(of: [moved])
        #expect(moved.closeIntent == false)
    }

    // MARK: - A cross-window swap, where NO ordering is safe

    @Test func aCrossWindowSwapStrandsOnePaneWhicheverOrderIsUsed() {
        // Each pane departs one tree and arrives in the other, so whichever
        // controller is updated last, the OTHER one's departing pane keeps
        // its close mark. This is why ordering alone cannot be the fix.
        func runSwap(sourceFirst: Bool) -> (Leaf, Leaf) {
            let paneA = Leaf("A", session: "sA")
            let paneB = Leaf("B", session: "sB")
            let otherInSource = Leaf("X", session: "sX")
            let otherInDest = Leaf("Y", session: "sY")

            let updateSource = { applyTreeChange(from: [paneA, otherInSource], to: [paneB, otherInSource]) }
            let updateDest = { applyTreeChange(from: [paneB, otherInDest], to: [paneA, otherInDest]) }

            if sourceFirst { updateSource(); updateDest() } else { updateDest(); updateSource() }
            return (paneA, paneB)
        }

        let (aSourceFirst, bSourceFirst) = runSwap(sourceFirst: true)
        #expect(aSourceFirst.closeIntent == false)
        #expect(bSourceFirst.closeIntent == true, "B is stranded when the source goes first")

        let (aDestFirst, bDestFirst) = runSwap(sourceFirst: false)
        #expect(aDestFirst.closeIntent == true, "A is stranded when the destination goes first")
        #expect(bDestFirst.closeIntent == false)
    }

    @Test func declaringBothEndsAliveFixesTheSwapInEitherOrder() {
        let paneA = Leaf("A", session: "sA")
        let paneB = Leaf("B", session: "sB")
        let otherInSource = Leaf("X", session: "sX")
        let otherInDest = Leaf("Y", session: "sY")

        applyTreeChange(from: [paneA, otherInSource], to: [paneB, otherInSource])
        applyTreeChange(from: [paneB, otherInDest], to: [paneA, otherInDest])

        // The coordinator knows this was an exchange and says so for BOTH
        // relocated panes — which is what `alsoRelocated` carries.
        finishRelocation(of: [paneA, paneB])

        #expect(paneA.closeIntent == false)
        #expect(paneB.closeIntent == false)
    }

    // MARK: - A real close is still a close

    @Test func closingAPaneStillMarksItRegardlessOfTheMovePath() {
        // The relaxation must not leak into the close path: a pane that
        // genuinely left and went nowhere keeps its CLOSE-on-free intent.
        let closed = Leaf("closed", session: "s1")
        let stays = Leaf("stays", session: "s2")

        applyTreeChange(from: [closed, stays], to: [stays])

        #expect(closed.closeIntent == true)
        #expect(stays.closeIntent == false)
    }

    @Test func aViewerPaneHasNoSessionAndIsNeverSpared() {
        // A viewer has no session id, so it can never be mistaken for a
        // rebuild's re-attached surface.
        let viewer = Leaf("viewer", session: nil)
        let plan = SessionCloseIntentPolicy.plan(
            from: [viewer], to: [], sessionID: { $0.sessionID })
        #expect(plan.spared.isEmpty)
        #expect(plan.close.count == 1)
    }
}

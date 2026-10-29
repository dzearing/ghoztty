import AppKit
import SwiftUI
import Testing
@testable import Ghostty

/// Hover follows where the pointer IS: the exit/enter pair AppKit fires when
/// a re-layout rebuilds tracking areas must not blink the hover off.
@MainActor
struct HoverTrackingViewTests {
    final class Probe: HoverTrackingView {
        var pointer: NSPoint? = NSPoint(x: 10, y: 10)
        override var pointerLocation: NSPoint? { pointer }
    }

    private func event(_ type: NSEvent.EventType) -> NSEvent {
        NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    }

    @Test func aRebuiltTrackingAreaDoesNotBlinkTheHoverOff() {
        let view = Probe(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        var reports: [Bool] = []
        view.onHoverChanged = { reports.append($0) }

        view.mouseEntered(with: event(.mouseEntered))
        // The spurious pair a re-layout produces, pointer still inside.
        view.mouseExited(with: event(.mouseExited))
        view.mouseEntered(with: event(.mouseEntered))
        view.syncHover()
        #expect(reports == [true])

        // The row slides out from under a still pointer: that IS a change.
        view.pointer = NSPoint(x: 10, y: 40)
        view.syncHover()
        #expect(reports == [true, false])
    }

    @Test func aSidebarDragHoldsEveryHoverUntilItLands() {
        let passed = Probe(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        passed.pointer = NSPoint(x: 10, y: 40)
        var reports: [Bool] = []
        passed.onHoverChanged = { reports.append($0) }
        defer { HoverTrackingView.isHeld = false }

        // An item is dragged over the row: it does not light up.
        HoverTrackingView.isHeld = true
        passed.pointer = NSPoint(x: 10, y: 10)
        passed.mouseEntered(with: event(.mouseEntered))
        passed.syncHover()
        #expect(reports.isEmpty)

        // Let go over it: now it does.
        HoverTrackingView.isHeld = false
        passed.syncHover()
        #expect(reports == [true])
    }

    @Test func aDragClearsAndBlocksThePaneTint() {
        let hover = PaneSidebarHover.shared
        let (grabbed, passed) = (UUID(), UUID())
        defer { HoverTrackingView.isHeld = false; hover.clear() }
        hover.hover(grabbed, color: .red)
        HoverTrackingView.isHeld = true
        #expect(hover.pane == nil, "the grabbed tile's pane loses its tint")
        hover.hover(passed, color: .blue)
        #expect(hover.pane == nil, "a tile it passes tints nothing")
    }
}

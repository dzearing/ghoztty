import AppKit
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
}

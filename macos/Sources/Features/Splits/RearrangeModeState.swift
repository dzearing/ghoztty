import SwiftUI

/// Per-window state for pane rearrange mode.
///
/// The mode is an AFFORDANCE state, not a behavior state: turning it on gives
/// every pane a header with a drag grip and a pop-out button, and forces the
/// tab bar visible because the tab bar is a drop target. It does NOT change
/// what a drop does — a drag started from the hover grab handle with the mode
/// off resolves through exactly the same `PaneDropResolver`. Keeping the mode
/// out of the drop path is what stops "moded dropping" and "unmoded dropping"
/// from drifting into two behaviors.
@MainActor
class RearrangeModeState: ObservableObject {
    @Published private(set) var isActive: Bool = false

    /// True when entering the mode is what made the tab bar visible, so
    /// exiting knows to put it back. A tab bar the user already had (two or
    /// more tabs, or they chose Show Tab Bar) is left alone.
    private(set) var didForceTabBar: Bool = false

    func activate(forcingTabBar: Bool) {
        guard !isActive else { return }
        didForceTabBar = forcingTabBar
        isActive = true
    }

    /// Leave the mode. Returns true when the caller must un-force the tab bar
    /// — i.e. when this activation is the reason it is showing.
    @discardableResult
    func deactivate() -> Bool {
        guard isActive else { return false }
        let shouldRestoreTabBar = didForceTabBar
        didForceTabBar = false
        isActive = false
        return shouldRestoreTabBar
    }
}

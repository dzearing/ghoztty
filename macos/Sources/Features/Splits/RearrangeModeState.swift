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

/// Keeps rearrange mode's tab bar forcing out of AppKit's persisted state.
///
/// `NSWindow.toggleTabBar(_:)` is the only public way to show a lone window's
/// tab bar, and it is also the Show/Hide Tab Bar menu item — so AppKit records
/// it as the user's choice, in `NSWindowTabbingShoudShowTabBarKey-…` (one key
/// for every window of the class, sic "Shoud"), and every window after it shows
/// a tab bar even with one tab. The mode's toggles are not that choice. A mode
/// that ended without its matching toggle — a drop that turned the window into
/// a tab group, a window closed or the app quit mid-mode — used to leave the
/// key at `1` for good.
enum TabBarVisibilityPreference {
    static let keyPrefix = "NSWindowTabbingShoudShowTabBarKey-"

    /// Run `body` (a `toggleTabBar`), then put every persisted tab bar key
    /// back exactly as it was: the window's tab bar changes, the saved
    /// preference does not.
    static func preservingPersistedVisibility(
        in defaults: UserDefaults = .standard,
        _ body: () -> Void
    ) {
        let before = snapshot(defaults)
        body()
        for key in snapshot(defaults).keys where before[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in before {
            defaults.set(value, forKey: key)
        }
    }

    /// Builds before this fix leaked the key, and nothing tells a leaked `1`
    /// from a deliberate Show Tab Bar — so it is cleared once, on the first
    /// launch of a build that no longer leaks it. A user who did want the bar
    /// always shown chooses View → Show Tab Bar again, once.
    static let leakClearedKey = "TabBarVisibilityLeakCleared"

    static func clearLeakedPreferenceOnce(in defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: leakClearedKey) else { return }
        for key in snapshot(defaults).keys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: leakClearedKey)
    }

    private static func snapshot(_ defaults: UserDefaults) -> [String: Any] {
        defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(keyPrefix) }
    }
}

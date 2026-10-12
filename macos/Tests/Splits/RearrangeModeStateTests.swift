import Foundation
import Testing
@testable import Ghostty

@MainActor
struct RearrangeModeStateTests {
    @Test func startsInactive() {
        let state = RearrangeModeState()
        #expect(state.isActive == false)
        #expect(state.didForceTabBar == false)
    }

    @Test func activatingRemembersWhetherItForcedTheTabBar() {
        let state = RearrangeModeState()
        state.activate(forcingTabBar: true)
        #expect(state.isActive)
        #expect(state.didForceTabBar)
    }

    @Test func deactivatingReportsThatTheTabBarMustBeRestored() {
        let state = RearrangeModeState()
        state.activate(forcingTabBar: true)
        #expect(state.deactivate() == true)
        #expect(state.isActive == false)
        #expect(state.didForceTabBar == false)
    }

    @Test func aTabBarTheUserAlreadyHadSurvivesTheMode() {
        // The window was already showing a tab bar (a real tab group, or the
        // user chose Show Tab Bar). Exiting must not take it away.
        let state = RearrangeModeState()
        state.activate(forcingTabBar: false)
        #expect(state.deactivate() == false)
    }

    @Test func deactivatingWhenInactiveIsANoOp() {
        let state = RearrangeModeState()
        #expect(state.deactivate() == false)
        #expect(state.isActive == false)
    }

    @Test func activatingTwiceDoesNotOverwriteTheRememberedTabBar() {
        // `enterRearrangeModeIfNeeded` is called again after every drop into
        // this window. A second call must not decide the tab bar was already
        // visible and forget that entering is what showed it.
        let state = RearrangeModeState()
        state.activate(forcingTabBar: true)
        state.activate(forcingTabBar: false)
        #expect(state.didForceTabBar)
        #expect(state.deactivate() == true)
    }
}

struct TabBarVisibilityPreferenceTests {
    private static let key = TabBarVisibilityPreference.keyPrefix + "TestWindow-TestController-VT-FS"

    private func withScratchDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "ghoztty.tests.tabbar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }

    @Test func aForcedToggleLeavesNoPreferenceBehind() {
        // The leak: AppKit records toggleTabBar as "always show the tab bar"
        // and every later lone window shows one.
        withScratchDefaults { defaults in
            TabBarVisibilityPreference.preservingPersistedVisibility(in: defaults) {
                defaults.set(true, forKey: Self.key)
            }
            #expect(defaults.object(forKey: Self.key) == nil)
        }
    }

    @Test func theUsersOwnChoiceSurvivesTheMode() {
        withScratchDefaults { defaults in
            defaults.set(true, forKey: Self.key)
            TabBarVisibilityPreference.preservingPersistedVisibility(in: defaults) {
                defaults.set(false, forKey: Self.key)
            }
            #expect(defaults.bool(forKey: Self.key) == true)
        }
    }

    @Test func otherDefaultsAreUntouched() {
        withScratchDefaults { defaults in
            TabBarVisibilityPreference.preservingPersistedVisibility(in: defaults) {
                defaults.set(42, forKey: "SomethingElse")
            }
            #expect(defaults.integer(forKey: "SomethingElse") == 42)
        }
    }

    @Test func aLeakedPreferenceIsClearedOnceOnly() {
        withScratchDefaults { defaults in
            defaults.set(true, forKey: Self.key)
            TabBarVisibilityPreference.clearLeakedPreferenceOnce(in: defaults)
            #expect(defaults.object(forKey: Self.key) == nil)

            // A Show Tab Bar chosen after that is the user's, and stays.
            defaults.set(true, forKey: Self.key)
            TabBarVisibilityPreference.clearLeakedPreferenceOnce(in: defaults)
            #expect(defaults.bool(forKey: Self.key) == true)
        }
    }
}

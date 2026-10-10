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

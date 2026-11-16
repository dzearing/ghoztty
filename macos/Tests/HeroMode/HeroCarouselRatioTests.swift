import AppKit
import Testing
@testable import Ghostty

/// The carousel's starting size when hero mode turns on —
/// `macos-hero-carousel-width` (130pt), or `macos-hero-carousel-ratio` when
/// set — until the divider is dragged in that window.
struct HeroCarouselRatioTests {
    @Test func startsAt130Points() {
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: 2)
        #expect(state.carouselWidth == 130)
        #expect(state.carouselWidth(in: 1700) == 130)
        // Never more than the widest share on a narrow window.
        #expect(state.carouselWidth(in: 200) == 200 * HeroModeState.maxCarouselRatio)
    }

    @Test func aConfiguredWidthIsTakenAndClamped() {
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: 2, carouselWidth: 200)
        #expect(state.carouselWidth(in: 1700) == 200)
        state.activate(focusedIndex: 0, leafCount: 2, carouselWidth: 10)
        #expect(state.carouselWidth(in: 1700) == HeroModeState.minCarouselWidth)
    }

    @Test func aConfiguredRatioWinsOverTheWidth() {
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: 2, carouselRatio: 0.4, carouselWidth: 130)
        #expect(state.carouselWidth == nil)
        #expect(state.carouselWidth(in: 1000) == 400)
    }

    @Test func heroTurnsOnOverASinglePane() {
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: 1)
        #expect(state.isActive)
    }

    @Test func aDragNeedNotSnapA130PointCarouselWider() {
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: 2)
        // 130pt of a 1728pt window is 0.075, under the configured minimum.
        state.resizeCarousel(to: 130 / 1728)
        #expect(abs(state.carouselWidth(in: 1728) - 130) < 0.5)
    }

    @Test func turningHeroOnTakesTheConfiguredRatio() {
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: 2, carouselRatio: 0.4)
        #expect(state.carouselRatio == 0.4)
    }

    @Test(arguments: [(0.01, 0.1), (0.9, 0.6), (Double.nan, 0.25)])
    func theConfiguredRatioIsClamped(raw: Double, expected: Double) {
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: 2, carouselRatio: CGFloat(raw))
        #expect(state.carouselRatio == CGFloat(expected))
    }

    @Test func aDraggedDividerIsKeptWhenHeroIsTurnedOnAgain() {
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: 2, carouselRatio: 0.3)
        state.resizeCarousel(to: 0.5)
        state.deactivate()
        state.activate(focusedIndex: 0, leafCount: 2, carouselRatio: 0.3)
        #expect(state.carouselRatio == 0.5)
    }

    @Test func aDragIsClamped() {
        let state = HeroModeState()
        state.resizeCarousel(to: 0.95)
        #expect(state.carouselRatio == 0.6)
    }
}

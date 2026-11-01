import AppKit
import Testing
@testable import Ghostty

/// `macos-hero-carousel-ratio`: the carousel's starting share when hero mode
/// turns on, until the divider is dragged in that window.
struct HeroCarouselRatioTests {
    @Test func startsAtTheDefaultQuarter() {
        let state = HeroModeState()
        state.activate(focusedIndex: 0, leafCount: 2)
        #expect(state.carouselRatio == 0.25)
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

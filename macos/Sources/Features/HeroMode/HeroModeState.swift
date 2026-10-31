import SwiftUI
import GhosttyKit

class HeroModeState: ObservableObject {
    @Published var isActive: Bool = false
    @Published var selectedIndex: Int = 0
    @Published var carouselRatio: CGFloat = HeroModeState.defaultCarouselRatio
    @Published var scrollOffset: CGFloat = 0

    /// The carousel's divider has been dragged in this window: its size is
    /// the user's from then on, and turning hero on again keeps it rather
    /// than going back to `macos-hero-carousel-ratio`.
    private(set) var isCarouselResized = false

    /// `macos-hero-carousel-ratio`'s default.
    static let defaultCarouselRatio: CGFloat = 0.25
    static let minCarouselRatio: CGFloat = 0.1
    static let maxCarouselRatio: CGFloat = 0.6

    static func clampedCarouselRatio(_ ratio: CGFloat) -> CGFloat {
        guard ratio.isFinite else { return defaultCarouselRatio }
        return min(maxCarouselRatio, max(minCarouselRatio, ratio))
    }

    /// Turn hero on. `carouselRatio` is the configured starting share
    /// (`macos-hero-carousel-ratio`); it applies until the divider is
    /// dragged in this window.
    func activate(focusedIndex: Int, leafCount: Int, carouselRatio startRatio: CGFloat? = nil) {
        guard leafCount > 1 else { return }
        if let startRatio, !isCarouselResized {
            carouselRatio = Self.clampedCarouselRatio(startRatio)
        }
        selectedIndex = clampIndex(focusedIndex, leafCount: leafCount)
        scrollOffset = 0
        isActive = true
    }

    func deactivate() {
        isActive = false
        scrollOffset = 0
    }

    func select(_ index: Int, leafCount: Int) {
        let clamped = clampIndex(index, leafCount: leafCount)
        guard clamped != selectedIndex else { return }
        selectedIndex = clamped
        scrollOffset = 0
    }

    func selectNext(leafCount: Int) {
        select(selectedIndex + 1, leafCount: leafCount)
    }

    func selectPrevious(leafCount: Int) {
        select(selectedIndex - 1, leafCount: leafCount)
    }

    /// The divider was dragged to `ratio` (clamped).
    func resizeCarousel(to ratio: CGFloat) {
        carouselRatio = Self.clampedCarouselRatio(ratio)
        isCarouselResized = true
    }

    func clampIndex(_ leafCount: Int) {
        selectedIndex = clampIndex(selectedIndex, leafCount: leafCount)
    }

    private func clampIndex(_ index: Int, leafCount: Int) -> Int {
        guard leafCount > 0 else { return 0 }
        return max(0, min(leafCount - 1, index))
    }

}

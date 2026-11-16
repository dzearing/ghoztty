import SwiftUI
import GhosttyKit

class HeroModeState: ObservableObject {
    @Published var isActive: Bool = false
    @Published var selectedIndex: Int = 0
    @Published var carouselRatio: CGFloat = HeroModeState.defaultCarouselRatio
    /// A fixed carousel width in points (`macos-hero-carousel-width`), in
    /// place of `carouselRatio`, until the divider is dragged.
    @Published var carouselWidth: CGFloat? = HeroModeState.defaultCarouselWidth
    @Published var scrollOffset: CGFloat = 0

    /// The carousel's divider has been dragged in this window: its size is
    /// the user's from then on, and turning hero on again keeps it rather
    /// than going back to `macos-hero-carousel-ratio`.
    private(set) var isCarouselResized = false

    /// The share a ratio falls back to (an invalid one).
    static let defaultCarouselRatio: CGFloat = 0.25
    static let minCarouselRatio: CGFloat = 0.1
    static let maxCarouselRatio: CGFloat = 0.6
    /// How narrow a drag may make the carousel: below the configured
    /// ratios, so a 130pt carousel is not snapped wider on a big window.
    static let minDraggedCarouselRatio: CGFloat = 0.05

    /// `macos-hero-carousel-width`'s default and range, in points.
    static let defaultCarouselWidth: CGFloat = 130
    static let minCarouselWidth: CGFloat = 80
    static let maxCarouselWidth: CGFloat = 600

    static func clampedCarouselWidth(_ width: CGFloat) -> CGFloat {
        guard width.isFinite else { return defaultCarouselWidth }
        return min(maxCarouselWidth, max(minCarouselWidth, width))
    }

    /// The carousel's width in a window `windowWidth` wide.
    func carouselWidth(in windowWidth: CGFloat) -> CGFloat {
        if let carouselWidth { return min(carouselWidth, windowWidth * Self.maxCarouselRatio) }
        return windowWidth * carouselRatio
    }

    static func clampedCarouselRatio(_ ratio: CGFloat) -> CGFloat {
        guard ratio.isFinite else { return defaultCarouselRatio }
        return min(maxCarouselRatio, max(minCarouselRatio, ratio))
    }

    /// Turn hero on — over one pane too. The carousel starts at the
    /// configured width (`macos-hero-carousel-width`), or share
    /// (`macos-hero-carousel-ratio`) when one is set; either applies until
    /// the divider is dragged in this window.
    func activate(
        focusedIndex: Int, leafCount: Int,
        carouselRatio startRatio: CGFloat? = nil,
        carouselWidth startWidth: CGFloat? = nil
    ) {
        guard leafCount > 0 else { return }
        if !isCarouselResized {
            if let startRatio {
                carouselRatio = Self.clampedCarouselRatio(startRatio)
                carouselWidth = nil
            } else {
                carouselWidth = Self.clampedCarouselWidth(startWidth ?? Self.defaultCarouselWidth)
            }
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
        carouselRatio = ratio.isFinite
            ? min(Self.maxCarouselRatio, max(Self.minDraggedCarouselRatio, ratio))
            : Self.defaultCarouselRatio
        carouselWidth = nil
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

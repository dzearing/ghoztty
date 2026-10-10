import AppKit

/// Names the window a drop lands in without holding one.
///
/// The resolver is pure — it must not retain a `TerminalController`, and a
/// test must be able to fabricate a window identity out of nothing. Both fall
/// out of wrapping `ObjectIdentifier`: the coordinator maps a ref back to its
/// controller by scanning live windows, and a test hands in any object.
///
/// Because it does NOT retain, the caller must keep the object alive for as
/// long as the ref is meaningful. In the app that is free (a ref is only ever
/// made from a live controller); in a test, `PaneDropWindowRef(NSObject())`
/// is a trap — the temporary deallocates and the next allocation can land on
/// the same address, so two "different" windows compare EQUAL. Hold the
/// tokens in stored properties.
struct PaneDropWindowRef: Hashable, CustomStringConvertible {
    private let id: ObjectIdentifier

    init(_ object: AnyObject) {
        self.id = ObjectIdentifier(object)
    }

    var description: String { "window(\(id))" }
}

/// What a pane drag would do if released right now.
///
/// A value, not an action: producing one touches nothing, which is what lets
/// the same target drive both the live drop-feedback overlay and the commit.
enum PaneDropTarget: Equatable {
    /// Split `pane` on `direction`, putting the dragged pane there.
    case split(window: PaneDropWindowRef, pane: UUID, direction: SplitTree<PaneView>.NewDirection)

    /// Exchange the dragged pane and `pane` in place.
    case swap(window: PaneDropWindowRef, pane: UUID)

    /// Insert at the TOP level of the window's tree, on `side`, so the
    /// dragged pane spans the full width or height of the window.
    case topLevel(window: PaneDropWindowRef, side: SplitTree<PaneView>.NewDirection)

    /// Move the pane into a new tab of its own, at `index` in the tab bar.
    case newTab(window: PaneDropWindowRef, index: Int)

    /// Move the pane into a new window at this screen point. This is what
    /// "released over nothing" means.
    case newWindow(at: CGPoint)

    /// The window this target lands in, or nil for a brand new one.
    var window: PaneDropWindowRef? {
        switch self {
        case .split(let w, _, _), .swap(let w, _), .topLevel(let w, _), .newTab(let w, _): w
        case .newWindow: nil
        }
    }
}

/// Everything the resolver needs to know about ONE candidate window.
///
/// All rects are in SCREEN coordinates (AppKit: y grows upward), because that
/// is the only space a cross-window drag has in common — a drag session
/// reports screen points, and two windows share no view hierarchy.
struct PaneDropCandidate {
    let window: PaneDropWindowRef

    /// Front-to-back ordering, 0 = frontmost. Decides which window owns a
    /// point that two overlapping windows both contain.
    let zOrder: Int

    /// The split-tree area: the window's content rect, excluding titlebar.
    let contentRect: CGRect

    /// Every leaf pane's frame, keyed by `PaneView.id`.
    let paneRects: [(id: UUID, rect: CGRect)]

    /// The tab bar, when this window is showing one.
    let tabBarRect: CGRect?

    /// Tab buttons in visual order, left to right.
    let tabButtonRects: [CGRect]

    init(
        window: PaneDropWindowRef,
        zOrder: Int,
        contentRect: CGRect,
        paneRects: [(id: UUID, rect: CGRect)],
        tabBarRect: CGRect? = nil,
        tabButtonRects: [CGRect] = []
    ) {
        self.window = window
        self.zOrder = zOrder
        self.contentRect = contentRect
        self.paneRects = paneRects
        self.tabBarRect = tabBarRect
        self.tabButtonRects = tabButtonRects
    }
}

/// Turns a screen point plus a set of candidate windows into the drop that
/// point means.
///
/// Pure by construction: no AppKit objects in the signature, no mutation, no
/// main-actor isolation. It takes a SET of windows rather than one because
/// cross-window dragging is a first-class case, not something bolted on after
/// — a resolver that knew about only one window would have to be rewritten to
/// learn about two.
///
/// Applying a resolved target is `PaneMoveCoordinator`'s job.
enum PaneDropResolver {
    // MARK: Geometry

    /// How far inside the window's content edge the top-level insert band
    /// reaches.
    static let windowEdgeBand: CGFloat = 28

    /// The swap rectangle is this fraction of each of the pane's dimensions,
    /// floored at `swapMinimum` so a narrow pane still has a hittable target
    /// and capped at `swapMaximumFraction` so a small pane does not become
    /// mostly swap.
    static let swapFraction: CGFloat = 0.34
    static let swapMinimum: CGFloat = 44
    static let swapMaximumFraction: CGFloat = 0.60

    /// Below this the edge band is suppressed. A band on every side of a tiny
    /// window would tile the whole thing, leaving no way to reach a pane's own
    /// zones — the band is a refinement of pane targeting, so it must never
    /// eat all of it.
    static let minimumWindowForEdgeBand: CGFloat = windowEdgeBand * 4

    /// Where a point falls within a single pane.
    enum PaneZone: Equatable {
        case edge(SplitTree<PaneView>.NewDirection)
        case center
    }

    // MARK: Resolution

    /// The drop `screenPoint` currently means, or nil for "nothing would
    /// happen" (over a window but not over any target, or over the dragged
    /// pane itself).
    static func resolve(
        screenPoint: CGPoint,
        candidates: [PaneDropCandidate],
        dragged: UUID
    ) -> PaneDropTarget? {
        let ordered = candidates.sorted { $0.zOrder < $1.zOrder }

        // The tab bar sits outside the content rect and outranks it: it is
        // chrome, and a point on it is never also a point on a pane.
        if let hit = tabBarHit(screenPoint: screenPoint, candidates: ordered) {
            return .newTab(window: hit.window, index: hit.index)
        }

        guard let candidate = ordered.first(where: { $0.contentRect.contains(screenPoint) }) else {
            // Over no window of ours at all.
            return .newWindow(at: screenPoint)
        }

        // The window edge beats the pane under it. Dropping at the very edge
        // of a window reads as "put it down the whole side", which a pane's
        // own half-split cannot express.
        if let side = edgeBandSide(for: screenPoint, in: candidate.contentRect) {
            return .topLevel(window: candidate.window, side: side)
        }

        guard let pane = candidate.paneRects.first(where: { $0.rect.contains(screenPoint) }) else {
            // Inside the window but between panes — a divider. Nothing.
            return nil
        }

        // A pane cannot be dropped onto itself: every zone of it is a no-op,
        // and a swap with itself is not a swap.
        guard pane.id != dragged else { return nil }

        return switch paneZone(at: screenPoint, in: pane.rect) {
        case .center: .swap(window: candidate.window, pane: pane.id)
        case .edge(let direction): .split(window: candidate.window, pane: pane.id, direction: direction)
        }
    }

    /// The tab currently under the pointer, for the long-hover timer that
    /// switches tabs mid-drag.
    ///
    /// Separate from `resolve` because it is a *dwell* result, not a drop: the
    /// same point simultaneously means "release here to make a new tab" and
    /// "rest here to open that tab".
    static func hoveredTab(
        screenPoint: CGPoint,
        candidates: [PaneDropCandidate]
    ) -> (window: PaneDropWindowRef, index: Int)? {
        let ordered = candidates.sorted { $0.zOrder < $1.zOrder }
        for candidate in ordered {
            guard let tabBarRect = candidate.tabBarRect,
                  tabBarRect.contains(screenPoint) else { continue }
            guard let index = candidate.tabButtonRects.firstIndex(where: { $0.contains(screenPoint) }) else {
                // The bar's background or its "+" button names no tab.
                return nil
            }
            return (candidate.window, index)
        }
        return nil
    }

    // MARK: Pieces

    /// The swap rectangle inscribed in a pane.
    static func swapRect(in rect: CGRect) -> CGRect {
        let width = min(max(rect.width * swapFraction, swapMinimum), rect.width * swapMaximumFraction)
        let height = min(max(rect.height * swapFraction, swapMinimum), rect.height * swapMaximumFraction)
        return CGRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height)
    }

    /// Which pane zone a point falls in.
    ///
    /// Outside the swap rectangle the pane is divided into four triangles by
    /// its diagonals — "nearest edge wins" — which is what makes the corners
    /// behave: a point up and to the left reads as whichever it is more of.
    static func paneZone(at point: CGPoint, in rect: CGRect) -> PaneZone {
        if swapRect(in: rect).contains(point) { return .center }
        return .edge(nearestSide(to: point, in: rect))
    }

    /// The top-level insert side a point in the window's edge band means, or
    /// nil when it is not in the band.
    static func edgeBandSide(
        for point: CGPoint,
        in contentRect: CGRect
    ) -> SplitTree<PaneView>.NewDirection? {
        guard contentRect.contains(point) else { return nil }
        guard contentRect.width >= minimumWindowForEdgeBand,
              contentRect.height >= minimumWindowForEdgeBand else { return nil }

        // In POINTS, not normalized: the band is an absolute 28pt, so the
        // edge it names must be the one actually nearest in points. Using the
        // pane triangles' normalized distances here would miss — 30pt from a
        // short window's side is "nearer" in fractions than 10pt from its very
        // long bottom, and the drop would fall out of the band entirely.
        let toLeft = point.x - contentRect.minX
        let toRight = contentRect.maxX - point.x
        let toTop = contentRect.maxY - point.y
        let toBottom = point.y - contentRect.minY

        let minimum = min(toLeft, toRight, toTop, toBottom)
        guard minimum <= windowEdgeBand else { return nil }

        // Horizontal first, so an exact corner is deterministic.
        if minimum == toLeft { return .left }
        if minimum == toRight { return .right }
        if minimum == toTop { return .up }
        return .down
    }

    // MARK: Private

    private static func tabBarHit(
        screenPoint: CGPoint,
        candidates: [PaneDropCandidate]
    ) -> (window: PaneDropWindowRef, index: Int)? {
        for candidate in candidates {
            guard let tabBarRect = candidate.tabBarRect,
                  tabBarRect.contains(screenPoint) else { continue }
            // Over a button: insert at that button's index. Over the bar's
            // background or its "+": append. Either way the bar means "tab".
            let index = candidate.tabButtonRects.firstIndex { $0.contains(screenPoint) }
                ?? candidate.tabButtonRects.count
            return (candidate.window, index)
        }
        return nil
    }

    /// The edge a point is nearest to as a FRACTION of the pane's own
    /// dimensions — the four triangles cut by the pane's diagonals.
    ///
    /// Normalized rather than absolute so a 2000x200 pane still divides along
    /// its diagonals; in points its diagonals would be so shallow that nearly
    /// every position read as top or bottom. This is the same rule (and the
    /// same tie-break order) `TerminalSplitDropZone` used, in screen
    /// coordinates.
    ///
    /// Ties break horizontal-first — left, right, up, down — so an exact
    /// corner is deterministic.
    private static func nearestSide(
        to point: CGPoint,
        in rect: CGRect
    ) -> SplitTree<PaneView>.NewDirection {
        guard rect.width > 0, rect.height > 0 else { return .right }

        // Screen coordinates grow UPWARD, so the pane's top edge is maxY and
        // "insert above" is proximity to it.
        let toLeft = (point.x - rect.minX) / rect.width
        let toRight = (rect.maxX - point.x) / rect.width
        let toTop = (rect.maxY - point.y) / rect.height
        let toBottom = (point.y - rect.minY) / rect.height

        let minimum = min(toLeft, toRight, toTop, toBottom)
        if minimum == toLeft { return .left }
        if minimum == toRight { return .right }
        if minimum == toTop { return .up }
        return .down
    }
}

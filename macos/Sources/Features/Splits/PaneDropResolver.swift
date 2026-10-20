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

    /// Stash the pane in `window`'s pane sidebar, at `index` in its stash.
    case stash(window: PaneDropWindowRef, index: Int)

    /// Send the pane into `window`'s grid. What a drop on another window's
    /// group in the all-windows sidebar means: a cross-window move without
    /// dragging across the screen.
    case joinWindow(window: PaneDropWindowRef)

    /// A strip dragged along its own row: move the pane to `side` of the
    /// row's item made of the panes `beside`, within the row. `caret` is
    /// the insertion line to draw, in screen coordinates.
    case reorder(window: PaneDropWindowRef, beside: Set<UUID>, side: SplitTree<PaneView>.NewDirection, caret: CGRect)

    /// A strip dragged to a screen's edge: a new window holding the pane,
    /// covering `frame` — that half of the screen's visible frame.
    case tile(frame: CGRect)

    /// The window this target lands in, or nil for a brand new one.
    var window: PaneDropWindowRef? {
        switch self {
        case .split(let w, _, _), .swap(let w, _), .topLevel(let w, _), .newTab(let w, _),
             .stash(let w, _), .joinWindow(let w), .reorder(let w, _, _, _): w
        case .newWindow, .tile: nil
        }
    }
}

/// A strip — a pane minimized in a collapsed row — being dragged. It gets
/// targets of its own instead of a pane's (`PaneDropResolver.resolveBlade`).
struct PaneBladeDrag {
    /// Where in its row the strip can go: one slot per place between two of
    /// the row's items (cards on show and strips alike), and one at each
    /// end. In screen coordinates.
    struct Slot: Equatable {
        /// Where the pointer means this slot.
        let rect: CGRect
        /// The insertion line to draw: the gutter at the slot.
        let caret: CGRect
        /// The item the pane goes beside, by its panes, and which side.
        let beside: Set<UUID>
        let side: SplitTree<PaneView>.NewDirection
    }

    /// The window the strip lives in.
    let window: PaneDropWindowRef
    let slots: [Slot]
    /// Every screen's visible frame, for tiling to an edge.
    let screens: [CGRect]

    /// How far in from a screen's edge a drop tiles to it. Narrower than the
    /// window edge band: a window that fills the screen keeps its own edges
    /// just inside.
    static let screenEdgeBand: CGFloat = 12

    /// How far a slot reaches into the cards either side of its gutter: a
    /// strip is 36pt, so the slots either side of one meet across it.
    static let slotReach: CGFloat = 24

    /// The slots of a row: `items` in order, each with the screen rect its
    /// panes show in (a card, or its strip) and its panes; `dragged`'s own
    /// item is left out (a drop beside itself changes nothing).
    static func slots(
        items: [(rect: CGRect, panes: Set<UUID>)],
        direction: PaneLayout.Direction,
        dragged: UUID
    ) -> [Slot] {
        // The dragged pane leaves wherever it was: its own item, or the
        // column it was one pane of.
        let others = items.filter { $0.panes != [dragged] }
            .map { (rect: $0.rect, panes: $0.panes.subtracting([dragged])) }
        guard !others.isEmpty else { return [] }
        let across = others.dropFirst().reduce(others[0].rect) { $0.union($1.rect) }
        // Screen coordinates run UP: a column's first item is its top.
        let (before, after): (SplitTree<PaneView>.NewDirection, SplitTree<PaneView>.NewDirection) =
            direction == .horizontal ? (.left, .right) : (.up, .down)
        func band(_ from: CGFloat, _ to: CGFloat) -> (rect: CGRect, caret: CGRect) {
            let mid = (from + to) / 2
            let reach = Swift.max(slotReach, (to - from) / 2)
            switch direction {
            case .horizontal:
                return (CGRect(x: mid - reach, y: across.minY, width: 2 * reach, height: across.height),
                        CGRect(x: mid - 1.5, y: across.minY, width: 3, height: across.height))
            case .vertical:
                return (CGRect(x: across.minX, y: mid - reach, width: across.width, height: 2 * reach),
                        CGRect(x: across.minX, y: mid - 1.5, width: across.width, height: 3))
            }
        }
        // Along the row: leading to trailing (a column's leading is its top,
        // which is the HIGHER y on screen).
        func lead(_ r: CGRect) -> CGFloat { direction == .horizontal ? r.minX : r.maxY }
        func trail(_ r: CGRect) -> CGFloat { direction == .horizontal ? r.maxX : r.minY }
        var slots: [Slot] = []
        let first = others[0]
        let start = band(lead(first.rect), lead(first.rect))
        slots.append(Slot(rect: start.rect, caret: start.caret, beside: first.panes, side: before))
        for (a, b) in zip(others, others.dropFirst()) {
            // Leaving out the dragged pane's own item leaves its neighbours'
            // gap wider; the slot spans it.
            let gap = direction == .horizontal ? band(trail(a.rect), lead(b.rect)) : band(lead(b.rect), trail(a.rect))
            slots.append(Slot(rect: gap.rect, caret: gap.caret, beside: a.panes, side: after))
        }
        let last = others[others.count - 1]
        let end = band(trail(last.rect), trail(last.rect))
        slots.append(Slot(rect: end.rect, caret: end.caret, beside: last.panes, side: after))
        // A drop beside the strip's own neighbours, on its own side, is
        // where it already is.
        let index = items.firstIndex { $0.panes == [dragged] }
        return slots.enumerated().filter { k, _ in
            guard let index else { return true }
            // Slot k sits between others[k-1] and others[k]: the dragged
            // item's own place is the slot that replaced it.
            return k != index
        }.map(\.element)
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

    /// The window's pane sidebar, when it is showing. Nil while hidden — a
    /// hidden sidebar is not a drop target.
    let sidebar: Sidebar?

    /// The pane sidebar's droppable geometry, in screen coordinates.
    struct Sidebar {
        /// The whole sidebar card or panel as drawn — including a mini rail
        /// opened over the grid, which is exactly where the pointer is.
        let rect: CGRect

        /// This window's STASHED rows, top to bottom, keyed by pane id. The
        /// stash index of a drop is the gap between these nearest the pointer.
        let stashRows: [(id: UUID, rect: CGRect)]

        /// With the all-windows scope on: each OTHER window's group, so a
        /// drop there sends the pane to that window.
        let windowGroups: [(window: PaneDropWindowRef, rect: CGRect)]

        init(
            rect: CGRect,
            stashRows: [(id: UUID, rect: CGRect)] = [],
            windowGroups: [(window: PaneDropWindowRef, rect: CGRect)] = []
        ) {
            self.rect = rect
            self.stashRows = stashRows
            self.windowGroups = windowGroups
        }
    }

    init(
        window: PaneDropWindowRef,
        zOrder: Int,
        contentRect: CGRect,
        paneRects: [(id: UUID, rect: CGRect)],
        tabBarRect: CGRect? = nil,
        tabButtonRects: [CGRect] = [],
        sidebar: Sidebar? = nil
    ) {
        self.window = window
        self.zOrder = zOrder
        self.contentRect = contentRect
        self.paneRects = paneRects
        self.tabBarRect = tabBarRect
        self.tabButtonRects = tabButtonRects
        self.sidebar = sidebar
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
    /// pane itself). A strip being dragged (`blade`) means something else
    /// (`resolveBlade`).
    static func resolve(
        screenPoint: CGPoint,
        candidates: [PaneDropCandidate],
        dragged: UUID,
        blade: PaneBladeDrag? = nil
    ) -> PaneDropTarget? {
        if let blade { return resolveBlade(screenPoint: screenPoint, candidates: candidates, dragged: dragged, blade: blade) }
        let ordered = candidates.sorted { $0.zOrder < $1.zOrder }

        // The tab bar sits outside the content rect and outranks it: it is
        // chrome, and a point on it is never also a point on a pane.
        if let hit = tabBarHit(screenPoint: screenPoint, candidates: ordered) {
            return .newTab(window: hit.window, index: hit.index)
        }

        // The pane sidebar is chrome over the window, like the tab bar: a
        // point on it never also means a pane, so it is resolved before the
        // content rect (which it sits beside, or — opened over the grid —
        // on top of).
        if let hit = sidebarHit(screenPoint: screenPoint, candidates: ordered, dragged: dragged) {
            return hit
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

    /// What dropping a strip at `screenPoint` means. A strip is a pane put
    /// away in its row, so it has the targets of a pane being put somewhere
    /// else in that row, or taken out of the window — never a pane's own
    /// split quadrants or swap (a strip used to swap with a pane it was
    /// dropped on):
    ///
    /// 1. **A screen's edge** (`screenEdgeBand`): a new window tiled to that
    ///    half of the screen. Outermost, so it wins at the very edge.
    /// 2. **The pane sidebar**: stash it, as for any pane.
    /// 3. **A slot in its own row**, between two of its cards or strips or
    ///    at either end: the pane moves there.
    /// 4. **A window's edge band**: a top-level insert, as for any pane.
    ///
    /// Anywhere else, nothing: the card settles back.
    static func resolveBlade(
        screenPoint: CGPoint,
        candidates: [PaneDropCandidate],
        dragged: UUID,
        blade: PaneBladeDrag
    ) -> PaneDropTarget? {
        if let frame = tileFrame(at: screenPoint, screens: blade.screens) {
            return .tile(frame: frame)
        }
        let ordered = candidates.sorted { $0.zOrder < $1.zOrder }
        // The pane sidebar is chrome, as for any pane: a strip stashes there.
        if let hit = sidebarHit(screenPoint: screenPoint, candidates: ordered, dragged: dragged) {
            return hit
        }
        let over = ordered.first { $0.contentRect.contains(screenPoint) }
        if over == nil || over?.window == blade.window,
           let slot = blade.slots.min(by: { distance(screenPoint, $0.caret) < distance(screenPoint, $1.caret) }),
           slot.rect.contains(screenPoint) {
            return .reorder(window: blade.window, beside: slot.beside, side: slot.side, caret: slot.caret)
        }
        guard let over, let side = edgeBandSide(for: screenPoint, in: over.contentRect) else { return nil }
        return .topLevel(window: over.window, side: side)
    }

    /// The half of a screen a point at its edge tiles to, or nil when the
    /// point is not at any screen's edge.
    static func tileFrame(at point: CGPoint, screens: [CGRect]) -> CGRect? {
        let band = PaneBladeDrag.screenEdgeBand
        for screen in screens where screen.insetBy(dx: -1, dy: -1).contains(point) {
            let toLeft = point.x - screen.minX, toRight = screen.maxX - point.x
            let toTop = screen.maxY - point.y, toBottom = point.y - screen.minY
            let nearest = Swift.min(toLeft, toRight, toTop, toBottom)
            guard nearest <= band else { return nil }
            let half = CGSize(width: screen.width / 2, height: screen.height / 2)
            if nearest == toLeft { return CGRect(origin: screen.origin, size: CGSize(width: half.width, height: screen.height)) }
            if nearest == toRight {
                return CGRect(x: screen.midX, y: screen.minY, width: half.width, height: screen.height)
            }
            if nearest == toTop { return CGRect(x: screen.minX, y: screen.midY, width: screen.width, height: half.height) }
            return CGRect(origin: screen.origin, size: CGSize(width: screen.width, height: half.height))
        }
        return nil
    }

    /// How far a point is from a rect (0 inside it).
    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = Swift.max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = Swift.max(r.minY - p.y, 0, p.y - r.maxY)
        return (dx * dx + dy * dy).squareRoot()
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

    /// The drop a point on a window's pane sidebar means, or nil when the
    /// point is on no sidebar.
    ///
    /// Anywhere on the sidebar means "stash": over another window's group (in
    /// the all-windows scope) it means "send it to that window"; otherwise the
    /// index is the number of this window's stashed rows above the point —
    /// so the grid section, which sits above the stash, means the top.
    static func sidebarHit(
        screenPoint: CGPoint,
        candidates: [PaneDropCandidate],
        dragged: UUID
    ) -> PaneDropTarget? {
        for candidate in candidates.sorted(by: { $0.zOrder < $1.zOrder }) {
            guard let sidebar = candidate.sidebar,
                  sidebar.rect.contains(screenPoint) else { continue }

            if let group = sidebar.windowGroups.first(where: { $0.rect.contains(screenPoint) }),
               group.window != candidate.window {
                return .joinWindow(window: group.window)
            }

            // Screen coordinates grow UPWARD: a row is above the point when
            // its middle is higher.
            let index = sidebar.stashRows
                .filter { $0.id != dragged }
                .filter { $0.rect.midY > screenPoint.y }
                .count
            return .stash(window: candidate.window, index: index)
        }
        return nil
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

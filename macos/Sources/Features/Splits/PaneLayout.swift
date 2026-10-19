import AppKit

/// Where every pane of a window's split tree goes, in points.
///
/// The ONE layout function: the grid renders from it, the hidden stashed-pane
/// slots render from it (so a stashed pane always has the size it will come
/// back at), and the tests check it. It is pure — a tree, a rectangle, and a
/// focus history in; frames out.
///
/// It owns two rules the old nested `SplitView`s could not express, because
/// both need to see a whole ROW of panes, not one binary split at a time:
///
/// - **A pane has a real minimum size** (`Metrics.minimumPaneSize`). A row
///   whose ratios would squeeze a pane below it is laid out as if the ratios
///   had been honored as far as they can be (`waterFill`), without touching
///   the stored ratios — so shrinking a window and growing it back returns the
///   layout the user made.
/// - **A row that cannot fit even at the minimum becomes a stack.** As many
///   panes as fit stay side by side (the visible RUN); the rest are cards
///   tucked behind them on the side they live on, each showing a `peek`-wide
///   sliver of its leading edge. The run's slots are equal until the user
///   resizes them, and a tucked card is the size of the slot it would come
///   forward into, so with equal slots changing which panes are in the run
///   moves cards but never resizes one.
/// - **The user can collapse a row by hand** (`Pin`): dragging a divider past
///   a pane's minimum tucks that side's outermost pane behind the rest.
///
/// Paint order is `Leaf.elevation`: the run is highest, and tucked cards sit
/// lower the farther they are from it, on both sides — so the run casts its
/// shadow on the cards beside it, and each card on the next one out. Before
/// the run a card's sliver is its leading edge, the rest under the card after
/// it. Past the run a card is drawn as its sliver alone (`Leaf.isSliver`):
/// it lies over the next card out, which shows past it.
///
/// "Row" here means a same-direction chain of the binary tree: `a | (b | c)`
/// is one row of three, and `a | (b / c)` is a row of two whose second item
/// is a column.
enum PaneLayout {
    struct Metrics: Equatable {
        /// The space between two side-by-side panes.
        var gap: CGFloat
        /// How much of a tucked card's leading edge shows.
        var peek: CGFloat
        /// The smallest a pane may be before its row starts stacking.
        var minimumPaneSize: CGSize

        /// The size floor: 300pt is about 35 columns of a typical font, the
        /// point below which a terminal (or a page) stops being readable; 200pt
        /// is about a dozen rows.
        static let minimumPaneSize = CGSize(width: 300, height: 200)

        /// A tucked card shows this much of itself: room for the vertical title
        /// strip and a few columns of what is in it.
        static let peek: CGFloat = 36

        /// How far past a pane's minimum a divider must be dragged before the
        /// pane tucks behind its neighbours instead (and how far a stack grip
        /// must be dragged to do the same, or to bring one back): far enough
        /// that resizing up against the minimum never does it by accident.
        static let restackDistance: CGFloat = 48

        /// Below this a tucked card can no longer be hit; past it a window too
        /// small for even one pane plus slivers lets the front panes shrink.
        static let minimumPeek: CGFloat = 8

        static func forStyle(paneGap: CGFloat?) -> Metrics {
            // The flat style's 1pt line straddles the edge between two panes,
            // half of it over each; the elevated style leaves a real gap.
            Metrics(gap: paneGap ?? 0.5, peek: peek, minimumPaneSize: minimumPaneSize)
        }
    }

    /// One pane's place.
    struct Leaf: Equatable {
        /// The pane's full frame. A tucked pane keeps its full size; most of it
        /// is behind the cards in front of it.
        var frame: CGRect

        /// Whether the pane is a card tucked behind the visible run of a stack
        /// (at any level), rather than on show.
        var isTucked: Bool

        /// The part of a tucked pane that shows: its leading sliver, where a
        /// click brings it forward. Nil for a pane on show.
        var tab: CGRect?

        /// The axis the tab's stack runs along (`.horizontal`: a tall sliver
        /// at the pane's left edge; `.vertical`: a short one at its top).
        var tabAxis: Direction?

        /// The card is past its stack's run, so it is drawn as its tab alone:
        /// it lies over the cards farther out, which show beyond it.
        var isSliver = false

        /// Where the card is painted: leaves are painted in ascending
        /// lexicographic order of this, one entry per stack the pane is in,
        /// outermost first. Ties keep the tree's order.
        var elevation: [Int] = []

        /// Where the pane may draw, when a card hangs off its stack's far end
        /// (cards past the run are laid out end to end and would otherwise run
        /// into whatever is beyond the stack). Only the far edges are bounds;
        /// the rest lie `PaneLayout.unbounded` away, so a card's shadow still
        /// falls on the card behind it. Nil: nothing bounds it.
        var clip: CGRect?
    }

    enum Direction: Equatable { case horizontal, vertical }

    /// How far away a `Leaf.clip` puts the edges that bound nothing.
    static let unbounded: CGFloat = 100_000

    enum Side: Equatable { case leading, trailing }

    /// A row of panes (see the type's doc) and which of its items are on show,
    /// for the gestures that change that.
    struct Row<ID: Hashable>: Equatable {
        /// The items' leaf ids, in order.
        let items: [[ID]]
        /// The items on show: all of them for a row side by side.
        let run: ClosedRange<Int>
        /// The extent of each item on show, in order (`run.count` of them).
        var sizes: [CGFloat] = []

        /// What names the row in `PaneStackState`: its panes, in any order, so
        /// swapping two of them keeps the row what it was.
        var key: Set<ID> { Set(items.joined()) }
    }

    /// How a gesture changes which items of a row are on show.
    enum Restack: Equatable {
        /// One fewer: the outermost item on show on that side tucks behind.
        case collapse(Side)
        /// One more: the nearest item tucked on that side comes back out.
        case expand(Side)
    }

    /// A row the user collapsed (`Restack`): `count` of its items on show,
    /// from `start` — whether or not the row would fit side by side. Bringing
    /// a tucked card forward restores it (`restoring`): the run grows to take
    /// it in where there is room, and slides to it where there is not.
    struct Pin: Equatable {
        var start: Int
        var count: Int

        /// Bring item `index` on show: the run grows to take it in, and when
        /// more than `fits` would then be on show, the items at the far end
        /// from it give way. Nil when that shows all `n` items.
        func restoring(_ index: Int, fits: Int, of n: Int) -> Pin? {
            var lower = Swift.min(start, index)
            var upper = Swift.max(start + count - 1, index)
            let most = Swift.max(1, fits)
            if upper - lower + 1 > most {
                if index < start { upper = lower + most - 1 } else { lower = upper - most + 1 }
            }
            let pin = Pin(start: lower, count: upper - lower + 1)
            return pin.count >= n ? nil : pin
        }

        /// What is left of the pin when the items at `removed` leave a row of
        /// `n` (a pane closed, stashed, or moved away): the items still on
        /// show close up over the slots the others left, and the tucked ones
        /// stay tucked on their sides. When nothing on show is left, the item
        /// before the run comes on show — where the caret goes after a close
        /// — or, with nothing before it, the one after. Nil when what is left
        /// all shows, or is no row at all.
        func removing(_ removed: Set<Int>, of n: Int) -> Pin? {
            let kept = (0..<n).filter { !removed.contains($0) }
            guard kept.count > 1 else { return nil }
            let run = start..<(start + count)
            let shown = kept.indices.filter { run.contains(kept[$0]) }
            let pin = if let first = shown.first {
                Pin(start: first, count: shown.count)
            } else {
                Pin(start: kept.lastIndex { $0 < start } ?? 0, count: 1)
            }
            return pin.count >= kept.count ? nil : pin
        }

        /// What `change` makes of a row of `n` items showing `run`; nil when
        /// it shows the whole row again.
        static func restacking(_ run: ClosedRange<Int>, of n: Int, _ change: Restack) -> Pin? {
            let pin: Pin
            switch change {
            case .collapse(let side):
                guard run.count > 1 else { return Pin(start: run.lowerBound, count: run.count) }
                pin = Pin(start: side == .leading ? run.lowerBound + 1 : run.lowerBound, count: run.count - 1)
            case .expand(let side):
                let start = side == .leading ? Swift.max(0, run.lowerBound - 1) : run.lowerBound
                pin = Pin(start: start, count: Swift.min(n - start, run.count + 1))
            }
            return pin.count >= n ? nil : pin
        }
    }

    /// A divider between two side-by-side panes (or groups of panes).
    struct Divider<Node, ID: Hashable> {
        /// The binary split this divider belongs to — what a drag on it moves.
        let node: Node
        let direction: Direction
        /// The split node's whole frame.
        let nodeFrame: CGRect
        /// The divider's centre, in points from the leading edge of `nodeFrame`
        /// along `direction`.
        let position: CGFloat
        /// The row the divider is in. A drag that would squeeze a pane past its
        /// minimum collapses the row instead (`Restack.collapse`).
        let row: Row<ID>
        /// How many of the row's items lie before the divider.
        let index: Int

        /// The divider's place in its row, which outlives a change of ratio.
        var id: String { "\(row.items)#\(index)" }

        /// The divider's current position as a fraction of the node.
        var fraction: CGFloat {
            let extent = direction == .horizontal ? nodeFrame.width : nodeFrame.height
            return extent > 0 ? position / extent : 0.5
        }

        /// The gap the divider sits in, as a line across the node.
        func line(thickness: CGFloat) -> CGRect {
            switch direction {
            case .horizontal:
                CGRect(x: nodeFrame.minX + position - thickness / 2, y: nodeFrame.minY,
                       width: thickness, height: nodeFrame.height)
            case .vertical:
                CGRect(x: nodeFrame.minX, y: nodeFrame.minY + position - thickness / 2,
                       width: nodeFrame.width, height: thickness)
            }
        }
    }

    /// A grip on a stacked row: between two cards on show, where a drag
    /// resizes the two — and past a card's minimum tucks the outermost card on
    /// that side behind — or at the edge where the run meets the tucked cards
    /// of a row the user collapsed, where a drag out over them brings one back.
    struct StackHandle<ID: Hashable>: Equatable {
        enum Kind: Equatable {
            /// Between run slots `slot` and `slot + 1` (indices into `row.sizes`).
            case between(slot: Int)
            /// At the run's edge on that side.
            case expand(Side)
        }

        let row: Row<ID>
        let direction: Direction
        /// The stack's frame.
        let frame: CGRect
        /// The grip's centre, in points from the stack's leading edge.
        let position: CGFloat
        let kind: Kind

        /// The grip's place, which outlives a resize of the slots around it.
        var id: String { "\(row.items)#\(row.run)#\(kind)" }

        func line(thickness: CGFloat) -> CGRect {
            switch direction {
            case .horizontal:
                CGRect(x: frame.minX + position - thickness / 2, y: frame.minY,
                       width: thickness, height: frame.height)
            case .vertical:
                CGRect(x: frame.minX, y: frame.minY + position - thickness / 2,
                       width: frame.width, height: thickness)
            }
        }
    }

    /// A row that is stacked, for callers that want to know (tests, a11y).
    struct Stack<ID: Hashable>: Equatable {
        let frame: CGRect
        let direction: Direction
        /// The items' leaf ids, in order.
        let items: [[ID]]
        /// The visible run: the indices of the items on show.
        let run: ClosedRange<Int>
        /// How many items could be on show at once in this space: all of them
        /// for a row the user collapsed that would fit side by side.
        var fits: Int = 0
    }

    struct Result<V: NSView & Codable & Identifiable> where V.ID: Hashable {
        var leaves: [V.ID: Leaf] = [:]
        var dividers: [Divider<SplitTree<V>.Node, V.ID>] = []
        var stacks: [Stack<V.ID>] = []
        var stackHandles: [StackHandle<V.ID>] = []
        /// The tree as laid out: every side-by-side row's ratios are the ones
        /// on screen, after minimums. A divider drag starts from this (see
        /// `SplitTree.adoptingDisplayedLayout`), so it moves what the user
        /// sees rather than ratios the minimums are overriding. Dividers
        /// name their nodes in THIS tree.
        var displayed: SplitTree<V>.Node?
    }
}

extension PaneLayout {
    /// Lay `root` out in `rect`.
    ///
    /// - Parameter rank: how recently a pane had focus, 0 being the focused one
    ///   (nil: never, or not known). A stack's visible run is built around the
    ///   most recently focused of its items, so focusing a tucked pane — by
    ///   clicking its tab, by `goto_split`, from the sidebar — is what brings
    ///   it forward, and a stack the user is not working in keeps showing what
    ///   they last looked at there.
    static func compute<V>(
        _ root: SplitTree<V>.Node,
        in rect: CGRect,
        metrics: Metrics,
        rank: @escaping (V) -> Int?,
        pin: @escaping (Set<V.ID>) -> Pin? = { _ in nil },
        shares: @escaping (Set<V.ID>) -> [CGFloat]? = { _ in nil }
    ) -> Result<V> where V.ID: Hashable {
        var engine = Engine<V>(metrics: metrics, rank: rank, pin: pin, shares: shares)
        engine.result.displayed = engine.layout(root, in: rect, tucked: false, clip: nil)
        return engine.result
    }

    /// Every row in `node` (see the type's doc), outermost first, as its
    /// items' leaf ids: what `PaneStackState` keys a row's collapse by.
    static func rows<V>(_ node: SplitTree<V>.Node?) -> [[[V.ID]]] where V.ID: Hashable {
        guard case .split(let split) = node else { return [] }
        func chain(_ node: SplitTree<V>.Node) -> [SplitTree<V>.Node] {
            guard case .split(let inner) = node, inner.direction == split.direction else { return [node] }
            return chain(inner.left) + chain(inner.right)
        }
        let items = chain(.split(split))
        return [items.map { $0.leaves().map(\.id) }] + items.flatMap { rows($0) }
    }

    /// The smallest extent of `node` along `d` with every pane at `minimum`:
    /// side by side, or — with `stacking` — with rows that don't fit stacked.
    /// No gaps: this is what a divider move clamps against, and the gaps are
    /// the layout's to make room for.
    static func minimumExtent<V>(
        _ node: SplitTree<V>.Node, along d: Direction, minimum: CGSize, stacking: Bool
    ) -> CGFloat {
        let engine = Engine<V>(
            metrics: Metrics(gap: 0, peek: Metrics.peek, minimumPaneSize: minimum),
            rank: { _ in nil },
            pin: { _ in nil },
            shares: { _ in nil })
        return stacking ? engine.compact(node, along: d) : engine.comfortable(node, along: d)
    }

    /// Distribute `available` in proportion to `wanted`, giving no item less than
    /// its entry in `minimums`: an item that would fall below its minimum is
    /// pinned there and the rest share what is left, again in proportion.
    ///
    /// The caller guarantees `minimums` fit in `available`.
    static func waterFill(_ wanted: [CGFloat], minimums: [CGFloat], available: CGFloat) -> [CGFloat] {
        var sizes = Array(repeating: CGFloat(0), count: wanted.count)
        var pinned = Array(repeating: false, count: wanted.count)
        while true {
            let pinnedTotal = zip(sizes, pinned).reduce(0) { $0 + ($1.1 ? $1.0 : 0) }
            let free = wanted.indices.filter { !pinned[$0] }
            guard !free.isEmpty else { return sizes }
            let wantedTotal = free.reduce(0) { $0 + Swift.max(wanted[$1], 0) }
            for i in free {
                let share = wantedTotal > 0 ? Swift.max(wanted[i], 0) / wantedTotal : 1 / CGFloat(free.count)
                sizes[i] = (available - pinnedTotal) * share
            }
            let under = free.filter { sizes[$0] < minimums[$0] }
            if under.isEmpty { return sizes }
            for i in under {
                sizes[i] = minimums[i]
                pinned[i] = true
            }
        }
    }

    /// Which items of a stack are on show: the most recently focused one, grown
    /// to `count` items toward whichever neighbor had focus more recently (to the
    /// trailing side on a tie, so a stack nobody has focused shows its first
    /// items).
    /// `panes` (in tree order) in the order to paint them, bottom first:
    /// by `Leaf.elevation`, ties in tree order.
    static func paintOrder<V: Identifiable>(_ panes: [V], _ leaves: [V.ID: Leaf]) -> [V] {
        panes.enumerated().sorted { a, b in
            let x = leaves[a.element.id]?.elevation ?? [], y = leaves[b.element.id]?.elevation ?? []
            if x.lexicographicallyPrecedes(y) { return true }
            if y.lexicographicallyPrecedes(x) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }

    static func visibleRun(ranks: [Int?], count: Int) -> ClosedRange<Int> {
        let n = ranks.count
        guard n > 0 else { return 0...0 }
        let count = Swift.min(Swift.max(count, 1), n)
        let key = ranks.map { $0 ?? Int.max }
        var front = 0
        for i in key.indices where key[i] < key[front] { front = i }
        var start = front, end = front
        while end - start + 1 < count {
            let before = start > 0 ? key[start - 1] : nil
            let after = end < n - 1 ? key[end + 1] : nil
            switch (before, after) {
            case let (b?, a?): if a <= b { end += 1 } else { start -= 1 }
            case (_?, nil): start -= 1
            default: end += 1
            }
        }
        return start...end
    }
}

private extension PaneLayout {
    struct Engine<V: NSView & Codable & Identifiable> where V.ID: Hashable {
        typealias Node = SplitTree<V>.Node

        let metrics: Metrics
        let rank: (V) -> Int?
        let pin: (Set<V.ID>) -> Pin?
        let shares: (Set<V.ID>) -> [CGFloat]?
        var result = Result<V>()
        /// The elevation of the card being laid out, in each stack it is in.
        var elevation: [Int] = []

        init(
            metrics: Metrics,
            rank: @escaping (V) -> Int?,
            pin: @escaping (Set<V.ID>) -> Pin?,
            shares: @escaping (Set<V.ID>) -> [CGFloat]?
        ) {
            self.metrics = metrics
            self.rank = rank
            self.pin = pin
            self.shares = shares
        }

        // MARK: Sizes

        func minimum(along d: Direction) -> CGFloat {
            d == .horizontal ? metrics.minimumPaneSize.width : metrics.minimumPaneSize.height
        }

        /// The items of the same-direction chain rooted at `node`, with each
        /// one's share of the chain.
        func items(_ node: Node, along d: Direction, share: CGFloat = 1) -> [(node: Node, share: CGFloat)] {
            if case .split(let split) = node, split.direction.layoutDirection == d {
                let ratio = CGFloat(split.ratio)
                return items(split.left, along: d, share: share * ratio)
                    + items(split.right, along: d, share: share * (1 - ratio))
            }
            return [(node, share)]
        }

        /// The smallest extent along `d` that shows every pane of `node` side by
        /// side at its minimum.
        func comfortable(_ node: Node, along d: Direction) -> CGFloat {
            guard case .split(let split) = node else { return minimum(along: d) }
            if split.direction.layoutDirection == d {
                let row = items(node, along: d)
                if let pin = pinned(row.map(\.node)) {
                    // Collapsed by the user: its run of cards, and slivers.
                    let card = row.map { compact($0.node, along: d) }.max() ?? 0
                    return card * CGFloat(pin.count) + metrics.gap * CGFloat(pin.count - 1)
                        + metrics.peek * CGFloat(row.count - pin.count)
                }
                return row.reduce(0) { $0 + comfortable($1.node, along: d) }
                    + metrics.gap * CGFloat(row.count - 1)
            }
            return Swift.max(comfortable(split.left, along: d), comfortable(split.right, along: d))
        }

        /// The smallest extent along `d` that `node` fits in when its rows may stack.
        func compact(_ node: Node, along d: Direction) -> CGFloat {
            guard case .split(let split) = node else { return minimum(along: d) }
            if split.direction.layoutDirection == d {
                let row = items(node, along: d)
                let widest = row.map { compact($0.node, along: d) }.max() ?? 0
                return widest + metrics.peek * CGFloat(row.count - 1)
            }
            return Swift.max(compact(split.left, along: d), compact(split.right, along: d))
        }

        /// The row's ids, item by item.
        func ids(_ row: [Node]) -> [[V.ID]] {
            row.map { $0.leaves().map(\.id) }
        }

        /// The pin of a row the user collapsed, if it still collapses it.
        func pinned(_ row: [Node]) -> Pin? {
            guard row.count > 1, let pin = pin(Set(ids(row).joined())), pin.count < row.count else { return nil }
            return Pin(start: Swift.min(Swift.max(pin.start, 0), row.count - pin.count), count: Swift.max(1, pin.count))
        }

        // MARK: Layout

        @discardableResult
        mutating func layout(_ node: Node, in rect: CGRect, tucked: Bool, clip: CGRect?) -> Node {
            switch node {
            case .leaf(let view):
                result.leaves[view.id] = Leaf(
                    frame: rect.integral(),
                    isTucked: tucked,
                    tab: nil,
                    tabAxis: nil,
                    elevation: elevation,
                    clip: clip)
                return node

            case .split(let split):
                let d = split.direction.layoutDirection
                let row = items(node, along: d)
                let extent = d == .horizontal ? rect.width : rect.height
                let gaps = metrics.gap * CGFloat(row.count - 1)
                let comfortableTotal = row.reduce(0) { $0 + comfortable($1.node, along: d) } + gaps
                let compactTotal = row.reduce(0) { $0 + compact($1.node, along: d) } + gaps

                if pinned(row.map(\.node)) == nil, comfortableTotal <= extent || compactTotal <= extent {
                    // Side by side. Prefer every pane at full size; only when
                    // that can't fit may a nested row give way and stack.
                    let minimums = row.map {
                        comfortableTotal <= extent ? comfortable($0.node, along: d) : compact($0.node, along: d)
                    }
                    let available = extent - gaps
                    let sizes = PaneLayout.waterFill(
                        row.map { $0.share * available }, minimums: minimums, available: available)
                    var spans: [CGRect] = []
                    var offset: CGFloat = 0
                    for size in sizes {
                        spans.append(rect.span(along: d, from: offset, length: size))
                        offset += size + metrics.gap
                    }
                    var index = 0
                    let shown = Row(items: ids(row.map(\.node)), run: 0...(row.count - 1), sizes: sizes)
                    return layoutChain(node, along: d, spans: spans, index: &index, row: shown,
                                       tucked: tucked, clip: clip).node
                } else {
                    let fitsSideBySide = comfortableTotal <= extent || compactTotal <= extent
                    var laidOut = layoutStack(row.map(\.node), in: rect, along: d, tucked: tucked, clip: clip,
                                              fitsSideBySide: fitsSideBySide)
                    return rebuilding(node, along: d, items: &laidOut)
                }
            }
        }

        /// Walk the binary chain of a side-by-side row, laying each item out in
        /// its span and recording a divider for every split in the chain.
        /// Returns the frame the chain node covers, and the node with the ratios
        /// it was laid out at.
        mutating func layoutChain(
            _ node: Node, along d: Direction, spans: [CGRect], index: inout Int,
            row: Row<V.ID>, tucked: Bool, clip: CGRect?
        ) -> (frame: CGRect, node: Node) {
            guard case .split(let split) = node, split.direction.layoutDirection == d else {
                let span = spans[index]
                index += 1
                return (span, layout(node, in: span, tucked: tucked, clip: clip))
            }
            let left = layoutChain(split.left, along: d, spans: spans, index: &index, row: row, tucked: tucked, clip: clip)
            let before = index
            let right = layoutChain(split.right, along: d, spans: spans, index: &index, row: row, tucked: tucked, clip: clip)
            let frame = left.frame.union(right.frame)
            let centre = d == .horizontal
                ? (left.frame.maxX + right.frame.minX) / 2
                : (left.frame.maxY + right.frame.minY) / 2
            let start = d == .horizontal ? frame.minX : frame.minY
            let extent = d == .horizontal ? frame.width : frame.height
            let displayed = Node.split(.init(
                direction: split.direction,
                ratio: extent > 0 ? Double((centre - start) / extent) : split.ratio,
                left: left.node,
                right: right.node))
            // A tucked row's dividers are under the cards in front of it.
            if !tucked {
                result.dividers.append(.init(
                    node: displayed, direction: d, nodeFrame: frame, position: centre - start,
                    row: row, index: before))
            }
            return (frame, displayed)
        }

        /// `node`'s same-direction chain with its items replaced, in order, by
        /// `items` (consumed from the front); the chain's own ratios are kept.
        func rebuilding(_ node: Node, along d: Direction, items: inout [Node]) -> Node {
            guard case .split(let split) = node, split.direction.layoutDirection == d else {
                return items.removeFirst()
            }
            let left = rebuilding(split.left, along: d, items: &items)
            let right = rebuilding(split.right, along: d, items: &items)
            return .split(.init(direction: split.direction, ratio: split.ratio, left: left, right: right))
        }

        /// A row that doesn't fit: as many items side by side as fit, the rest
        /// tucked at either end.
        mutating func layoutStack(
            _ row: [Node], in rect: CGRect, along d: Direction, tucked: Bool, clip: CGRect?,
            fitsSideBySide: Bool
        ) -> [Node] {
            var laidOut: [Node] = []
            let n = row.count
            let extent = d == .horizontal ? rect.width : rect.height
            // No card smaller than the largest item's minimum.
            let card = row.map { compact($0, along: d) }.max() ?? minimum(along: d)
            let peek = Swift.max(Metrics.minimumPeek, Swift.min(metrics.peek, ((extent - card) / CGFloat(n - 1)).rounded(.down)))
            let pin = pinned(row)
            var fits = 1
            while fits + 1 < n,
                  CGFloat(n - fits - 1) * peek + CGFloat(fits + 1) * card + CGFloat(fits) * metrics.gap <= extent {
                fits += 1
            }
            let count = Swift.min(fits, pin?.count ?? n - 1)
            if fitsSideBySide { fits = n }
            // The run's slots: equal, or as the user sized them (`shares`), never
            // under a card's minimum. In whole points, so a card that moves to a
            // slot of the same size is not resized by rounding.
            let runSpace = (extent - CGFloat(n - count) * peek - CGFloat(count - 1) * metrics.gap).rounded(.down)
            let wanted = shares(Set(ids(row).joined())).flatMap { $0.count == count ? $0 : nil }
                ?? Array(repeating: 1 / CGFloat(count), count: count)
            var slots = PaneLayout.waterFill(
                wanted.map { $0 * runSpace },
                minimums: Array(repeating: Swift.min(card, runSpace / CGFloat(count)), count: count),
                available: runSpace
            ).map { Swift.max(1, $0.rounded(.down)) }
            slots[count - 1] = Swift.max(1, runSpace - slots.dropLast().reduce(0, +))
            let ranks = row.map { node in node.leaves().compactMap(rank).min() }
            let run: ClosedRange<Int>
            if let pin {
                // The user's run, or — in a window too small for all of it —
                // the part of it around the pane last focused there.
                let window = pin.start...(pin.start + pin.count - 1)
                let part = PaneLayout.visibleRun(ranks: Array(ranks[window]), count: count)
                run = (part.lowerBound + pin.start)...(part.upperBound + pin.start)
            } else {
                run = PaneLayout.visibleRun(ranks: ranks, count: count)
            }

            let end = d == .horizontal ? rect.maxX : rect.maxY
            let runStart = CGFloat(run.lowerBound) * peek
            /// Where slot `k` of the run starts.
            func slotStart(_ k: Int) -> CGFloat {
                runStart + slots.prefix(k).reduce(0, +) + CGFloat(k) * metrics.gap
            }
            for (i, item) in row.enumerated() {
                // A tucked card is the size of the slot it would come forward
                // into: the run's first, or its last.
                let size: CGFloat = if i < run.lowerBound {
                    slots[0]
                } else if i <= run.upperBound {
                    slots[i - run.lowerBound]
                } else {
                    slots[count - 1]
                }
                let offset: CGFloat = if i < run.lowerBound {
                    CGFloat(i) * peek
                } else if i <= run.upperBound {
                    slotStart(i - run.lowerBound)
                } else {
                    extent - CGFloat(n - i) * peek
                }
                let frame = rect.span(along: d, from: offset, length: size)
                let isTucked = !run.contains(i)
                // Past the run, cards run off the stack's far end; draw only
                // the part inside it.
                var childClip = clip
                if i > run.upperBound {
                    let u = PaneLayout.unbounded
                    let inside = d == .horizontal
                        ? CGRect(x: -u, y: -u, width: end + u, height: 2 * u)
                        : CGRect(x: -u, y: -u, width: 2 * u, height: end + u)
                    childClip = childClip.map { $0.intersection(inside) } ?? inside
                }
                // The run on top; tucked cards lower the farther out they are.
                elevation.append(i < run.lowerBound ? i : i <= run.upperBound ? 2 * n + i : 2 * n - 1 - i)
                laidOut.append(layout(item, in: frame, tucked: tucked || isTucked, clip: childClip))
                elevation.removeLast()
                guard isTucked else { continue }
                // The sliver that shows, across every pane in the card. It
                // replaces a tab from a stack nested inside the card: that one
                // is under this card's neighbours now.
                let tabSpan = rect.span(along: d, from: offset, length: Swift.min(peek, size))
                for leaf in item.leaves() {
                    guard var placed = result.leaves[leaf.id] else { continue }
                    let tab = placed.frame.intersection(tabSpan)
                    let shows = !tab.isNull && !tab.isEmpty
                    placed.tab = shows ? tab : nil
                    placed.tabAxis = shows ? d : nil
                    placed.isSliver = shows && i > run.upperBound
                    result.leaves[leaf.id] = placed
                }
            }
            let items = ids(row)
            result.stacks.append(.init(frame: rect, direction: d, items: items, run: run, fits: fits))

            // Grips, on a stack that shows: between the cards on show, and at
            // the edges of a run the user narrowed that there is room to widen.
            guard !tucked else { return laidOut }
            let shown = Row(items: items, run: run, sizes: slots)
            for k in 0..<(count - 1) {
                result.stackHandles.append(.init(
                    row: shown, direction: d, frame: rect,
                    position: slotStart(k + 1) - metrics.gap / 2, kind: .between(slot: k)))
            }
            let roomForOneMore = CGFloat(n - count - 1) * peek + CGFloat(count + 1) * card
                + CGFloat(count) * metrics.gap <= extent
            if pin != nil, roomForOneMore {
                if run.lowerBound > 0 {
                    result.stackHandles.append(.init(
                        row: shown, direction: d, frame: rect, position: runStart, kind: .expand(.leading)))
                }
                if run.upperBound < n - 1 {
                    result.stackHandles.append(.init(
                        row: shown, direction: d, frame: rect,
                        position: slotStart(count - 1) + slots[count - 1], kind: .expand(.trailing)))
                }
            }
            return laidOut
        }
    }
}

extension SplitTree.Direction {
    var layoutDirection: PaneLayout.Direction {
        switch self {
        case .horizontal: .horizontal
        case .vertical: .vertical
        }
    }
}

private extension CGRect {
    /// The slice of this rect from `offset` to `offset + length` along `d`
    /// (offsets from the rect's own leading edge), spanning it across.
    func span(along d: PaneLayout.Direction, from offset: CGFloat, length: CGFloat) -> CGRect {
        switch d {
        case .horizontal: CGRect(x: minX + offset, y: minY, width: length, height: height)
        case .vertical: CGRect(x: minX, y: minY + offset, width: width, height: length)
        }
    }

    /// Whole points, without growing past where the next pane starts the way
    /// `CGRect.integral` would.
    func integral() -> CGRect {
        CGRect(x: minX.rounded(), y: minY.rounded(),
               width: (maxX.rounded() - minX.rounded()), height: (maxY.rounded() - minY.rounded()))
    }
}

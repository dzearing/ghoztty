import AppKit

/// Stashing: taking a pane out of the LAYOUT while keeping it in the TREE.
///
/// The pane sidebar (`docs/design/pane-sidebar.md`) lists every pane in the
/// window; a stashed one sits in the sidebar instead of the grid and keeps
/// running. It stays in `root` — exactly as a pane hidden behind a zoom does —
/// so everything that walks the tree keeps seeing it (IPC targeting, session
/// close intent, close confirmation, the manifest). Only spatial work — the
/// rendered layout, divider moves, directional focus — runs on `visibleTree`,
/// which is `root` with the stashed leaves pruned and their parent splits
/// collapsed. The full tree keeps those splits, their directions, and their
/// ratios, so a restored pane comes back to exactly the slot it left.
///
/// Invariants (unit-tested in `SplitTreeStashTests`):
/// 1. While the tree is non-empty, at least one pane is visible. Stashing the
///    last visible pane is refused; a mutation that would leave only stashed
///    panes restores the top of the stash.
/// 2. `stashed` only names leaves that are in `root`.
/// 3. A zoom whose every leaf is stashed is cleared.
/// Why a stash operation was refused. Not nested in the generic `SplitTree`
/// so it stays a plain Sendable value whatever the tree's view type is.
enum SplitTreeStashError: Error, Equatable {
    /// The view is not a leaf of this tree.
    case notInTree
    /// Stashing it would leave nothing on screen.
    case lastVisiblePane
}

extension SplitTree {
    typealias StashError = SplitTreeStashError

    // MARK: Queries

    /// Whether `view` is stashed.
    func isStashed(_ view: ViewType) -> Bool {
        stashed.contains(view.id)
    }

    /// The stashed views, in sidebar order.
    var stashedViews: [ViewType] {
        guard let root else { return [] }
        return stashed.compactMap { id in
            if case .leaf(let view) = root.find(id: id) { return view }
            return nil
        }
    }

    /// The tree as it is laid out: `root` and `zoomed` with stashed leaves
    /// pruned. Its split nodes are NEW values (a pruned split is a different
    /// node), which is why ratio changes made on it are lifted back with
    /// `liftingLayout(from:)` rather than applied to `root` directly.
    var visibleTree: SplitTree {
        guard !stashed.isEmpty else { return self }
        let hidden = Set(stashed)
        let visibleRoot = root?.pruned(hiding: hidden)
        // Pruning is deterministic, so the pruned zoom is structurally the
        // node inside the pruned root that it corresponds to.
        let visibleZoom = zoomed?.pruned(hiding: hidden)
        return .init(root: visibleRoot, zoomed: visibleZoom, stashed: [])
    }

    /// The panes on screen, in reading order.
    var visibleLeaves: [ViewType] {
        visibleTree.root?.leaves() ?? []
    }

    /// Whether more than one pane is on screen — the stash-aware "is this
    /// window split", for questions about what the user can see.
    var isVisiblySplit: Bool {
        visibleTree.isSplit
    }

    // MARK: Mutations

    /// Stash `view` at `index` in the stash (default: the top). Stashing a
    /// pane that is already stashed MOVES it within the stash.
    func stashing(_ view: ViewType, at index: Int? = nil) throws -> Self {
        guard let root, root.node(view: view) != nil else { throw StashError.notInTree }

        let alreadyStashed = isStashed(view)
        if !alreadyStashed && visibleLeaves.count <= 1 {
            throw StashError.lastVisiblePane
        }

        var list = stashed.filter { $0 != view.id }
        let at = Swift.min(Swift.max(index ?? 0, 0), list.count)
        list.insert(view.id, at: at)

        // A zoom that hides every pane it shows is no zoom at all.
        var newZoomed = zoomed
        if let zoomed, zoomed.leaves().allSatisfy({ list.contains($0.id) }) {
            newZoomed = nil
        }
        return .init(root: root, zoomed: newZoomed, stashed: list)
    }

    /// Put `view` back in the layout, in the slot it left.
    func restoring(_ view: ViewType) -> Self {
        guard isStashed(view) else { return self }
        return .init(root: root, zoomed: zoomed, stashed: stashed.filter { $0 != view.id })
    }

    /// Swap a stashed pane with a visible one: `stashed` takes `visible`'s
    /// slot in the layout, and `visible` takes `stashed`'s place in the stash.
    /// The sidebar's Option-click — one-pane-at-a-time switching.
    func exchanging(stashed stashedView: ViewType, with visibleView: ViewType) throws -> Self {
        guard isStashed(stashedView), !isStashed(visibleView),
              let root,
              let stashedNode = root.node(view: stashedView),
              let visibleNode = root.node(view: visibleView)
        else { throw StashError.notInTree }
        let swapped = try swapping(stashedNode, with: visibleNode)
        let list = stashed.map { $0 == stashedView.id ? visibleView.id : $0 }
        return .init(root: swapped.root, zoomed: swapped.zoomed, stashed: list)
    }

    /// Replace the stash wholesale (session restore), keeping only ids that
    /// are leaves of this tree and never stashing every pane.
    func withStash(_ ids: [ViewType.ID]) -> Self {
        Self(root: root, zoomed: zoomed, stashed: ids).rebuilt(root: root, zoomed: zoomed)
    }

    /// The same tree with a different zoom. The stash is carried — a zoom
    /// toggle must never un-stash anything.
    func settingZoomed(_ node: Node?) -> Self {
        .init(root: root, zoomed: node, stashed: stashed)
    }

    /// Build a tree from new structure, carrying the stash forward.
    ///
    /// Every structural mutation goes through here: ids whose leaf is gone are
    /// dropped (invariant 2), and if only stashed panes would remain, the top
    /// of the stash comes back (invariant 1) — so closing the last visible
    /// pane shows the next one rather than an empty window.
    func rebuilt(root newRoot: Node?, zoomed newZoomed: Node?) -> Self {
        guard let newRoot else { return .init(root: nil, zoomed: nil, stashed: []) }
        let leaves = newRoot.leaves()
        let present = Set(leaves.map(\.id))
        var list = stashed.filter { present.contains($0) }
        if !list.isEmpty && leaves.allSatisfy({ list.contains($0.id) }) {
            list.removeFirst()
        }
        return .init(root: newRoot, zoomed: newZoomed, stashed: list)
    }

    // MARK: Layout on the visible tree

    /// Apply a RATIO-ONLY transform (divider move, resize, equalize) to the
    /// visible tree and lift the result back onto the full tree.
    ///
    /// A transform that changed the visible tree's shape (rather than its
    /// ratios) can't be mapped back and is ignored — the full tree is
    /// returned unchanged. Structural edits go through the full tree.
    func applyingToVisible(_ transform: (SplitTree) throws -> SplitTree) rethrows -> SplitTree {
        let visible = visibleTree
        let result = try transform(visible)
        guard stashed.isEmpty == false else { return result }
        guard let before = visible.root, let after = result.root,
              before.hasSameShape(as: after) else { return self }
        return liftingLayout(from: result)
    }

    /// Copy every visible split's ratio back to the full-tree split it came
    /// from, and carry a cleared zoom.
    ///
    /// Each split of the visible tree corresponds to exactly one split of the
    /// full tree: the one whose two sides both still hold a visible leaf.
    /// Splits with a fully stashed side were collapsed away and keep their
    /// ratio, which is what restores a pane to the exact size it left.
    func liftingLayout(from visible: SplitTree) -> SplitTree {
        guard let root else { return self }
        let hidden = Set(stashed)
        let newRoot = root.liftingRatios(from: visible.root, hiding: hidden)
        let newZoomed: Node? = visible.zoomed == nil
            ? nil
            : zoomed.flatMap { root.path(to: $0) }.flatMap { newRoot.node(at: $0) }
        return .init(root: newRoot, zoomed: newZoomed, stashed: stashed)
    }
}

extension SplitTree.Node {
    /// This subtree with every leaf in `hidden` removed and the splits they
    /// leave one-sided collapsed into their surviving child. Nil when every
    /// leaf is hidden.
    func pruned(hiding hidden: Set<ViewType.ID>) -> Self? {
        switch self {
        case .leaf(let view):
            return hidden.contains(view.id) ? nil : self
        case .split(let split):
            let left = split.left.pruned(hiding: hidden)
            let right = split.right.pruned(hiding: hidden)
            switch (left, right) {
            case let (left?, right?):
                return .split(.init(
                    direction: split.direction, ratio: split.ratio, left: left, right: right))
            case let (left?, nil): return left
            case let (nil, right?): return right
            case (nil, nil): return nil
            }
        }
    }

    /// The inverse of `pruned`: this full subtree with the ratios of the
    /// matching visible splits copied in. See `SplitTree.liftingLayout(from:)`.
    func liftingRatios(from visible: Self?, hiding hidden: Set<ViewType.ID>) -> Self {
        guard case .split(let split) = self, let visible else { return self }
        let leftVisible = split.left.pruned(hiding: hidden) != nil
        let rightVisible = split.right.pruned(hiding: hidden) != nil

        switch (leftVisible, rightVisible) {
        case (true, true):
            // Both sides visible: this split IS a visible split.
            guard case .split(let visibleSplit) = visible else { return self }
            return .split(.init(
                direction: split.direction,
                ratio: visibleSplit.ratio,
                left: split.left.liftingRatios(from: visibleSplit.left, hiding: hidden),
                right: split.right.liftingRatios(from: visibleSplit.right, hiding: hidden)))
        case (true, false):
            // Collapsed into its left side: the visible node IS that side.
            return .split(.init(
                direction: split.direction, ratio: split.ratio,
                left: split.left.liftingRatios(from: visible, hiding: hidden),
                right: split.right))
        case (false, true):
            return .split(.init(
                direction: split.direction, ratio: split.ratio,
                left: split.left,
                right: split.right.liftingRatios(from: visible, hiding: hidden)))
        case (false, false):
            return self
        }
    }

    /// Same splits, directions, and leaves in the same places — ratios aside.
    func hasSameShape(as other: Self) -> Bool {
        switch (self, other) {
        case let (.leaf(a), .leaf(b)):
            return a === b
        case let (.split(a), .split(b)):
            return a.direction == b.direction
                && a.left.hasSameShape(as: b.left)
                && a.right.hasSameShape(as: b.right)
        default:
            return false
        }
    }
}

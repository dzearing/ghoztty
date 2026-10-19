import Foundation

/// What decides which panes of a stacked row are on show (`PaneLayout`):
/// the window's pane focus history, and the rows the user collapsed.
///
/// Bringing a tucked pane forward is not an operation of its own: it is
/// FOCUSING the pane, however that happens (a click on its tab, `goto_split`,
/// the pane sidebar, `ghoztty://focus/…`), and the row slides to show it. A row
/// the user is not working in keeps showing the panes they last looked at
/// there, because those are still the most recent of its panes.
///
/// Ephemeral: a relaunch starts from the focused pane, like the window does,
/// with every row side by side again where it fits.
final class PaneStackState: ObservableObject {
    /// Pane ids, most recently focused first.
    @Published private(set) var recency: [UUID] = []

    /// Rows the user collapsed, by the set of panes in each. A set, not the
    /// row's order, so swapping two of its panes keeps the row collapsed.
    @Published private(set) var pins: [Set<UUID>: PaneLayout.Pin] = [:]

    /// How the user sized the slots of a stacked row's run, as shares of it,
    /// by the row's panes. Ignored when the run has a different number of
    /// slots (the window grew or shrank past a card).
    @Published private(set) var shares: [Set<UUID>: [CGFloat]] = [:]

    /// Each pinned row's items in order, so a focus change knows which way to
    /// slide it. Kept by the layout, which is what knows the order.
    private var pinnedItems: [Set<UUID>: [[UUID]]] = [:]

    /// How many panes are remembered: far more than a window can hold.
    static let capacity = 64

    func noteFocus(_ id: UUID) {
        bringOnShow(id, in: Array(pinnedItems.keys))
        guard recency.first != id else { return }
        recency = Self.noting(id, in: recency)
    }

    /// A pane minimized in a collapsed row (one of `keys`) comes back: the
    /// run grows to take it in, sharing the space out evenly, and only when
    /// that won't fit does a pane on the far edge minimize to make room. A
    /// pane already in the run stays put, even when the window is too small
    /// to show all of it: the layout shows the part around the focus.
    private func bringOnShow(_ id: UUID, in keys: [Set<UUID>]) {
        for key in keys where key.contains(id) {
            guard let pin = pins[key], let items = pinnedItems[key],
                  let index = items.firstIndex(where: { $0.contains(id) }),
                  !(pin.start..<(pin.start + pin.count)).contains(index)
            else { continue }
            let restored = pin.restoring(index, fits: capacity[key] ?? pin.count, of: items.count)
            if restored?.count != pin.count { shares[key] = nil }
            pins[key] = restored
            if restored == nil { pinnedItems[key] = nil }
        }
    }

    /// 0 for the focused pane, 1 for the one before it, …; nil if never focused.
    func rank(of id: UUID) -> Int? {
        recency.firstIndex(of: id)
    }

    func pin(for row: Set<UUID>) -> PaneLayout.Pin? {
        pins[row]
    }

    /// Collapse or widen a row (a divider or stack grip dragged).
    func restack(_ row: PaneLayout.Row<UUID>, _ change: PaneLayout.Restack) {
        let key = row.key
        // Rows nest (a column is one item of the row beside it), and each
        // keeps its own collapse. A row that only partly overlaps this one
        // is one its panes have left: that pin is stale.
        for other in pins.keys where !other.isDisjoint(with: key)
            && !other.isSubset(of: key) && !other.isSuperset(of: key) {
            pins[other] = nil
            pinnedItems[other] = nil
        }
        pins[key] = PaneLayout.Pin.restacking(row.run, of: row.items.count, change)
        pinnedItems[key] = pins[key] == nil ? nil : row.items
        // The panes still on show keep the sizes they had; a pane coming back
        // gets an average slot.
        shares[key] = pins[key] == nil ? nil : Self.shares(row.sizes, change)
    }

    /// One row's collapse and slot sizes, as a drag found them: every step
    /// of the drag is replayed from this, so dragging back undoes what
    /// dragging forward did.
    struct Snapshot {
        fileprivate let pin: PaneLayout.Pin?
        fileprivate let shares: [CGFloat]?
        fileprivate let items: [[UUID]]?
    }

    func snapshot(_ row: Set<UUID>) -> Snapshot {
        Snapshot(pin: pins[row], shares: shares[row], items: pinnedItems[row])
    }

    func restore(_ row: Set<UUID>, _ snapshot: Snapshot) {
        if pins[row] != snapshot.pin { pins[row] = snapshot.pin }
        if shares[row] != snapshot.shares { shares[row] = snapshot.shares }
        pinnedItems[row] = snapshot.items
    }

    /// A drag on a divider or stack grip is under way. Cards move faster while
    /// one is: the hand is already moving, and the layout should keep up.
    var isGesturing = false

    /// Set how a stacked row's run is divided (a grip between cards dragged).
    func resize(_ row: PaneLayout.Row<UUID>, shares new: [CGFloat]) {
        shares[row.key] = new
    }

    static func shares(_ sizes: [CGFloat], _ change: PaneLayout.Restack) -> [CGFloat]? {
        guard !sizes.isEmpty else { return nil }
        var sizes = sizes
        switch change {
        case .collapse(.leading) where sizes.count > 1: sizes.removeFirst()
        case .collapse(.trailing) where sizes.count > 1: sizes.removeLast()
        case .collapse: break
        case .expand(.leading): sizes.insert(sizes.reduce(0, +) / CGFloat(sizes.count), at: 0)
        case .expand(.trailing): sizes.append(sizes.reduce(0, +) / CGFloat(sizes.count))
        }
        let total = sizes.reduce(0, +)
        return total > 0 ? sizes.map { $0 / total } : nil
    }

    /// How many items of each pinned row fit on show at once, as last laid out.
    private var capacity: [Set<UUID>: Int] = [:]

    /// The layout's current order of a pinned row's items, and how many of
    /// them fit on show.
    func noteItems(_ items: [[UUID]], fits: Int) {
        let key = Set(items.joined())
        guard pins[key] != nil else { return }
        if pinnedItems[key] != items { pinnedItems[key] = items }
        capacity[key] = fits
    }

    /// The window's rows changed, from `old` to `new` (`PaneLayout.rows`).
    /// Adding or removing a pane never brings a collapsed row's minimized
    /// panes back out. A row that panes left — closed, stashed, moved out of
    /// it — stays collapsed without them (`Pin.removing`): the panes still on
    /// show take the space. A row that panes joined — a split, a drop, a
    /// restore — stays collapsed with them (`Pin.adding`): one that lands
    /// beside the panes on show is on show too (the layout shows as many of
    /// the run as fit, the focused one first), and one among the minimized
    /// ones is minimized with them until it is focused. A row whose items
    /// are not the row the user collapsed any more (a column that emptied to
    /// one pane, merging what was in it into the row around it) lays out
    /// afresh.
    ///
    /// The collapse under the row's old panes is kept, so an undone close or
    /// a restored stash brings the row back as it was: a row that already
    /// has a collapse of its own keeps it when panes join it.
    func rowsDidChange(from old: [[[UUID]]], to new: [[[UUID]]]) {
        let carried = Self.carried(pins, shares, pinnedItems, from: old, to: new)
        for (key, row) in carried {
            if pins[key] != row.pin { pins[key] = row.pin }
            if shares[key] != row.shares { shares[key] = row.shares }
            pinnedItems[key] = row.pin == nil ? nil : row.items
            capacity[key] = row.pin == nil ? nil : capacity[row.from]
        }
        // A focus change slides only rows on screen (the layout notes them
        // again as it lays them out).
        let keys = Set(new.map { Set($0.joined()) })
        for key in pinnedItems.keys where !keys.contains(key) { pinnedItems[key] = nil }
        // The focus can land before the tree change is seen (a pane focused
        // as it joins a row): it comes on show as it would have after.
        if let focused = recency.first { bringOnShow(focused, in: Array(carried.keys)) }
    }

    /// Where the caret goes when the rows change from `old` to `new` (a
    /// close): `candidate`, unless that is minimized in a row left collapsed,
    /// in which case the pane on show there nearest it, last focused first.
    /// Focusing a minimized pane would bring it back out.
    func paneOnShow(instead candidate: UUID, from old: [[[UUID]]], to new: [[[UUID]]]) -> UUID {
        let carried = Self.carried(pins, shares, pinnedItems, from: old, to: new)
        var id = candidate
        for row in new {
            let key = Set(row.joined())
            guard let pin = carried[key].map({ $0.pin }) ?? pins[key],
                  let index = row.firstIndex(where: { $0.contains(id) })
            else { continue }
            let target = Swift.min(Swift.max(index, pin.start), pin.start + pin.count - 1)
            guard target != index else { continue }
            id = row[target].min { (rank(of: $0) ?? .max) < (rank(of: $1) ?? .max) } ?? id
        }
        return id
    }

    /// A collapse `rowsDidChange` carries over: the new pin, slot sizes and
    /// items, and the row it came from.
    private typealias Carried = (pin: PaneLayout.Pin?, shares: [CGFloat]?, items: [[UUID]], from: Set<UUID>)

    /// The collapses `rowsDidChange` carries over, by the new row's panes:
    /// for each collapsed row, the row it became — the same items with some
    /// gone, some joined, or in a new order.
    private static func carried(
        _ pins: [Set<UUID>: PaneLayout.Pin],
        _ shares: [Set<UUID>: [CGFloat]],
        _ orders: [Set<UUID>: [[UUID]]],
        from old: [[[UUID]]],
        to new: [[[UUID]]]
    ) -> [Set<UUID>: Carried] {
        let newKeys = Set(new.map { Set($0.joined()) })
        var result: [Set<UUID>: Carried] = [:]
        for items in old {
            let key = Set(items.joined())
            guard let pin = pins[key] else { continue }
            for row in new {
                guard let origin = Self.origin(of: row, in: items, order: orders[key], newKeys: newKeys, pinned: pins)
                else { continue }
                let carried = pin.carrying(origin)
                // The slots on show keep their sizes when they are the same
                // slots; a slot that joined the run shares it out evenly.
                let sizes: [CGFloat]? = carried.flatMap { carried in
                    guard let old = shares[key], old.count == pin.count else { return nil }
                    let slots = (carried.start..<(carried.start + carried.count))
                        .compactMap { origin[$0].map { $0 - pin.start } }
                        .filter(old.indices.contains)
                    guard slots.count == carried.count else { return nil }
                    let sizes = slots.map { old[$0] }
                    let total = sizes.reduce(0, +)
                    return sizes.count > 1 && total > 0 ? sizes.map { $0 / total } : nil
                }
                result[Set(row.joined())] = (carried, sizes, row, key)
                break
            }
        }
        return result
    }

    /// Each of `row`'s items' index in `items`, a collapsed row before the
    /// change, or nil for an item that joined it — when `row` is what became
    /// of `items`: its panes a strict subset or superset of theirs with every
    /// item they share intact and in order, or the same items reordered. Nil
    /// when it is some other row. A row that gained panes and already has a
    /// collapse of its own (`pinned`) keeps that one.
    ///
    /// A reorder is measured from `order`, the order the collapse was last
    /// laid out in, not from `items`: a swap (`swap(_:_:)`) trades the two
    /// panes there before the tree changes, because the panes on show are
    /// the slots, not the panes. A pane moved within the row is followed.
    private static func origin(
        of row: [[UUID]], in items: [[UUID]], order: [[UUID]]?,
        newKeys: Set<Set<UUID>>, pinned: [Set<UUID>: PaneLayout.Pin]
    ) -> [Int?]? {
        let key = Set(items.joined()), rowKey = Set(row.joined())
        if rowKey == key {
            // Reordered: the same items, in another order.
            guard let order else { return nil }
            let before = order.map(Set.init), after = row.map(Set.init)
            guard before != after, Set(before) == Set(after), before.count == after.count else { return nil }
            return after.map { before.firstIndex(of: $0) }
        }
        // The row itself is still there: it is not what this one became.
        guard !newKeys.contains(key) else { return nil }
        let grew = rowKey.isStrictSuperset(of: key)
        guard rowKey.isStrictSubset(of: key) || (grew && pinned[rowKey] == nil) else { return nil }
        let common = key.intersection(rowKey)
        let left = items.map { $0.filter(common.contains) }
        let right = row.map { $0.filter(common.contains) }
        guard left.filter({ !$0.isEmpty }) == right.filter({ !$0.isEmpty }) else { return nil }
        var kept = left.indices.filter { !left[$0].isEmpty }.makeIterator()
        return right.map { $0.isEmpty ? nil : kept.next() }
    }

    /// Two panes traded places (a rearrange swap): a collapsed row keeps its
    /// shape with the other pane in it, wherever that came from.
    func swap(_ a: UUID, _ b: UUID) {
        func traded(_ id: UUID) -> UUID { id == a ? b : id == b ? a : id }
        var newPins: [Set<UUID>: PaneLayout.Pin] = [:]
        var newItems: [Set<UUID>: [[UUID]]] = [:]
        for (key, pin) in pins {
            let rekeyed = Set(key.map(traded))
            newPins[rekeyed] = pin
            newItems[rekeyed] = pinnedItems[key]?.map { $0.map(traded) }
        }
        pins = newPins
        pinnedItems = newItems
        shares = Dictionary(uniqueKeysWithValues: shares.map { (Set($0.key.map(traded)), $0.value) })
    }

    static func noting(_ id: UUID, in recency: [UUID]) -> [UUID] {
        Array(([id] + recency.filter { $0 != id }).prefix(capacity))
    }
}

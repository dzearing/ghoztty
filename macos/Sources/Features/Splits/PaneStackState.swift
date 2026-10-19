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
        // A pane minimized in a collapsed row comes back: the run grows to
        // take it in, sharing the space out evenly, and only when that won't
        // fit does a pane on the far edge minimize to make room.
        for (key, items) in pinnedItems where key.contains(id) {
            guard let pin = pins[key], let index = items.firstIndex(where: { $0.contains(id) }) else { continue }
            let restored = pin.restoring(index, fits: capacity[key] ?? pin.count, of: items.count)
            guard restored != pin else { continue }
            if restored?.count != pin.count { shares[key] = nil }
            pins[key] = restored
            if restored == nil { pinnedItems[key] = nil }
        }
        guard recency.first != id else { return }
        recency = Self.noting(id, in: recency)
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

    /// The window's rows changed, from `old` to `new` (`PaneLayout.rows`). A
    /// collapsed row that panes left — closed, stashed, moved out of it —
    /// stays collapsed without them (`Pin.removing`): the panes still on
    /// show take the space, and the minimized ones stay minimized. A row
    /// whose remaining items are not a row of their own any more (a column
    /// that emptied to one pane, merging what was in it into the row around
    /// it) is not the row the user collapsed, and lays out afresh.
    ///
    /// The collapse under the row's old panes is kept, so an undone close or
    /// a restored stash brings the row back as it was.
    func rowsDidChange(from old: [[[UUID]]], to new: [[[UUID]]]) {
        for (key, carried) in Self.carried(pins, shares, from: old, to: new) {
            if pins[key] != carried.pin { pins[key] = carried.pin }
            if shares[key] != carried.shares { shares[key] = carried.shares }
            pinnedItems[key] = carried.pin == nil ? nil : carried.items
        }
        // A focus change slides only rows on screen (the layout notes them
        // again as it lays them out).
        let keys = Set(new.map { Set($0.joined()) })
        for key in pinnedItems.keys where !keys.contains(key) { pinnedItems[key] = nil }
    }

    /// Where the caret goes when the rows change from `old` to `new` (a
    /// close): `candidate`, unless that is minimized in a row left collapsed,
    /// in which case the pane on show there nearest it, last focused first.
    /// Focusing a minimized pane would bring it back out.
    func paneOnShow(instead candidate: UUID, from old: [[[UUID]]], to new: [[[UUID]]]) -> UUID {
        let carried = Self.carried(pins, shares, from: old, to: new)
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

    /// The collapses `rowsDidChange` carries over, by the new row's panes.
    private static func carried(
        _ pins: [Set<UUID>: PaneLayout.Pin],
        _ shares: [Set<UUID>: [CGFloat]],
        from old: [[[UUID]]],
        to new: [[[UUID]]]
    ) -> [Set<UUID>: (pin: PaneLayout.Pin?, shares: [CGFloat]?, items: [[UUID]])] {
        let newKeys = Set(new.map { Set($0.joined()) })
        var result: [Set<UUID>: (pin: PaneLayout.Pin?, shares: [CGFloat]?, items: [[UUID]])] = [:]
        for items in old {
            let key = Set(items.joined())
            guard let pin = pins[key], !newKeys.contains(key) else { continue }
            // The row it became: what is left of it, item for item.
            for row in new {
                let rowKey = Set(row.joined())
                guard rowKey.isStrictSubset(of: key) else { continue }
                let left = items.map { $0.filter(rowKey.contains) }
                guard left.filter({ !$0.isEmpty }) == row else { continue }
                let removed = Set(left.indices.filter { left[$0].isEmpty })
                let carried = pin.removing(removed, of: items.count)
                // The slots still on show keep their sizes.
                var sizes = shares[key].flatMap { $0.count == pin.count ? $0 : nil }
                sizes = sizes.map { sizes in
                    sizes.indices.filter { !removed.contains(pin.start + $0) }.map { sizes[$0] }
                }
                let total = sizes?.reduce(0, +) ?? 0
                let kept = sizes.flatMap { sizes in
                    sizes.count == carried?.count && sizes.count > 1 && total > 0 ? sizes.map { $0 / total } : nil
                }
                result[rowKey] = (carried, kept, row)
                break
            }
        }
        return result
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

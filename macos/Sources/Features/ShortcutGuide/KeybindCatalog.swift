import Foundation
import GhosttyKit

/// One effective binding as libghostty reports it
/// (`ghostty_config_keybinds_json`, `src/config/keybind_list.zig`).
struct KeybindEntry: Decodable, Hashable {
    let trigger: String
    let action: String
    let actionKey: String
    let chain: [String]
    let table: String
    let global: Bool
    let all: Bool
    let consumed: Bool
    let performable: Bool

    enum CodingKeys: String, CodingKey {
        case trigger, action, chain, table, global, all, consumed, performable
        case actionKey = "action_key"
    }

    init(
        trigger: String, action: String, actionKey: String? = nil, chain: [String] = [], table: String = "",
        global: Bool = false, all: Bool = false, consumed: Bool = true, performable: Bool = false
    ) {
        self.trigger = trigger
        self.action = action
        self.actionKey = actionKey ?? String(action.split(separator: ":", maxSplits: 1).first ?? "")
        self.chain = chain
        self.table = table
        self.global = global
        self.all = all
        self.consumed = consumed
        self.performable = performable
    }

    // Readers tolerate absent fields (the JSON is additive across versions).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let action = try c.decode(String.self, forKey: .action)
        self.init(
            trigger: try c.decode(String.self, forKey: .trigger),
            action: action,
            actionKey: try c.decodeIfPresent(String.self, forKey: .actionKey),
            chain: try c.decodeIfPresent([String].self, forKey: .chain) ?? [],
            table: try c.decodeIfPresent(String.self, forKey: .table) ?? "",
            global: try c.decodeIfPresent(Bool.self, forKey: .global) ?? false,
            all: try c.decodeIfPresent(Bool.self, forKey: .all) ?? false,
            consumed: try c.decodeIfPresent(Bool.self, forKey: .consumed) ?? true,
            performable: try c.decodeIfPresent(Bool.self, forKey: .performable) ?? false)
    }

    /// The argument after the action tag (`right` in `new_split:right`).
    var argument: String {
        guard let idx = action.firstIndex(of: ":") else { return "" }
        return String(action[action.index(after: idx)...])
    }
}

/// A binding as the guide shows it: a parsed trigger plus the flags worth a label.
struct ShortcutBinding: Hashable, Identifiable {
    let trigger: KeyTrigger
    let isGlobal: Bool
    let isAll: Bool
    /// Key table name; empty for the root set.
    let table: String
    /// Further actions this binding runs (`chain=`), canonical form.
    let chain: [String]
    /// When several actions share these modifiers and differ only by key, the
    /// row draws `modifiers + keys` (⌥⌘ + ↑↓←→) instead of one chord.
    let familyKeys: [String]?

    var id: String { "\(table)/\(trigger.canonical)/\(familyKeys?.joined(separator: "|") ?? "")" }
}

/// One row of the guide.
struct ShortcutRow: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A config keybind action.
        case keybind
        /// Several actions of one family collapsed into a row (⌘1…⌘8).
        case family
        /// A fixed key owned by a pane type or mode; not configurable.
        case builtIn
    }

    let id: String
    let kind: Kind
    /// Canonical action strings this row stands for (one, except families).
    let actions: [String]
    let actionKey: String
    let category: ShortcutCategory
    let title: String
    let detail: String
    let bindings: [ShortcutBinding]
    /// Bindings differ from the defaults (added, changed or removed).
    let isCustomized: Bool
    /// A default binding the user's config removed, leaving none.
    let isUnboundByUser: Bool
    /// No curated descriptor: shown with its raw action name.
    let isUncurated: Bool
    /// Safe to run from the guide with one click.
    let isRunnable: Bool

    var action: String { actions.first ?? "" }
    var isBound: Bool { !bindings.isEmpty }
    var isGlobal: Bool { bindings.contains(where: \.isGlobal) }
    var tables: [String] { Array(Set(bindings.map(\.table).filter { !$0.isEmpty })).sorted() }
}

/// Every keyboard shortcut Ghoztty knows, as the guide (and the Settings
/// window's Keyboard page) show them: the live config's effective bindings,
/// compared against the defaults, described by `ShortcutDescriptors`.
///
/// Pure and UI-free: build it from entry lists (tests) or from a
/// `ghostty_config_t` (`init(config:)`).
struct KeybindCatalog {
    /// Every row: bound actions, unbound-but-listable actions, built-ins.
    /// Families are expanded; `rows(groupingFamilies:)` collapses them.
    let allRows: [ShortcutRow]
    /// Every action tag libghostty knows (`ghostty_input_action_keys`).
    let actionKeys: [String]

    /// Actions that the config binds, in config order, with their entries.
    let effective: [KeybindEntry]
    let defaults: [KeybindEntry]

    init(effective: [KeybindEntry], defaults: [KeybindEntry], actionKeys: [String]) {
        self.effective = effective
        self.defaults = defaults
        self.actionKeys = actionKeys
        self.allRows = Self.buildRows(effective: effective, defaults: defaults, actionKeys: actionKeys)
    }

    /// The live catalog for `config`. "Customized" is measured against a
    /// freshly built default config.
    init(config: ghostty_config_t) {
        let defaultConfig = ghostty_config_new()
        defer { if let defaultConfig { ghostty_config_free(defaultConfig) } }
        if let defaultConfig { ghostty_config_finalize(defaultConfig) }
        self.init(
            effective: Self.entries(of: config),
            defaults: defaultConfig.map(Self.entries(of:)) ?? [],
            actionKeys: Self.libraryActionKeys())
    }

    static func entries(of config: ghostty_config_t) -> [KeybindEntry] {
        let json = Ghostty.AllocatedString(ghostty_config_keybinds_json(config)).string
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([KeybindEntry].self, from: data)) ?? []
    }

    static func libraryActionKeys() -> [String] {
        guard let ptr = ghostty_input_action_keys() else { return [] }
        return String(cString: ptr).split(separator: "\n").map(String.init)
    }

    // MARK: Queries

    /// Rows for display. With `groupingFamilies` (the read-only guide),
    /// ⌘1…⌘8 and the like collapse into one row; Settings keeps them apart
    /// so each action can be edited.
    func rows(groupingFamilies: Bool = true, includeUnbound: Bool = false) -> [ShortcutRow] {
        let visible = allRows.filter { includeUnbound || $0.isBound || $0.isUnboundByUser }
        let grouped = groupingFamilies ? Self.collapseFamilies(visible) : visible
        return Self.sorted(grouped)
    }

    /// The row for one action string, if any.
    func row(forAction action: String) -> ShortcutRow? {
        allRows.first { $0.actions.contains(action) }
    }

    /// Actions bound to `trigger` (any spelling), for conflict checks.
    func actions(boundTo trigger: KeyTrigger, table: String = "") -> [String] {
        effective.filter { $0.table == table && KeyTrigger($0.trigger) == trigger }.map(\.action)
    }

    /// Whether `row` matches a search: its title, description or action
    /// name, or — for a key-combo query ("⌘D", "cmd shift p") — its keys.
    static func matches(_ row: ShortcutRow, query rawQuery: String) -> Bool {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        let haystack = ([row.title, row.detail, row.category.title] + row.actions).joined(separator: " ")
        if haystack.localizedCaseInsensitiveContains(query) { return true }
        if let combo = KeyTrigger.parseQuery(query) {
            return row.bindings.contains { binding in
                if let keys = binding.familyKeys {
                    guard Set(binding.trigger.steps.first?.modifiers ?? []) == combo.modifiers else { return false }
                    return combo.key.isEmpty || keys.contains {
                        $0 == KeyTrigger.canonicalKey(combo.key)
                            || KeyTrigger.displayName(forKey: $0).lowercased() == combo.key.lowercased()
                    }
                }
                return binding.trigger.matches(modifiers: combo.modifiers, key: combo.key)
            }
        }
        // A bare key name ("f5", "esc") with no modifier.
        return row.bindings.contains { binding in
            binding.trigger.steps.contains { step in
                step.modifiers.isEmpty && (step.key == KeyTrigger.canonicalKey(query)
                    || KeyTrigger.displayName(forKey: step.key).lowercased() == query.lowercased())
            }
        }
    }

    // MARK: Building

    private static func describe(actionKey: String, argument: String) -> (ShortcutDescriptor?, String, String) {
        guard let d = ShortcutDescriptors.all[actionKey] else {
            return (nil, actionKey, "No description yet — listed by its raw action name.")
        }
        return (d, d.title(argument), d.detail(argument))
    }

    private static func signature(_ e: KeybindEntry) -> String {
        let trigger = KeyTrigger(e.trigger)?.canonical ?? e.trigger
        return [e.table, trigger, e.chain.joined(separator: ","), e.global ? "g" : "", e.all ? "a" : "",
                e.consumed ? "" : "u", e.performable ? "p" : ""].joined(separator: "|")
    }

    private static func buildRows(
        effective: [KeybindEntry],
        defaults: [KeybindEntry],
        actionKeys: [String]
    ) -> [ShortcutRow] {
        var order: [String] = []
        var byAction: [String: [KeybindEntry]] = [:]
        for e in effective {
            if byAction[e.action] == nil { order.append(e.action) }
            byAction[e.action, default: []].append(e)
        }
        var defaultsByAction: [String: [KeybindEntry]] = [:]
        for e in defaults { defaultsByAction[e.action, default: []].append(e) }

        var rows: [ShortcutRow] = []
        var seenKeys = Set<String>()

        func makeRow(action: String, entries: [KeybindEntry]) -> ShortcutRow {
            let actionKey = entries.first?.actionKey ?? String(action.split(separator: ":").first ?? "")
            let argument = entries.first?.argument
                ?? (action.firstIndex(of: ":").map { String(action[action.index(after: $0)...]) } ?? "")
            let (descriptor, title, detail) = describe(actionKey: actionKey, argument: argument)
            let defaultEntries = defaultsByAction[action] ?? []
            let customized = Set(entries.map(signature)) != Set(defaultEntries.map(signature))

            // Collapse spellings that draw the same keycaps (super+digit_1 vs super+1).
            var seen = Set<String>()
            var bindings: [ShortcutBinding] = []
            for e in entries {
                guard let trigger = KeyTrigger(e.trigger) else { continue }
                let key = "\(e.table)/\(trigger.canonical)/\(e.global)"
                guard seen.insert(key).inserted else { continue }
                bindings.append(.init(trigger: trigger, isGlobal: e.global, isAll: e.all, table: e.table,
                                      chain: e.chain, familyKeys: nil))
            }
            return ShortcutRow(
                id: action, kind: .keybind, actions: [action], actionKey: actionKey,
                category: descriptor?.category ?? .other, title: title, detail: detail, bindings: bindings,
                isCustomized: customized, isUnboundByUser: entries.isEmpty && !defaultEntries.isEmpty,
                isUncurated: descriptor == nil,
                isRunnable: (descriptor?.runnable ?? false) && entries.allSatisfy { $0.table.isEmpty })
        }

        for action in order {
            let entries = byAction[action] ?? []
            rows.append(makeRow(action: action, entries: entries))
            seenKeys.insert(entries.first?.actionKey ?? action)
        }

        // Defaults the user's config unbound entirely.
        for (action, entries) in defaultsByAction where byAction[action] == nil {
            rows.append(makeRow(action: action, entries: []))
            seenKeys.insert(entries.first?.actionKey ?? action)
        }

        // Every other action: listed as "Not bound" when it has a sensible
        // argument-free form; uncurated ones always, so nothing disappears.
        for key in actionKeys where !seenKeys.contains(key) {
            if let descriptor = ShortcutDescriptors.all[key] {
                guard let action = descriptor.unboundAction else { continue }
                rows.append(makeRow(action: action, entries: []))
            } else {
                rows.append(makeRow(action: key, entries: []))
            }
        }

        // Built-in, non-configurable keys.
        for (index, item) in ShortcutDescriptors.builtIns.enumerated() {
            let (category, title, detail, triggers) = item
            rows.append(ShortcutRow(
                id: "builtin:\(index)", kind: .builtIn, actions: [], actionKey: "", category: category,
                title: title, detail: detail,
                bindings: triggers.compactMap(KeyTrigger.init).map {
                    .init(trigger: $0, isGlobal: false, isAll: false, table: "", chain: [], familyKeys: nil)
                },
                isCustomized: false, isUnboundByUser: false, isUncurated: false, isRunnable: false))
        }
        return rows
    }

    /// Collapses rows of one family (same action tag) whose single binding
    /// shares modifiers and differs only by key, when three or more do.
    static func collapseFamilies(_ rows: [ShortcutRow]) -> [ShortcutRow] {
        var result: [ShortcutRow] = []
        var consumed = Set<String>()
        for row in rows {
            guard !consumed.contains(row.id) else { continue }
            guard row.kind == .keybind, let family = ShortcutDescriptors.families[row.actionKey],
                  let mods = singleStepModifiers(row) else {
                result.append(row)
                continue
            }
            let members = rows.filter {
                $0.kind == .keybind && $0.actionKey == row.actionKey && singleStepModifiers($0) == mods
            }
            guard members.count >= 3 else {
                result.append(row)
                continue
            }
            members.forEach { consumed.insert($0.id) }
            let keys = members.compactMap { $0.bindings.first?.trigger.steps.first?.key }
            let trigger = KeyTrigger(steps: [KeyStep(modifiers: mods, key: keys.first ?? "")])
            result.append(ShortcutRow(
                id: "family:\(row.actionKey):\(mods.map(\.rawValue).joined(separator: "+"))",
                kind: .family, actions: members.flatMap(\.actions), actionKey: row.actionKey,
                category: row.category, title: family.title, detail: family.detail,
                bindings: [.init(trigger: trigger, isGlobal: false, isAll: false, table: "", chain: [], familyKeys: keys)],
                isCustomized: members.contains(where: \.isCustomized), isUnboundByUser: false,
                isUncurated: false, isRunnable: false))
        }
        return result
    }

    /// The modifiers of a row's only binding, when it has exactly one,
    /// single-step, root-table, non-global binding.
    private static func singleStepModifiers(_ row: ShortcutRow) -> [KeyModifier]? {
        guard row.bindings.count == 1, let b = row.bindings.first, b.table.isEmpty, !b.isGlobal,
              b.trigger.steps.count == 1 else { return nil }
        return b.trigger.steps[0].modifiers
    }

    /// Category order, then the curated order of `ShortcutDescriptors`
    /// (by the order actions appear in the defaults), built-ins last.
    private static let orderIndex = Dictionary(
        uniqueKeysWithValues: ShortcutDescriptors.order.enumerated().map { ($1, $0) })

    /// Within one action tag: directions in reading order, numbers ascending,
    /// so "Split Right" precedes "Split Down" and Tab 2 precedes Tab 10.
    private static func argumentOrder(_ row: ShortcutRow) -> String {
        let arg = row.action.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
        let rank = ["right", "down", "left", "up", "next", "previous", "auto", "this", "other", "mixed", "plain"]
        if let i = rank.firstIndex(where: { arg.hasPrefix($0) }) { return String(format: "a%02d", i) }
        if let n = Double(arg) { return String(format: "b%012.3f", n + 1_000_000) }
        return "c" + arg
    }

    private static func sorted(_ rows: [ShortcutRow]) -> [ShortcutRow] {
        let categoryIndex = Dictionary(uniqueKeysWithValues: ShortcutCategory.allCases.enumerated().map { ($1, $0) })
        return rows.enumerated().sorted { lhs, rhs in
            let (li, l) = lhs
            let (ri, r) = rhs
            if l.category != r.category { return categoryIndex[l.category]! < categoryIndex[r.category]! }
            if (l.kind == .builtIn) != (r.kind == .builtIn) { return r.kind == .builtIn }
            if l.isBound != r.isBound { return l.isBound }
            let lo = orderIndex[l.actionKey] ?? Int.max
            let ro = orderIndex[r.actionKey] ?? Int.max
            if lo != ro { return lo < ro }
            return argumentOrder(l) < argumentOrder(r) || (argumentOrder(l) == argumentOrder(r) && li < ri)
        }.map(\.1)
    }
}

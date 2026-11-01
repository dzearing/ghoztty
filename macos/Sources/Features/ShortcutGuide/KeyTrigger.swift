import Foundation

/// A keybind modifier, in the order macOS draws them (⌃⌥⇧⌘).
enum KeyModifier: String, CaseIterable, Comparable, Hashable {
    case ctrl, alt, shift, `super`

    /// The glyph macOS menus use.
    var glyph: String {
        switch self {
        case .ctrl: return "⌃"
        case .alt: return "⌥"
        case .shift: return "⇧"
        case .super: return "⌘"
        }
    }

    /// Plain-language name, for VoiceOver and search.
    var spokenName: String {
        switch self {
        case .ctrl: return "Control"
        case .alt: return "Option"
        case .shift: return "Shift"
        case .super: return "Command"
        }
    }

    /// Every spelling config (and people) use for this modifier.
    static func parse(_ raw: String) -> KeyModifier? {
        switch raw.lowercased() {
        case "ctrl", "control", "⌃": return .ctrl
        case "alt", "opt", "option", "⌥": return .alt
        case "shift", "⇧": return .shift
        case "super", "cmd", "command", "⌘": return .super
        default: return nil
        }
    }

    static func < (lhs: KeyModifier, rhs: KeyModifier) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One step of a trigger: modifiers plus a key (`super+shift+d`).
struct KeyStep: Hashable {
    let modifiers: [KeyModifier]
    /// The key as config spells it, canonicalized (see `KeyTrigger.canonicalKey`).
    let key: String

    /// The keycap labels for this step: one per modifier, then the key.
    var keycaps: [String] { modifiers.map(\.glyph) + [KeyTrigger.displayName(forKey: key)] }

    /// `⇧⌘D` — compact, menu-style.
    var display: String { modifiers.map(\.glyph).joined() + KeyTrigger.displayName(forKey: key) }

    /// `super+shift+d` — canonical spelling, modifiers in the order config
    /// itself writes them (super, ctrl, alt, shift).
    var canonical: String {
        let configOrder: [KeyModifier] = [.super, .ctrl, .alt, .shift]
        return (configOrder.filter(modifiers.contains).map(\.rawValue) + [key]).joined(separator: "+")
    }

    /// "Shift Command D" for VoiceOver.
    var spoken: String {
        (modifiers.map(\.spokenName) + [KeyTrigger.spokenName(forKey: key)]).joined(separator: " ")
    }
}

/// A parsed keybind trigger: one step, or several for a sequence (`ctrl+a>n`).
///
/// Parsing is forgiving about spelling so that two ways of writing the same
/// chord compare equal: `cmd+shift+d`, `shift+super+D` and `super+shift+d` are
/// one trigger. That equality is what the guide uses to collapse duplicates and
/// what Settings uses to detect conflicts.
struct KeyTrigger: Hashable, CustomStringConvertible {
    let steps: [KeyStep]

    init(steps: [KeyStep]) { self.steps = steps }

    /// Parses config's trigger syntax. Returns nil for an empty trigger.
    init?(_ raw: String) {
        let steps = Self.splitSequence(raw).compactMap(Self.parseStep)
        guard !steps.isEmpty else { return nil }
        self.steps = steps
    }

    /// Canonical spelling: `super+shift+d`, `ctrl+a>n`.
    var canonical: String { steps.map(\.canonical).joined(separator: ">") }

    /// Compact display: `⇧⌘D`, `⌃A N`.
    var display: String { steps.map(\.display).joined(separator: " ") }

    var description: String { canonical }

    var spoken: String { steps.map(\.spoken).joined(separator: ", then ") }

    var isSequence: Bool { steps.count > 1 }

    // MARK: Parsing

    /// Splits `ctrl+a>n` into steps. A `>` that IS the key (`super+>`,
    /// or a lone `>`) is not a separator.
    private static func splitSequence(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for ch in raw {
            if ch == ">" && !current.isEmpty && !current.hasSuffix("+") {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// Parses `super+shift+d`. A `+` that IS the key (`super++`, a lone `+`)
    /// is kept as the key.
    private static func parseStep(_ raw: String) -> KeyStep? {
        var tokens: [String] = []
        var current = ""
        for ch in raw {
            if ch == "+" && !current.isEmpty {
                tokens.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        guard let last = tokens.last else { return nil }

        var mods = Set<KeyModifier>()
        for token in tokens.dropLast() {
            // An unknown "modifier" means this isn't a chord we understand;
            // keep it visible rather than dropping it.
            guard let mod = KeyModifier.parse(token) else {
                return KeyStep(modifiers: [], key: raw.lowercased())
            }
            mods.insert(mod)
        }
        // A trailing modifier with nothing after it ("super+shift") is not a
        // trigger config accepts, but keep the modifier as the key.
        return KeyStep(modifiers: mods.sorted(), key: canonicalKey(last))
    }

    /// One spelling per key: config writes `digit_1` for the physical key and
    /// `1` for the character, `period` vs `.`, etc. They draw the same keycap,
    /// so they compare equal.
    static func canonicalKey(_ raw: String) -> String {
        let lower = raw.lowercased()
        if lower.hasPrefix("digit_"), lower.count == 7 { return String(lower.dropFirst(6)) }
        if lower.hasPrefix("numpad_") { return lower }
        return keyAliases[lower] ?? lower
    }

    private static let keyAliases: [String: String] = [
        "period": ".", "comma": ",", "slash": "/", "backslash": "\\", "minus": "-",
        "equal": "=", "semicolon": ";", "quote": "'", "backquote": "`", "grave_accent": "`",
        "bracket_left": "[", "bracket_right": "]", "plus": "+",
        "return": "enter", "esc": "escape", "up": "arrow_up", "down": "arrow_down",
        "left": "arrow_left", "right": "arrow_right", "pageup": "page_up", "pagedown": "page_down",
    ]

    // MARK: Display

    private static let displayNames: [String: String] = [
        "arrow_left": "←", "arrow_right": "→", "arrow_up": "↑", "arrow_down": "↓",
        "enter": "↩", "backspace": "⌫", "delete": "⌦", "escape": "esc", "tab": "⇥",
        "space": "Space", "page_up": "Page Up", "page_down": "Page Down", "home": "Home",
        "end": "End", "insert": "Insert", "copy": "Copy", "paste": "Paste", "cut": "Cut",
        "caps_lock": "⇪", "fn": "fn", "context_menu": "Menu", "numpad_enter": "⌤",
    ]

    private static let spokenNames: [String: String] = [
        "arrow_left": "Left Arrow", "arrow_right": "Right Arrow", "arrow_up": "Up Arrow",
        "arrow_down": "Down Arrow", "enter": "Return", "backspace": "Delete", "delete": "Forward Delete",
        "escape": "Escape", "tab": "Tab", ".": "Period", ",": "Comma", "/": "Slash", "\\": "Backslash",
        "-": "Minus", "=": "Equals", "+": "Plus", ";": "Semicolon", "'": "Quote", "`": "Backtick",
        "[": "Left Bracket", "]": "Right Bracket",
    ]

    /// The keycap label for a canonical key: `D`, `↩`, `Page Up`, `F5`.
    static func displayName(forKey key: String) -> String {
        if let name = displayNames[key] { return name }
        if key.count == 1 { return key.uppercased() }
        if key.hasPrefix("f"), Int(key.dropFirst()) != nil { return key.uppercased() }
        if key.hasPrefix("numpad_") { return "Num " + displayName(forKey: String(key.dropFirst(7))) }
        return key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func spokenName(forKey key: String) -> String {
        spokenNames[key] ?? displayName(forKey: key)
    }

    // MARK: Search

    /// Splits a search query that looks like a key combo ("⌘D", "cmd shift p",
    /// "ctrl+cmd") into modifiers and the rest. Nil when it names no modifier.
    static func parseQuery(_ query: String) -> (modifiers: Set<KeyModifier>, key: String)? {
        var mods = Set<KeyModifier>()
        var rest = ""
        // Word spellings first ("cmd shift p" / "cmd+shift+p").
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init)
        for word in words {
            if let mod = KeyModifier.parse(word) {
                mods.insert(mod)
                continue
            }
            // Glyph runs ("⇧⌘p").
            for ch in word {
                if let mod = KeyModifier.parse(String(ch)) { mods.insert(mod) } else { rest.append(ch) }
            }
        }
        guard !mods.isEmpty else { return nil }
        return (mods, rest)
    }

    /// Whether this trigger is what a key-combo query names: same modifiers
    /// on some step, and the key (if typed) matching that step's key.
    func matches(modifiers: Set<KeyModifier>, key: String) -> Bool {
        steps.contains { step in
            guard Set(step.modifiers) == modifiers else { return false }
            if key.isEmpty { return true }
            let wanted = Self.canonicalKey(key)
            return step.key == wanted
                || Self.displayName(forKey: step.key).lowercased() == key.lowercased()
        }
    }
}

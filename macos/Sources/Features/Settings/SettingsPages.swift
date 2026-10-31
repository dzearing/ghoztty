import SwiftUI

/// How the Settings window presents the schema: which keys go on which page,
/// in what order, with what label and control. This is presentation only —
/// docs, defaults, enum options and validation all come from libghostty
/// (`ConfigSchema`), and `SettingsPagesTests` fails if a key or option named
/// here drifts from `Config.zig`. Every key not curated here still appears
/// under Advanced → All Settings.
enum SettingsPageID: String, CaseIterable, Identifiable {
    case appearance, panes, terminal, keyboard, session, remote, updates, advanced
    var id: String { rawValue }
}

struct SettingsPage: Identifiable {
    let id: SettingsPageID
    let title: String
    let symbol: String
    let tint: Color
    let sections: [SettingsSection]
}

struct SettingsSection: Identifiable {
    let title: String?
    let footer: String?
    let content: Content

    enum Content {
        case rows([SettingRow])
        case custom(SettingsCustomSection)
    }

    var id: String { title ?? content.debugID }

    init(_ rows: [SettingRow]) {
        self.init(nil, footer: nil, rows)
    }

    init(_ title: String?, footer: String? = nil, _ rows: [SettingRow]) {
        self.title = title
        self.footer = footer
        self.content = .rows(rows)
    }

    init(_ title: String? = nil, footer: String? = nil, custom: SettingsCustomSection) {
        self.title = title
        self.footer = footer
        self.content = .custom(custom)
    }

    /// Keys this section edits (for search and the "changed" counts).
    var keys: [String] {
        switch content {
        case .rows(let rows): return rows.map(\.key)
        case .custom(let custom): return custom.keys
        }
    }
}

extension SettingsSection.Content {
    var debugID: String {
        switch self {
        case .rows(let rows): return rows.first?.key ?? "rows"
        case .custom(let custom): return "\(custom)"
        }
    }
}

/// Sections with their own UI.
enum SettingsCustomSection: String {
    case preview, theme, paneStyle, shortcutGuide, agentStatus, remoteMachines, version, configFile, allSettings

    var keys: [String] {
        switch self {
        case .theme: return ["theme"]
        case .paneStyle: return ["macos-pane-style"]
        default: return []
        }
    }

    /// Words search should match for a custom section.
    var searchText: String {
        switch self {
        case .preview: return "preview"
        case .theme: return "theme colors light dark mode appearance"
        case .paneStyle: return "pane style elevated flat cards"
        case .shortcutGuide: return "keyboard shortcuts keybind guide"
        case .agentStatus: return "agent session persistence status socket"
        case .remoteMachines: return "remote machines relay ssh host"
        case .version: return "version update check"
        case .configFile: return "config file open editor backup include"
        case .allSettings: return "all settings raw advanced"
        }
    }
}

struct SettingRow: Identifiable {
    enum Control {
        case toggle
        /// A popup. `options` are (value, label); schema options without a
        /// curated label are added with their raw name, so a new enum value
        /// still shows up. A "" value means "unset" (the default).
        case picker([(String, String)])
        case segmented([(String, String)])
        /// `percent` shows 0…1 as a percentage; `inverted` shows 1 − value.
        case slider(min: Double, max: Double, step: Double, percent: Bool = true, inverted: Bool = false)
        case stepper(min: Double, max: Double, step: Double, unit: String)
        /// A size in bytes shown as megabytes.
        case megabytes(max: Double)
        case color(noneLabel: String)
        case text(placeholder: String)
        case font
        /// A repeatable key's values as removable chips.
        case list(placeholder: String)
        case flags
        case shell(scripted: Bool)
        case folder
    }

    let key: String
    let label: String
    let control: Control
    /// Shown instead of the doc summary.
    var hint: String?
    /// Dim the row unless `key` has `value` (or, with `lessThan`, is below it).
    var enabledWhen: Condition?

    struct Condition {
        let key: String
        let equals: String?
        let lessThan: Double?
        let reason: String

        static func equals(_ key: String, _ value: String, _ reason: String) -> Condition {
            Condition(key: key, equals: value, lessThan: nil, reason: reason)
        }
        static func lessThan(_ key: String, _ value: Double, _ reason: String) -> Condition {
            Condition(key: key, equals: nil, lessThan: value, reason: reason)
        }
    }

    var id: String { key }

    init(_ key: String, _ label: String, _ control: Control, hint: String? = nil, enabledWhen: Condition? = nil) {
        self.key = key
        self.label = label
        self.control = control
        self.hint = hint
        self.enabledWhen = enabledWhen
    }

    /// Curated option values (for the drift test).
    var curatedOptions: [String] {
        switch control {
        case .picker(let o), .segmented(let o): return o.map(\.0).filter { !$0.isEmpty }
        default: return []
        }
    }
}

enum SettingsPages {
    static let all: [SettingsPage] = [appearance, panes, terminal, keyboard, session, remote, updates, advanced]

    static func page(_ id: SettingsPageID) -> SettingsPage { all.first { $0.id == id }! }

    /// Every key a curated page edits.
    static let curatedKeys: Set<String> = Set(all.flatMap { $0.sections.flatMap(\.keys) })

    static func pageID(for key: String) -> SettingsPageID? {
        all.first { $0.sections.contains { $0.keys.contains(key) } }?.id
    }

    // MARK: Pages

    static let appearance = SettingsPage(
        id: .appearance, title: "Appearance", symbol: "circle.lefthalf.filled", tint: .indigo,
        sections: [
            SettingsSection(custom: .preview),
            SettingsSection("Theme", custom: .theme),
            SettingsSection("Font", [
                SettingRow("font-family", "Font", .font),
                SettingRow("font-size", "Size", .stepper(min: 6, max: 72, step: 0.5, unit: "pt")),
                SettingRow("font-feature", "Font features", .list(placeholder: "-calt"),
                           hint: "OpenType features, e.g. -calt turns off ligatures, ss01 picks a stylistic set."),
                SettingRow("font-thicken", "Thicken strokes", .toggle),
                SettingRow("adjust-cell-height", "Line height adjustment", .text(placeholder: "0 or 10%")),
            ]),
            SettingsSection("Cursor", [
                SettingRow("cursor-style", "Style", .segmented([
                    ("block", "Block"), ("bar", "Bar"), ("underline", "Underline"), ("block_hollow", "Hollow"),
                ])),
                SettingRow("cursor-style-blink", "Blink", .segmented([("", "App decides"), ("true", "On"), ("false", "Off")])),
                SettingRow("cursor-color", "Color", .color(noneLabel: "Theme")),
                SettingRow("cursor-opacity", "Opacity", .slider(min: 0, max: 1, step: 0.05)),
            ]),
            SettingsSection("Window", [
                SettingRow("background-opacity", "Background opacity", .slider(min: 0, max: 1, step: 0.01)),
                SettingRow("background-blur", "Background blur", .picker([
                    ("false", "Off"), ("true", "On"), ("macos-glass-regular", "Glass"), ("macos-glass-clear", "Clear glass"),
                ]), enabledWhen: .lessThan("background-opacity", 1, "Needs a background opacity below 100%")),
                SettingRow("window-padding-x", "Horizontal padding", .stepper(min: 0, max: 80, step: 1, unit: "pt")),
                SettingRow("window-padding-y", "Vertical padding", .stepper(min: 0, max: 80, step: 1, unit: "pt")),
                SettingRow("window-padding-balance", "Balance padding", .toggle),
                SettingRow("macos-titlebar-style", "Title bar", .picker([
                    ("transparent", "Transparent"), ("native", "Native"), ("tabs", "Tabs in the title bar"), ("hidden", "Hidden"),
                ])),
                SettingRow("window-theme", "Window appearance", .picker([
                    ("auto", "Match the theme"), ("system", "Follow the system"), ("light", "Light"), ("dark", "Dark"), ("ghostty", "Ghostty"),
                ])),
            ]),
        ])

    static let panes = SettingsPage(
        id: .panes, title: "Panes & Windows", symbol: "square.split.2x1", tint: .teal,
        sections: [
            SettingsSection("Pane style", custom: .paneStyle),
            SettingsSection([
                SettingRow("macos-pane-glass", "Glass panes", .toggle,
                           enabledWhen: .equals("macos-pane-style", "elevated", "Elevated style only")),
                SettingRow("unfocused-split-opacity", "Dim unfocused panes", .slider(min: 0.15, max: 1, step: 0.05, inverted: true)),
                SettingRow("unfocused-split-fill", "Dimming color", .color(noneLabel: "Background")),
                SettingRow("split-divider-color", "Divider color", .color(noneLabel: "Automatic"),
                           enabledWhen: .equals("macos-pane-style", "flat", "Flat style only")),
            ]),
            SettingsSection("Window gradient", [
                SettingRow("macos-window-gradient", "New windows", .segmented([("random", "Random color"), ("ocean", "Ocean")]),
                           enabledWhen: .equals("macos-pane-style", "elevated", "Elevated style only")),
            ]),
            SettingsSection("Pane sidebar", [
                SettingRow("macos-pane-sidebar", "Sidebar in new windows", .picker([
                    ("remember", "Same as the last window"), ("expanded", "Expanded"), ("collapsed", "Collapsed to a rail"), ("hidden", "Hidden"),
                ])),
            ]),
            SettingsSection("Stacked panes", [
                SettingRow("macos-pane-min-width", "Stack panes narrower than", .stepper(min: 120, max: 800, step: 5, unit: "pt")),
                SettingRow("macos-pane-min-height", "Stack panes shorter than", .stepper(min: 80, max: 600, step: 5, unit: "pt")),
            ]),
            SettingsSection("Hero layout", [
                SettingRow("macos-hero-carousel-ratio", "Carousel width", .slider(min: 0.1, max: 0.6, step: 0.05)),
            ]),
            SettingsSection("New windows", [
                SettingRow("maximize", "Open windows filling the screen", .toggle),
                SettingRow("window-inherit-font-size", "Keep the current font size", .toggle),
                SettingRow("window-new-tab-position", "New tab position", .picker([("current", "After the current tab"), ("end", "At the end")])),
                SettingRow("window-save-state", "Reopen windows at launch", .picker([("default", "System default"), ("always", "Always"), ("never", "Never")])),
                SettingRow("confirm-close-surface", "Confirm before closing", .picker([
                    ("true", "When a process is running"), ("always", "Always"), ("false", "Never"),
                ])),
            ]),
        ])

    static let terminal = SettingsPage(
        id: .terminal, title: "Terminal", symbol: "terminal", tint: Color(white: 0.3),
        sections: [
            SettingsSection("Shell", [
                SettingRow("command", "Shell", .shell(scripted: false)),
                SettingRow("working-directory", "Start new windows in", .folder),
                SettingRow("window-inherit-working-directory", "New windows open in the current folder", .toggle),
                SettingRow("split-inherit-working-directory", "New panes open in the current folder", .toggle),
                SettingRow("tab-inherit-working-directory", "New tabs open in the current folder", .toggle),
                SettingRow("env", "Environment variables", .list(placeholder: "KEY=VALUE"),
                           hint: "Added to every shell, as KEY=VALUE."),
                SettingRow("command-shell", "Shell for scripted windows", .shell(scripted: true),
                           hint: "Runs the command of ghoztty +new-window --command=…, with -lic so your profile loads."),
            ]),
            SettingsSection("Scrollback", [
                SettingRow("scrollback-limit", "Scrollback size", .megabytes(max: 4096)),
                SettingRow("scrollbar", "Scroll bar", .picker([("system", "System setting"), ("never", "Never")])),
            ]),
            SettingsSection("Shell integration", [
                SettingRow("shell-integration", "Shell", .picker([
                    ("detect", "Detect automatically"), ("none", "Off"), ("bash", "bash"), ("zsh", "zsh"),
                    ("fish", "fish"), ("elvish", "elvish"), ("nushell", "nushell"),
                ])),
                SettingRow("shell-integration-features", "Features", .flags),
            ]),
            SettingsSection("Copy & paste", [
                SettingRow("copy-on-select", "Copy on select", .picker([
                    ("true", "To the selection clipboard"), ("clipboard", "To the system clipboard"), ("false", "Off"),
                ])),
                SettingRow("clipboard-trim-trailing-spaces", "Trim trailing spaces", .toggle),
                SettingRow("clipboard-paste-protection", "Warn before pasting commands", .toggle),
                SettingRow("clipboard-read", "Apps reading the clipboard", .segmented([("ask", "Ask"), ("allow", "Allow"), ("deny", "Deny")])),
                SettingRow("clipboard-write", "Apps writing the clipboard", .segmented([("ask", "Ask"), ("allow", "Allow"), ("deny", "Deny")])),
            ]),
            SettingsSection("Mouse & links", [
                SettingRow("mouse-hide-while-typing", "Hide the pointer while typing", .toggle),
                SettingRow("focus-follows-mouse", "Focus follows the mouse", .toggle),
                SettingRow("right-click-action", "Right click", .picker([
                    ("context-menu", "Context menu"), ("paste", "Paste"), ("copy", "Copy"),
                    ("copy-or-paste", "Copy or paste"), ("ignore", "Nothing"),
                ])),
                SettingRow("link-url", "Detect links", .toggle),
                SettingRow("mouse-scroll-multiplier", "Scroll speed", .text(placeholder: "precision:1,discrete:3")),
            ]),
            SettingsSection("Notifications", [
                SettingRow("notify-on-command-finish", "Notify when a command finishes", .picker([
                    ("never", "Never"), ("unfocused", "When unfocused"), ("always", "Always"),
                ])),
                SettingRow("notify-on-command-finish-after", "Only for commands longer than", .text(placeholder: "5s")),
            ]),
        ])

    static let keyboard = SettingsPage(
        id: .keyboard, title: "Keyboard", symbol: "command", tint: .gray,
        sections: [
            SettingsSection(custom: .shortcutGuide),
            SettingsSection("Keys", [
                SettingRow("macos-option-as-alt", "Option key sends Alt", .picker([
                    ("", "Off"), ("true", "Both Option keys"), ("left", "Left Option only"), ("right", "Right Option only"),
                ])),
                SettingRow("macos-shortcuts", "Shortcuts app access", .segmented([("ask", "Ask"), ("allow", "Allow"), ("deny", "Deny")])),
                SettingRow("macos-auto-secure-input", "Secure input at password prompts", .toggle),
            ]),
        ])

    static let session = SettingsPage(
        id: .session, title: "Sessions & Agent", symbol: "arrow.clockwise.circle", tint: .green,
        sections: [
            SettingsSection("Session persistence", [
                SettingRow("session-persistence", "Keep shells running when the app quits", .toggle),
                SettingRow("session-relaunch", "After a reboot, panes", .picker([
                    ("restore", "Reopen as a shell in the same folder"), ("rerun", "Re-run their command"), ("prompt", "Ask each time"),
                ]), enabledWhen: .equals("session-persistence", "true", "Needs session persistence")),
                SettingRow("claude-code-fullscreen", "Claude Code full-screen mode", .toggle),
            ]),
            SettingsSection("Agent", custom: .agentStatus),
        ])

    static let remote = SettingsPage(
        id: .remote, title: "Remote Machines", symbol: "arrow.left.arrow.right", tint: .orange,
        sections: [SettingsSection(custom: .remoteMachines)])

    static let updates = SettingsPage(
        id: .updates, title: "Updates", symbol: "arrow.down.circle", tint: .blue,
        sections: [
            SettingsSection([
                SettingRow("auto-update", "Automatic updates", .picker([
                    ("", "System default"), ("check", "Check and notify"), ("download", "Download and install"), ("off", "Off"),
                ])),
                SettingRow("auto-update-channel", "Channel", .segmented([("", "Default"), ("stable", "Stable"), ("tip", "Tip")])),
            ]),
            SettingsSection(custom: .version),
        ])

    static let advanced = SettingsPage(
        id: .advanced, title: "Advanced", symbol: "ellipsis.circle", tint: Color(white: 0.4),
        sections: [
            SettingsSection("Config file", custom: .configFile),
            SettingsSection("All settings", footer: "Every option, straight from the config schema.", custom: .allSettings),
        ])
}

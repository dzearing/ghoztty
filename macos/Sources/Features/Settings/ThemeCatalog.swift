import AppKit
import SwiftUI

/// The themes the `theme` key can name: the bundled ones
/// (`Resources/ghostty/themes`) plus the user's own (`~/.config/ghostty/themes`,
/// which win on a name clash, as in Ghostty's theme lookup). Each is read
/// once for the colors the Settings window previews.
struct ThemeInfo: Identifiable, Equatable {
    let name: String
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor?
    /// ANSI 0–15 (missing entries fall back to the foreground).
    let palette: [NSColor]
    let isUserTheme: Bool

    var id: String { name }

    /// Light or dark comes from the background's luminance, so the
    /// light/dark lists never mix (a light theme can't land in the dark slot).
    var isLight: Bool { background.isLightColor }

    func ansi(_ index: Int) -> Color { Color(nsColor: index < palette.count ? palette[index] : foreground) }
}

final class ThemeCatalog {
    static let shared = ThemeCatalog()

    private var cached: [ThemeInfo]?
    private let lock = NSLock()

    var themes: [ThemeInfo] {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let loaded = Self.load()
        cached = loaded
        return loaded
    }

    func theme(named name: String) -> ThemeInfo? {
        themes.first { $0.name == name }
    }

    /// Forget the cache (after the user adds a theme file).
    func reload() {
        lock.lock(); cached = nil; lock.unlock()
    }

    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes", isDirectory: true)
    }

    static var userDirectory: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("ghostty/themes", isDirectory: true)
    }

    private static func load() -> [ThemeInfo] {
        var byName: [String: ThemeInfo] = [:]
        for (dir, isUser) in [(bundledDirectory, false), (userDirectory, true)] {
            guard let dir,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let theme = parse(name: name, text: text, isUserTheme: isUser) else { continue }
                byName[name] = theme
            }
        }
        return byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func parse(name: String, text: String, isUserTheme: Bool) -> ThemeInfo? {
        var background: NSColor?
        var foreground: NSColor?
        var cursor: NSColor?
        var palette: [Int: NSColor] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = ConfigFileText.parse(String(line)), let value else { continue }
            switch key {
            case "background": background = NSColor(hex: value)
            case "foreground": foreground = NSColor(hex: value)
            case "cursor-color": cursor = NSColor(hex: value)
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                   let color = NSColor(hex: String(parts[1])) {
                    palette[index] = color
                }
            default: break
            }
        }
        guard let background, let foreground else { return nil }
        let ansi = (0..<16).map { palette[$0] ?? foreground }
        return ThemeInfo(name: name, background: background, foreground: foreground,
                         cursor: cursor, palette: ansi, isUserTheme: isUserTheme)
    }
}

/// A `theme` value: one theme, or `light:A,dark:B` (Ghostty's conditional form).
struct ThemeSelection: Equatable {
    var light: String
    var dark: String
    var followsSystem: Bool

    init(light: String, dark: String) {
        self.light = light
        self.dark = dark
        self.followsSystem = true
    }

    init(single: String) {
        self.light = single
        self.dark = single
        self.followsSystem = false
    }

    /// Parse a `theme` value (`""` → no theme). Mirrors `Theme.parseCLI`.
    init?(configValue: String) {
        let value = configValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        guard value.contains(":") else {
            self.init(single: value)
            return
        }
        var light: String?
        var dark: String?
        for part in value.split(separator: ",") {
            let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            if pair[0] == "light" { light = pair[1] }
            if pair[0] == "dark" { dark = pair[1] }
        }
        guard let light, let dark else {
            // e.g. a path containing ":" — treat as one theme.
            self.init(single: value)
            return
        }
        self.init(light: light, dark: dark)
    }

    var configValue: String {
        followsSystem ? "light:\(light),dark:\(dark)" : light
    }
}

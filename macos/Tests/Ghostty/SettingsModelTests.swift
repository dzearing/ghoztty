import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Ghostty

/// The curated pages must stay in step with `Config.zig`: every key and
/// every enum option they name has to exist in libghostty's schema.
@Suite
struct SettingsPagesTests {
    let schema = ConfigSchema.defaults()!

    @Test func everyCuratedKeyExistsInTheSchema() {
        for key in SettingsPages.curatedKeys {
            #expect(schema[key] != nil, "Settings page names \(key), which isn't a config key")
        }
    }

    @Test func everyCuratedOptionIsAValidValue() {
        for page in SettingsPages.all {
            for section in page.sections {
                guard case .rows(let rows) = section.content else { continue }
                for row in rows {
                    guard let entry = schema[row.key] else { continue }
                    for option in row.curatedOptions {
                        let valid = (entry.options?.contains(option) ?? false)
                            || ConfigValidator.problems(in: [try! ConfigFileText.render(row.key, option)]).isEmpty
                        #expect(valid, "\(row.key) offers \(option), which Ghostty rejects")
                    }
                }
            }
        }
    }

    @Test func noKeyIsOnTwoPages() {
        var seen: [String: SettingsPageID] = [:]
        for page in SettingsPages.all {
            for key in page.sections.flatMap(\.keys) {
                #expect(seen[key] == nil || seen[key] == page.id, "\(key) is on \(seen[key]!) and \(page.id)")
                seen[key] = page.id
            }
        }
    }

    @Test func schemaCarriesDocsDefaultsAndKinds() throws {
        let size = try #require(schema["font-size"])
        #expect(size.kind == .float)
        #expect(!(size.doc ?? "").isEmpty)
        #expect(schema["cursor-style"]?.options?.contains("block") == true)
        #expect(schema["keybind"]?.repeatable == true)
        #expect(schema["macos-pane-min-width"]?.value == "225")
        #expect(schema["macos-pane-sidebar"]?.options == ["remember", "expanded", "collapsed", "hidden"])
        #expect(schema["shell-integration-features"]?.kind == .flags)
        // A row subtitle drops a trailing "Valid values:" lead-in.
        #expect(schema["window-new-tab-position"]?.summary.hasSuffix(":") == false)
    }

    /// The debug build must never write the release app's config: libghostty
    /// loads (and Settings writes) the `.debug` App Support file, the same
    /// folder Settings lists as a default source.
    @MainActor @Test func debugBuildWritesItsOwnConfig() throws {
        let preferred = try #require(ConfigSchema.preferredPath())
        #expect(preferred.contains("/com.dzearing.ghoztty.debug/"), "\(preferred)")
        let dir = URL(fileURLWithPath: preferred).deletingLastPathComponent().standardizedFileURL
        #expect(SettingsModel.defaultFileURLs().contains { $0.deletingLastPathComponent().standardizedFileURL == dir })
    }

    @Test func validatorUsesGhosttysParser() {
        #expect(ConfigValidator.problems(in: ["font-size = 14"]).isEmpty)
        #expect(ConfigValidator.problems(in: ["font-size = abc"]) == ["invalid value \"abc\""])
        #expect(ConfigValidator.problems(in: ["cursor-style = wiggle"]).first?.hasPrefix("invalid value \"wiggle\"") == true)
    }
}

@Suite
struct ThemeSelectionTests {
    @Test func parsesAndFormatsBothForms() {
        #expect(ThemeSelection(configValue: "") == nil)
        let single = ThemeSelection(configValue: "Dracula")!
        #expect(!single.followsSystem && single.light == "Dracula" && single.configValue == "Dracula")
        let pair = ThemeSelection(configValue: "light:Catppuccin Latte, dark:Catppuccin Mocha")!
        #expect(pair.followsSystem && pair.light == "Catppuccin Latte" && pair.dark == "Catppuccin Mocha")
        #expect(pair.configValue == "light:Catppuccin Latte,dark:Catppuccin Mocha")
    }

    @Test func bundledThemesSplitIntoLightAndDark() throws {
        let themes = ThemeCatalog.shared.themes
        #expect(themes.count > 100)
        let latte = try #require(themes.first { $0.name == "Catppuccin Latte" })
        let mocha = try #require(themes.first { $0.name == "Catppuccin Mocha" })
        #expect(latte.isLight)
        #expect(!mocha.isLight)
    }
}

/// The model's write path: validation before writing, include overrides,
/// undo, keyed keybinds, and the reload after each change.
@MainActor
@Suite
struct SettingsModelTests {
    let root: URL
    let catalog = ConfigSchema.defaults()!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    final class Counter { var reloads = 0 }

    private func model(_ text: String? = nil, counter: Counter = Counter()) throws -> SettingsModel {
        let url = root.appendingPathComponent("config.ghostty")
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        let store = ConfigFileStore(url: url, backupDirectory: root.appendingPathComponent("backups"))
        return SettingsModel(catalog: catalog, store: store, reload: { counter.reloads += 1 }, liveConfig: { nil })
    }

    private func contents() throws -> String {
        try String(contentsOf: root.appendingPathComponent("config.ghostty"), encoding: .utf8)
    }

    @Test func validValuesAreWrittenAndReloaded() throws {
        let counter = Counter()
        let m = try model("# mine\n", counter: counter)
        #expect(m.set("font-size", "15"))
        #expect(try contents() == "# mine\nfont-size = 15\n")
        #expect(counter.reloads == 1)
        #expect(m.isSetInFile("font-size"))
        #expect(m.lastChange?.added == ["font-size = 15"])
    }

    @Test func invalidValuesAreShownAndNeverWritten() throws {
        let counter = Counter()
        let m = try model("# mine\n", counter: counter)
        #expect(!m.set("font-size", "huge"))
        #expect(m.problems["font-size"] == "invalid value \"huge\"")
        #expect(try contents() == "# mine\n")
        #expect(counter.reloads == 0)
        // A good value clears the problem.
        #expect(m.set("font-size", "12"))
        #expect(m.problems["font-size"] == nil)
    }

    @Test func resetRemovesTheKey() throws {
        let m = try model("font-size = 15\n# keep\n")
        m.reset("font-size")
        #expect(try contents() == "# keep\n")
    }

    @Test func aKeySetByALaterIncludeIsReadOnly() throws {
        try "font-size = 20\n".write(to: root.appendingPathComponent("work.ghostty"), atomically: true, encoding: .utf8)
        let m = try model("config-file = ?work.ghostty\n")
        #expect(m.overridingSource("font-size")?.url.lastPathComponent == "work.ghostty")
        #expect(!m.set("font-size", "12"))
        #expect(m.problems["font-size"]?.contains("work.ghostty") == true)
        #expect(try contents() == "config-file = ?work.ghostty\n")
        #expect(m.overridingSource("cursor-style") == nil)
    }

    @Test func undoPutsTheFileBack() throws {
        let m = try model("# a\nfont-size = 12\n")
        m.set("font-size", "16")
        m.undoLastChange()
        #expect(try contents() == "# a\nfont-size = 12\n")
        #expect(m.lastChange == nil)
    }

    @Test func undoNeverClobbersAnOutsideEdit() throws {
        let m = try model("font-size = 12\n")
        m.set("font-size", "16")
        try "font-size = 16\n# typed by hand\n".write(to: root.appendingPathComponent("config.ghostty"), atomically: true, encoding: .utf8)
        m.undoLastChange()
        #expect(try contents() == "font-size = 16\n# typed by hand\n")
        #expect(m.fileError != nil)
    }

    @Test func keybindsAreKeyedByTrigger() throws {
        let m = try model("keybind = cmd+k=clear_screen\n")
        let trigger: (String) -> String? = { value in
            value.firstMatch(of: #/^(.+?)=([a-z_]+(?::.*)?)$/#).map { String($0.1).replacingOccurrences(of: "cmd", with: "super") }
        }
        #expect(m.setKeyed("keybind", subkey: "super+k", rest: "new_tab", subkeyOf: trigger,
                           normalize: { $0.replacingOccurrences(of: "cmd", with: "super") }))
        #expect(try contents() == "keybind = super+k=new_tab\n")
        // An action Ghostty doesn't know is rejected inline.
        #expect(!m.setKeyed("keybind", subkey: "super+j", rest: "not_an_action", subkeyOf: trigger))
        #expect(try contents() == "keybind = super+k=new_tab\n")
    }

    @Test func listsAndFlagsRoundTrip() throws {
        let m = try model("")
        #expect(m.setList("font-feature", ["-calt", "ss01"]))
        #expect(m.file.values(for: "font-feature") == ["-calt", "ss01"])
        #expect(m.set("shell-integration-features", "cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path"))
    }

    @Test func sourcesFollowGhosttysLoadOrder() throws {
        let a = root.appendingPathComponent("a.conf")
        let b = root.appendingPathComponent("sub/b.conf")
        let c = root.appendingPathComponent("sub/c.conf")
        try FileManager.default.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "config-file = sub/b.conf\nconfig-file = ?missing.conf\n".write(to: a, atomically: true, encoding: .utf8)
        try "config-file = c.conf\n".write(to: b, atomically: true, encoding: .utf8)
        try "font-size = 9\n".write(to: c, atomically: true, encoding: .utf8)
        let sources = SettingsModel.loadSources(main: a, defaults: [a])
        #expect(sources.map(\.url.lastPathComponent) == ["a.conf", "b.conf", "c.conf"])
        #expect(sources.map(\.included) == [false, true, true])
    }
}

/// Renders every page offscreen (no window server permissions needed) so
/// layout can be inspected, and checks nothing is wider than the window.
@MainActor
@Suite(.serialized)
struct SettingsViewRenderTests {
    @Test(arguments: SettingsPageID.allCases)
    func pageRendersWithinTheWindow(_ page: SettingsPageID) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsRender-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.ghostty")
        try "# sample\nfont-family = JetBrains Mono\ntheme = light:Catppuccin Latte,dark:Catppuccin Mocha\nbackground-opacity = 0.92\nkeybind = cmd+k=clear_screen\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let catalog = try #require(ConfigSchema.defaults())
        let model = SettingsModel(catalog: catalog,
                                  store: ConfigFileStore(url: url, backupDirectory: root.appendingPathComponent("b")),
                                  reload: {}, liveConfig: { nil })

        for width in [720.0, 900.0] {
            let view = SettingsView(model: model, openInEditor: {}, initialPage: page)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 900),
                                  styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderBack(nil)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            hosting.layoutSubtreeIfNeeded()

            #expect(hosting.fittingSize.width <= width + 1, "\(page) is wider than \(width)pt: \(hosting.fittingSize.width)")

            if let dir = ProcessInfo.processInfo.environment["GHOZTTY_SETTINGS_SNAPSHOTS"]
                ?? Optional(FileManager.default.temporaryDirectory.appendingPathComponent("ghoztty-settings-snapshots").path) {
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    let png = rep.representation(using: .png, properties: [:])
                    try png?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(page.rawValue)-\(Int(width)).png"))
                }
            }
            window.orderOut(nil)
        }
    }
}

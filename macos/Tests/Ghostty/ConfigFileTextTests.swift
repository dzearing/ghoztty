import Foundation
import Testing
@testable import Ghostty

/// The Settings window's config writer must change only the lines for the key
/// being set. These pin that down: comments, blank lines, ordering, includes,
/// unknown keys and line endings all survive byte for byte.
@Suite
struct ConfigFileTextTests {
    private func edited(_ text: String, _ edit: (inout ConfigFileText) throws -> Void) rethrows -> String {
        var file = ConfigFileText(text)
        try edit(&file)
        return file.string
    }

    // MARK: Parsing (mirrors LineIterator in src/cli/args.zig)

    @Test func parsesLikeGhostty() {
        #expect(ConfigFileText.parse("font-size = 14") ?? ("", nil) == ("font-size", "14"))
        #expect(ConfigFileText.parse("  font-size=14\t\r") ?? ("", nil) == ("font-size", "14"))
        #expect(ConfigFileText.parse("title = \"  hi  \"") ?? ("", nil) == ("title", "  hi  "))
        #expect(ConfigFileText.parse("maximize") ?? ("", "x") == ("maximize", nil))
        #expect(ConfigFileText.parse("keybind = super+==increase_font_size:1") ?? ("", nil)
            == ("keybind", "super+==increase_font_size:1"))
        #expect(ConfigFileText.parse("# font-size = 20") == nil)
        #expect(ConfigFileText.parse("   # indented comment") == nil)
        #expect(ConfigFileText.parse("   ") == nil)
    }

    @Test func roundTripsUntouchedBytes() {
        let samples = [
            "", "\n", "a = 1", "a = 1\n", "# c\r\na = 1\r\n", "\u{FEFF}a = 1\n",
            "a = 1\r\n\nb = 2", "x = a\rb\n", "\n\n# only comments\n\n",
        ]
        for sample in samples {
            #expect(ConfigFileText(sample).string == sample, "round trip of \(sample.debugDescription)")
        }
    }

    // MARK: Plain keys

    @Test func setAppendsToEmptyAndMissingFiles() throws {
        #expect(try edited("") { try $0.set("font-size", "14") } == "font-size = 14\n")
    }

    @Test func setReplacesInPlaceKeepingEverythingElse() throws {
        let original = """
        # My config — hand written
        font-family = JetBrains Mono

          font-size = 13
        config-file = ?work.ghostty
        some-future-key = kept as-is
        # trailing comment

        """
        let result = try edited(original) { try $0.set("font-size", "15") }
        #expect(result == """
        # My config — hand written
        font-family = JetBrains Mono

          font-size = 15
        config-file = ?work.ghostty
        some-future-key = kept as-is
        # trailing comment

        """)
    }

    @Test func setRewritesOnlyTheLastOccurrence() throws {
        let result = try edited("font-size = 12\n# later\nfont-size = 13\n") { try $0.set("font-size", "16") }
        #expect(result == "font-size = 12\n# later\nfont-size = 16\n")
        #expect(ConfigFileText(result).value(for: "font-size") == .some("16"))
    }

    @Test func setReplacesTheBareFlagForm() throws {
        #expect(try edited("maximize\n") { try $0.set("maximize", "false") } == "maximize = false\n")
    }

    @Test func setKeepsAMissingTrailingNewline() throws {
        #expect(try edited("a = 1") { try $0.set("b", "2") } == "a = 1\nb = 2")
        #expect(try edited("a = 1") { try $0.set("a", "3") } == "a = 3")
    }

    @Test func commentedOutKeysAreNotTouched() throws {
        let result = try edited("# font-size = 20\n") { try $0.set("font-size", "14") }
        #expect(result == "# font-size = 20\nfont-size = 14\n")
    }

    @Test func removeDeletesEveryOccurrence() {
        let original = "font-size = 12\n# keep me\nmaximize\nfont-size = 13\nmaximize = true\n"
        var file = ConfigFileText(original)
        file.remove("font-size")
        file.remove("maximize")
        #expect(file.string == "# keep me\n")
    }

    @Test func removingTheUnterminatedLastLineKeepsNoTrailingNewline() {
        var file = ConfigFileText("a = 1\nb = 2")
        file.remove("b")
        #expect(file.string == "a = 1")
    }

    @Test func conditionalThemeValueIsOneValue() throws {
        let result = try edited("theme = Dracula\n") { try $0.set("theme", "light:Catppuccin Latte,dark:Catppuccin Mocha") }
        #expect(result == "theme = light:Catppuccin Latte,dark:Catppuccin Mocha\n")
    }

    @Test func includesAndUnknownKeysSurviveEdits() throws {
        let original = "config-file = ?work.ghostty\nconfig-file = theme.conf\nmystery = 1\n"
        let result = try edited(original) {
            try $0.set("font-size", "14")
            $0.remove("cursor-style")
        }
        #expect(result == original + "font-size = 14\n")
    }

    // MARK: Quoting and invalid values

    @Test func quotesValuesGhosttyWouldOtherwiseChange() throws {
        #expect(try ConfigFileText.render("title", " padded ") == "title = \" padded \"")
        #expect(try ConfigFileText.render("title", "\"quoted\"") == "title = \"\"quoted\"\"")
        #expect(try ConfigFileText.render("font-family", "JetBrains Mono") == "font-family = JetBrains Mono")
        // …and reading it back gives the value we meant.
        let file = ConfigFileText(try ConfigFileText.render("title", " padded ") + "\n")
        #expect(file.value(for: "title") == .some(" padded "))
    }

    @Test func rejectsLineBreaksWithoutChangingTheFile() {
        var file = ConfigFileText("a = 1\n")
        #expect(throws: ConfigFileText.EditError.multiline(key: "title")) { try file.set("title", "two\nlines") }
        #expect(file.string == "a = 1\n")
    }

    @Test func rejectsLinesGhosttyCannotRead() {
        var file = ConfigFileText("")
        #expect(throws: ConfigFileText.EditError.lineTooLong(key: "title")) {
            try file.set("title", String(repeating: "x", count: 5000))
        }
    }

    // MARK: Line endings and BOM

    @Test func crlfFilesStayCRLF() throws {
        let result = try edited("# win\r\nfont-size = 12\r\n\r\ncursor-style = bar\r\n") {
            try $0.set("font-size", "14")
            try $0.set("theme", "Nord")
        }
        #expect(result == "# win\r\nfont-size = 14\r\n\r\ncursor-style = bar\r\ntheme = Nord\r\n")
    }

    @Test func mixedEndingsKeepEachLinesOwn() throws {
        let result = try edited("a = 1\r\nb = 2\nc = 3\n") { try $0.set("b", "9") }
        #expect(result == "a = 1\r\nb = 9\nc = 3\n")
    }

    @Test func bomIsPreserved() throws {
        let result = try edited("\u{FEFF}a = 1\n") { try $0.set("a", "2") }
        #expect(result == "\u{FEFF}a = 2\n")
    }

    // MARK: Repeatable keys

    @Test func valuesHonorAnEmptyReset() {
        let file = ConfigFileText("font-family = A\nfont-family =\nfont-family = B\nfont-family = C\n")
        #expect(file.values(for: "font-family") == ["B", "C"])
    }

    @Test func setListKeepsMatchingLinesAndInterleavedComments() throws {
        let original = """
        font-family = JetBrains Mono
        # fallback for symbols
        font-family = Symbols Nerd Font
        font-size = 13

        """
        // Replace the primary font, keep the fallback line (and its comment).
        let result = try edited(original) { try $0.setList("font-family", ["Fira Code", "Symbols Nerd Font"]) }
        #expect(result == """
        # fallback for symbols
        font-family = Fira Code
        font-family = Symbols Nerd Font
        font-size = 13

        """)
        #expect(ConfigFileText(result).values(for: "font-family") == ["Fira Code", "Symbols Nerd Font"])
    }

    @Test func setListReordersWithTheFewestMovedLines() throws {
        let original = "font-family = A\nfont-family = B\nfont-family = C\n"
        let result = try edited(original) { try $0.setList("font-family", ["B", "C", "A"]) }
        #expect(result == "font-family = B\nfont-family = C\nfont-family = A\n")
    }

    @Test func setListKeepsAMissingTrailingNewline() throws {
        #expect(try edited("font-family = A") { try $0.setList("font-family", ["A", "B"]) } == "font-family = A\nfont-family = B")
        #expect(try edited("x = 1\nfont-family = A") { try $0.setList("font-family", []) } == "x = 1")
    }

    @Test func setListAddsAfterTheLastKeptLine() throws {
        let original = "font-feature = -calt\nfont-size = 13\n"
        let result = try edited(original) { try $0.setList("font-feature", ["-calt", "ss01"]) }
        #expect(result == "font-feature = -calt\nfont-feature = ss01\nfont-size = 13\n")
    }

    @Test func setListReplacesInPlaceWhenNothingIsKept() throws {
        let original = "# top\nfont-feature = -calt\nfont-size = 13\n"
        let result = try edited(original) { try $0.setList("font-feature", ["ss02"]) }
        #expect(result == "# top\nfont-feature = ss02\nfont-size = 13\n")
    }

    @Test func setListEmptyRemovesTheKey() throws {
        let result = try edited("font-feature = -calt\n# x\nfont-feature = ss01\n") { try $0.setList("font-feature", []) }
        #expect(result == "# x\n")
    }

    @Test func setListAppendsANewKey() throws {
        #expect(try edited("a = 1\n") { try $0.setList("font-family", ["A", "B"]) } == "a = 1\nfont-family = A\nfont-family = B\n")
    }

    @Test func addGoesAfterTheKeysLastLine() throws {
        let result = try edited("env = A=1\nfont-size = 3\n") { try $0.add("env", "B=2") }
        #expect(result == "env = A=1\nenv = B=2\nfont-size = 3\n")
    }

    // MARK: Keyed repeatable entries (keybind, palette, env)

    /// `cmd`/`command` are aliases of `super`, as Ghostty's trigger parser has them.
    private static func trigger(_ value: String) -> String? {
        guard let match = value.firstMatch(of: #/^(.+?)=([a-z_]+(?::.*)?)$/#) else { return nil }
        return normalize(String(match.1))
    }
    private static func normalize(_ trigger: String) -> String {
        trigger.split(separator: "+", omittingEmptySubsequences: false).map {
            ["cmd": "super", "command": "super", "opt": "alt", "option": "alt", "control": "ctrl"][String($0)] ?? String($0)
        }.joined(separator: "+")
    }

    @Test func keybindReplacesTheSameTriggerWrittenDifferently() throws {
        let original = "keybind = cmd+shift+d=new_split:down\nkeybind = cmd+k=clear_screen\n# end\n"
        let result = try edited(original) {
            try $0.setKeyed("keybind", subkey: "super+k", rest: "new_tab",
                            subkeyOf: Self.trigger, normalize: Self.normalize)
        }
        #expect(result == "keybind = cmd+shift+d=new_split:down\nkeybind = super+k=new_tab\n# end\n")
    }

    @Test func keybindUnbindIsJustAnotherAction() throws {
        let result = try edited("font-size = 3\n") {
            try $0.setKeyed("keybind", subkey: "super+d", rest: "unbind", subkeyOf: Self.trigger, normalize: Self.normalize)
        }
        #expect(result == "font-size = 3\nkeybind = super+d=unbind\n")
    }

    @Test func keybindTriggersMayContainEquals() throws {
        let original = "keybind = super+==increase_font_size:1\nkeybind = super+-=decrease_font_size:1\n"
        let result = try edited(original) {
            try $0.setKeyed("keybind", subkey: "super+=", rest: nil, subkeyOf: Self.trigger, normalize: Self.normalize)
        }
        #expect(result == "keybind = super+-=decrease_font_size:1\n")
    }

    @Test func keyedRemovesDuplicatesAndKeepsTheLastPosition() throws {
        let original = "palette = 1=#ff0000\n# mine\npalette = 2=#00ff00\npalette = 1=#aa0000\n"
        let result = try edited(original) { try $0.setKeyed("palette", subkey: "1", rest: "#123456") }
        #expect(result == "# mine\npalette = 2=#00ff00\npalette = 1=#123456\n")
    }

    @Test func keyedNewEntryGoesAfterTheKeysLastLine() throws {
        let result = try edited("env = A=1\nfont-size = 3\n") { try $0.setKeyed("env", subkey: "B", rest: "2") }
        #expect(result == "env = A=1\nenv = B=2\nfont-size = 3\n")
    }

    @Test func keyedNilRemovesOnlyThatEntry() throws {
        let result = try edited("env = A=1\nenv = B=2\n") { try $0.setKeyed("env", subkey: "A", rest: nil) }
        #expect(result == "env = B=2\n")
    }
}

/// File I/O around the text editor: creation, backups, symlinks, permissions.
@Suite
struct ConfigFileStoreTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigFileStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func store(_ name: String = "config.ghostty", kept: Int = 10, clock: @escaping () -> Date = Date.init) -> ConfigFileStore {
        ConfigFileStore(
            url: root.appendingPathComponent("dir/\(name)"),
            backupDirectory: root.appendingPathComponent("backups"),
            backupsKept: kept,
            now: clock)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func createsAMissingFileAndItsDirectoryWithoutABackup() throws {
        let s = store()
        try s.edit { try $0.set("font-size", "14") }
        #expect(try contents(s.url) == "font-size = 14\n")
        #expect(s.backupURL == nil)
        #expect(s.backups().isEmpty)
    }

    @Test func backsUpOncePerSessionBeforeTheFirstChange() throws {
        let s = store()
        try write("# mine\nfont-size = 12\n", to: s.url)
        try s.edit { try $0.set("font-size", "13") }
        try s.edit { try $0.set("font-size", "14") }
        #expect(s.backups().count == 1)
        #expect(try contents(try #require(s.backupURL)) == "# mine\nfont-size = 12\n")
        #expect(try contents(s.url) == "# mine\nfont-size = 14\n")
    }

    @Test func aNewSessionBacksUpAgainAndOldBackupsArePruned() throws {
        var tick = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = { tick }
        let first = store(kept: 2, clock: clock)
        try write("a = 1\n", to: first.url)
        for i in 0..<4 {
            tick += 60
            let session = store(kept: 2, clock: clock)
            try session.edit { try $0.set("a", "\(i + 2)") }
        }
        let backups = store(kept: 2).backups()
        #expect(backups.count == 2)
        // Newest first: the file as it was before the last session's change.
        #expect(try contents(backups[0]) == "a = 4\n")
    }

    @Test func noOpEditsNeitherWriteNorBackUp() throws {
        let s = store()
        try write("font-size = 14\n", to: s.url)
        let before = try FileManager.default.attributesOfItem(atPath: s.url.path)[.modificationDate] as? Date
        let change = try s.edit { try $0.set("font-size", "14") }
        #expect(!change.changed)
        #expect(s.backups().isEmpty)
        let after = try FileManager.default.attributesOfItem(atPath: s.url.path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test func writesThroughASymlinkAndKeepsTheLink() throws {
        let target = root.appendingPathComponent("dotfiles/ghostty.conf")
        try write("# from dotfiles\n", to: target)
        let s = store()
        try FileManager.default.createDirectory(at: s.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: s.url, withDestinationURL: target)

        try s.edit { try $0.set("font-size", "14") }

        let attrs = try FileManager.default.attributesOfItem(atPath: s.url.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try contents(target) == "# from dotfiles\nfont-size = 14\n")
    }

    @Test func keepsFilePermissions() throws {
        let s = store()
        try write("a = 1\n", to: s.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: s.url.path)
        try s.edit { try $0.set("a", "2") }
        let perms = try FileManager.default.attributesOfItem(atPath: s.url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func picksUpEditsMadeOutsideSettings() throws {
        let s = store()
        try write("a = 1\n", to: s.url)
        try s.edit { try $0.set("b", "2") }
        // The user edits the file in their editor…
        try write("a = 1\n# added by hand\nb = 2\nc = 3\n", to: s.url)
        // …and the next Settings change keeps their edit.
        try s.edit { try $0.set("a", "9") }
        #expect(try contents(s.url) == "a = 9\n# added by hand\nb = 2\nc = 3\n")
    }

    @Test func refusesNonUTF8FilesAndLeavesThemAlone() throws {
        let s = store()
        try FileManager.default.createDirectory(at: s.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data([0x61, 0x20, 0x3D, 0x20, 0xFF, 0xFE, 0x0A])
        try bytes.write(to: s.url)
        #expect(throws: ConfigFileStore.StoreError.self) { try s.edit { try $0.set("a", "2") } }
        #expect(try Data(contentsOf: s.url) == bytes)
    }

    @Test func restoresABackup() throws {
        let s = store()
        try write("a = 1\n", to: s.url)
        try s.edit { try $0.set("a", "2") }
        try s.restore(try #require(s.backupURL))
        #expect(try contents(s.url) == "a = 1\n")
    }
}

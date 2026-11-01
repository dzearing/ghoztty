import Testing
import Foundation
@testable import Ghostty
@testable import GhosttyKit

/// The shortcut guide's catalog: real data from libghostty, curated
/// descriptions layered on top. See docs/reference/keyboard-shortcuts.md.
@Suite
struct KeybindCatalogTests {
    // MARK: Coverage

    /// Fails when an action is added to `src/input/Binding.zig` without a
    /// curated entry in `ShortcutDescriptors` (category, title, description).
    @Test func everyLibraryActionHasACuratedDescriptor() {
        let keys = KeybindCatalog.libraryActionKeys()
        #expect(keys.count > 80)
        let missing = keys.filter { ShortcutDescriptors.all[$0] == nil }
        #expect(missing.isEmpty, "Add these actions to ShortcutDescriptors.all: \(missing)")
        let stale = Set(ShortcutDescriptors.all.keys).subtracting(keys)
        #expect(stale.isEmpty, "ShortcutDescriptors describes actions libghostty no longer has: \(stale)")
        #expect(Set(ShortcutDescriptors.order) == Set(ShortcutDescriptors.all.keys))
    }

    /// An action the catalog doesn't know still appears, under Other, by its raw name.
    @Test func uncuratedActionsStillAppearUnderOther() {
        let catalog = KeybindCatalog(
            effective: [.init(trigger: "super+shift+k", action: "brand_new_action:x")],
            defaults: [],
            actionKeys: ["brand_new_action", "another_new_action"])
        let bound = catalog.row(forAction: "brand_new_action:x")
        #expect(bound?.category == .other)
        #expect(bound?.title == "brand_new_action")
        #expect(bound?.isUncurated == true)
        #expect(bound?.isBound == true)
        // Unbound uncurated actions are listed too (with the unbound toggle).
        let unbound = catalog.rows(includeUnbound: true).first { $0.actions == ["another_new_action"] }
        #expect(unbound?.category == .other)
    }

    // MARK: Live config

    @Test func defaultsAreNotCustomized() throws {
        let config = try TemporaryConfig("")
        let catalog = KeybindCatalog(config: try #require(config.config))
        #expect(!catalog.effective.isEmpty)
        #expect(catalog.allRows.filter(\.isCustomized).isEmpty)
        let split = try #require(catalog.row(forAction: "new_split:right"))
        #expect(split.title == "Split Right")
        #expect(split.category == .panes)
        #expect(split.bindings.map(\.trigger.canonical) == ["super+d"])
        // The guide opens itself with ⌘/.
        #expect(catalog.row(forAction: "show_keyboard_shortcuts")?.bindings.map(\.trigger.display) == ["⌘/"])
    }

    @Test func overridesUnbindsSequencesAndGlobalsAreReported() throws {
        let config = try TemporaryConfig("""
        keybind = super+shift+h=toggle_hero_mode
        keybind = super+shift+space=unbind
        keybind = ctrl+a>n=new_window
        keybind = global:super+backquote=toggle_quick_terminal
        keybind = super+k=unbind
        """)
        let catalog = KeybindCatalog(config: try #require(config.config))

        let hero = try #require(catalog.row(forAction: "toggle_hero_mode"))
        #expect(hero.isCustomized)
        #expect(hero.bindings.map(\.trigger.canonical) == ["super+shift+h"])

        let newWindow = try #require(catalog.row(forAction: "new_window"))
        #expect(newWindow.isCustomized)
        let sequence = try #require(newWindow.bindings.first { $0.trigger.isSequence })
        #expect(sequence.trigger.steps.map(\.canonical) == ["ctrl+a", "n"])
        #expect(sequence.trigger.display == "⌃A N")

        let quick = try #require(catalog.row(forAction: "toggle_quick_terminal"))
        #expect(quick.isGlobal)
        #expect(quick.isCustomized)

        // A default the config unbound: listed, marked, without keys.
        let clear = try #require(catalog.row(forAction: "clear_screen"))
        #expect(clear.isUnboundByUser)
        #expect(clear.isCustomized)
        #expect(!clear.isBound)
        #expect(catalog.rows().contains { $0.id == clear.id })

        // Untouched defaults stay plain.
        #expect(catalog.row(forAction: "new_tab")?.isCustomized == false)
    }

    @Test func familiesCollapseForTheGuideButNotForEditing() throws {
        let config = try TemporaryConfig("")
        let catalog = KeybindCatalog(config: try #require(config.config))
        let grouped = catalog.rows()
        let tabs = try #require(grouped.first { $0.id.hasPrefix("family:goto_tab") })
        #expect(tabs.kind == .family)
        #expect(tabs.bindings.first?.familyKeys == ["1", "2", "3", "4", "5", "6", "7", "8"])
        #expect(!grouped.contains { $0.actions == ["goto_tab:1"] })
        // Expanded for an editor: one row per action.
        #expect(catalog.rows(groupingFamilies: false).contains { $0.actions == ["goto_tab:1"] })
        // ⌘1 and ⌘digit_1 are one keycap, not two bindings.
        #expect(catalog.row(forAction: "goto_tab:1")?.bindings.count == 1)
    }

    @Test func rowsComeOutInCategoryAndCuratedOrder() throws {
        let config = try TemporaryConfig("")
        let rows = KeybindCatalog(config: try #require(config.config)).rows()
        let cats = rows.map(\.category)
        let order = ShortcutCategory.allCases
        #expect(zip(cats, cats.dropFirst()).allSatisfy { order.firstIndex(of: $0)! <= order.firstIndex(of: $1)! })
        let panes = rows.filter { $0.category == .panes }.map(\.title)
        #expect(panes.firstIndex(of: "Split Right")! < panes.firstIndex(of: "Split Down")!)
        let windows = rows.filter { $0.category == .windows }.map(\.title)
        #expect(windows.first == "New Window")
    }

    // MARK: Triggers

    @Test func triggerSpellingsCompareEqual() {
        #expect(KeyTrigger("cmd+shift+d") == KeyTrigger("super+shift+d"))
        #expect(KeyTrigger("shift+super+D") == KeyTrigger("super+shift+d"))
        #expect(KeyTrigger("option+control+x") == KeyTrigger("ctrl+alt+x"))
        #expect(KeyTrigger("super+digit_1") == KeyTrigger("super+1"))
        #expect(KeyTrigger("super+period") == KeyTrigger("super+."))
        #expect(KeyTrigger("super+shift+d")?.canonical == "super+shift+d")
        #expect(KeyTrigger("super+shift+d")?.display == "⇧⌘D")
        #expect(KeyTrigger("ctrl+alt+shift+super+a")?.display == "⌃⌥⇧⌘A")
    }

    @Test func keysThatLookLikeSeparatorsParse() {
        #expect(KeyTrigger("super++")?.steps.first?.key == "+")
        #expect(KeyTrigger("super+=")?.steps.first?.key == "=")
        #expect(KeyTrigger("super+-")?.display == "⌘-")
        #expect(KeyTrigger("ctrl+a>shift+d")?.steps.count == 2)
        #expect(KeyTrigger("super+shift+arrow_up")?.display == "⇧⌘↑")
        #expect(KeyTrigger("super+page_up")?.steps.first?.keycaps == ["⌘", "Page Up"])
    }

    // MARK: Search

    @Test func searchMatchesWordsAndKeysInAnyModifierOrder() throws {
        let config = try TemporaryConfig("")
        let catalog = KeybindCatalog(config: try #require(config.config))
        func titles(_ q: String) -> [String] {
            catalog.rows().filter { KeybindCatalog.matches($0, query: q) }.map(\.title)
        }
        #expect(titles("⌘D") == ["Split Right"])
        #expect(titles("cmd shift p").contains("Command Palette"))
        #expect(titles("shift+cmd+p").contains("Command Palette"))
        #expect(titles("stash").contains("Stash Pane"))
        #expect(titles("split").contains("Split Down"))
        #expect(titles("⌘3").contains("Go to Tab"))
        #expect(titles("⌥⌘←").contains("Focus Pane"))
        #expect(titles("esc").contains("Close Find"))
    }

    @Test func conflictLookupFindsActionsByAnySpelling() throws {
        let config = try TemporaryConfig("")
        let catalog = KeybindCatalog(config: try #require(config.config))
        #expect(catalog.actions(boundTo: try #require(KeyTrigger("cmd+t"))) == ["new_tab"])
    }
}

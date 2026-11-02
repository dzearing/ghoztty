# Keyboard shortcut guide

Read before touching the shortcut guide window, the keybind catalog it shares
with the Settings window, the `show_keyboard_shortcuts` action, or the
`ghostty_config_keybinds_json` / `ghostty_input_action_keys` C API. Mock:
`temp/mocks/shortcuts/index.html` (not committed).

## Opening it

- **Help → Keyboard Shortcuts**, the **`show_keyboard_shortcuts`** action
  (default **⌘/** on macOS; ⌘? is the system Help-menu search, so it was left
  alone), or the command palette ("Show Keyboard Shortcuts").
- From code: `ShortcutGuideController.shared.show()` (or `show(query:)` to open
  it filtered), or send `showKeyboardShortcuts(_:)` (an `AppDelegate`
  `@IBAction`) up the responder chain. The Settings window's Keyboard page uses
  these.
- The action is app-scoped (`Binding.Action.scope`/`requires` = `.app`), so it
  works from a viewer pane and with no window open. The core performs it as
  apprt action `GHOSTTY_ACTION_SHOW_KEYBOARD_SHORTCUTS` (appended to
  `ghostty_action_tag_e`); `Ghostty.App` forwards it to the AppDelegate. GTK
  logs it as unimplemented.

## Where the data comes from

Nothing is a static list. `KeybindCatalog(config:)`
(`macos/Sources/Features/ShortcutGuide/KeybindCatalog.swift`) reads:

- **Effective bindings** of the running config via
  `ghostty_config_keybinds_json(cfg)` (`src/config/keybind_list.zig`): a JSON
  array of `{trigger, action, action_key, chain, table, global, all, consumed,
  performable}`, one object per binding, root set first, then each key table.
  Unlike `+list-keybinds` lines it keeps the `global:`/`all:`/`unconsumed:`/
  `performable:` flags, the key table and `chain=` actions. Field names are a
  contract: add fields, never rename one; the Swift decoder tolerates absent
  fields.
- **Defaults** the same way, from a fresh `ghostty_config_new()` +
  `ghostty_config_finalize()`. An action is **customized** when its set of
  (table, canonical trigger, chain, flags) differs from the defaults' set —
  added, changed or removed. A default the config unbound entirely is still
  listed ("Unbound in your config", CUSTOM badge).
- **Every action tag** via `ghostty_input_action_keys()` (newline-separated,
  static, generated at comptime from `Binding.Action.Key`).

The guide reloads on `ghosttyConfigDidChange` (global config only), so a
reloaded config shows up live.

## The curation layer

`ShortcutDescriptors.swift` maps each action tag to a category, a
plain-language title and a one-line description (both may depend on the
argument: `new_split:right` → "Split Right"), whether it is safe to run from
the guide, and which argument-free action to list when nothing binds it.

- **Nothing silently disappears.** An action with no descriptor is listed under
  **Other** with its raw name, bound or not.
- **`everyLibraryActionHasACuratedDescriptor`** (`KeybindCatalogTests`) fails
  when an action is added to `Binding.zig` without a descriptor, or a
  descriptor outlives its action, or `ShortcutDescriptors.order` drifts.
- **Built-in keys** that aren't keybinds (viewer pane ⌘R/⌘L/⌘F/⌘G/⇧⌘G/zoom,
  Esc in rearrange mode) are listed with a BUILT-IN badge from
  `ShortcutDescriptors.builtIns`; keep them in sync with
  [viewer-panes.md](viewer-panes.md) and [pane-rearrange.md](pane-rearrange.md).
- **Families**: when three or more bindings of one action tag (`goto_tab`,
  `goto_split`, `swap_split`, `resize_split`, `adjust_selection`) share
  modifiers and differ only in the key, the guide draws one row (⌘ + 1 … 8,
  ⌥⌘ + ↑↓←→). `rows(groupingFamilies: false)` keeps them apart for editing.
- Order: `ShortcutCategory.allCases`, then `ShortcutDescriptors.order`, then
  arguments in reading order (right, down, left, up; numbers ascending);
  unbound rows after bound ones, built-ins last.

## Triggers and keycaps

`KeyTrigger` (`KeyTrigger.swift`) parses config's trigger syntax: steps split
on `>` (sequence), keys on `+`, with a `+`/`>`/`=` that IS the key kept
(`super++`, `super+=`). Spellings normalize so they compare equal:
`cmd`/`command` → `super`, `opt`/`option` → `alt`, `control` → `ctrl`,
`digit_1` → `1`, `period` → `.`, `backquote` → `` ` `` …

- `canonical` writes modifiers in config's own order (`super+ctrl+alt+shift`).
- Display uses macOS glyph order ⌃⌥⇧⌘; a sequence draws "⌃ A then N".
- `catalog.actions(boundTo:table:)` answers "what is this key already bound
  to?" by any spelling (Settings' conflict check).

## Search and keyboard

- Search matches title, description, category and raw action name, or — for a
  key-combo query — the keys, in any modifier order: "⌘D", "cmd shift p",
  "shift+cmd+p", "⌥⌘←", and bare keys ("esc", "f5"). Typing a query always
  searches every category.
- ↑/↓ move the selection (even from the search field), ↩ runs it, esc clears
  the search, then the selection, then closes; ⌘F focuses the search. A local
  key monitor scoped to the guide window does this
  (`ShortcutGuideController.handle`).
- **Run** (▶ on hover/selection, or ↩) is offered only for descriptors marked
  `runnable` — no closes, quits, clipboard, text sent to a shell. It brings the
  most recent terminal window (`TerminalController.preferredParent`) forward
  and performs the action there on the next turn, through
  `ViewerKeyFallback.performPalette` (menu item first, else the core).

## Window

`ShortcutGuideController`: a plain `NSWindow` (880×640, min 640×420) hosting
`ShortcutGuideView`; frame autosaved as `ShortcutGuideWindow`; the "Show
unbound actions" toggle persists in `ShortcutGuideIncludeUnbound`. "Print Cheat
Sheet…" prints every bound shortcut by category (Save as PDF from the print
panel to export). "Open Config File" opens the file itself (`Ghostty.App.openConfigFile()`); `open_config` (⌘,) opens Settings.

## Reuse from Settings

`ShortcutListView(catalog:query:category:includeUnbound:editor:selection:onRun:)`
is the list both windows use. With `editor == nil` it is the read-only guide.
A `ShortcutEditing` editor gets `isCustomized`, `tapKeycap`, `add`, `remove`,
`reset` and a per-row `accessory` view (all defaulted), rows show the raw
action, families stay expanded and unbound actions are listed.

## Tests

- Zig: `keybind_list.zig` — `entries: defaults, a sequence, flags, an unbind
  and a table`, `action_keys lists every action tag`.
- Swift: `macos/Tests/ShortcutGuide/KeybindCatalogTests.swift` — coverage,
  Other fallback, live-config merge (overrides, unbinds, sequences, globals),
  families, ordering, trigger normalization, search.

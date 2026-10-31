# Settings window

The macOS Settings window (⌘, / Ghoztty → Preferences… / the `open_config`
action, which no longer opens the file directly) edits the user's config
visually. Code: `macos/Sources/Features/Settings/`. Design history and the
approved mock: `temp/mocks/settings/` (not committed).

## Rules

- **The config file is the source of truth.** Settings never rewrites the
  file from parsed state. Each action is ONE surgical edit
  (`ConfigFileText`): only the lines for that key change; comments, blank
  lines, ordering, `config-file` includes, unknown keys, CRLF endings and a
  BOM survive byte for byte.
- **Every write re-reads the file first** (`ConfigFileStore.edit`), so an edit
  the user just made in their editor is never clobbered. Undo (the toast)
  only reverts if the file still holds exactly what Settings wrote.
- **Invalid values are never written.** Before writing, the new line(s) are
  parsed by Ghostty itself on a scratch config (`ConfigValidator`, via
  `ghostty_config_load_file` + diagnostics); a rejection shows on the row
  ("invalid value … — not saved"). Controls also bound their input (ranges,
  existing executables for shells, `KEY=VALUE` for env…).
- **Changes apply live** through the normal `reloadConfig()`; plain keys read
  their value straight from the file when the file sets them, so the UI
  updates without waiting for the reload round-trip.
- **Backups**: before the first change in an app session the file is copied to
  `~/Library/Application Support/<bundle id>/config-backups/<name>.<yyyyMMdd-HHmmss>`;
  the newest 10 are kept. Advanced → Backups → Restore… puts one back (itself
  backed up first). A missing or empty file isn't backed up.
- **Symlinked configs** (dotfiles) are written through the link to its target;
  the link stays a link. Writes are atomic and keep the file's permissions.
  A file that isn't UTF-8 is refused, untouched.

## Which file

`ghostty_config_preferred_path()` (= `file_load.preferredDefaultFilePath`, the
file "Open Config" opens, without creating it): App Support
(`~/Library/Application Support/<bundle id>/config.ghostty`, legacy `config`)
if non-empty, else the XDG file (`~/.config/ghostty/config.ghostty`, legacy
`config`) if non-empty, else App Support. The debug build's bundle id
(`com.dzearing.ghoztty.debug`) gives it its own App Support file.

**Load order and overrides** (`SettingsModel.loadSources`): XDG legacy, XDG,
App Support legacy, App Support, then `config-file` includes in the order
Ghostty processes them (after every default file; nested includes appended;
paths relative to the including file; `?` = optional). A key set by a file
that loads AFTER the user's file wins, so Settings shows that row read-only
("Set in work.ghostty, which loads after your config — Open") and refuses to
write it. A keybind trigger set in a later include is refused the same way.

## Repeatable keys

- Plain key: `set` rewrites the LAST line for the key (the one Ghostty
  honors) in place, keeping its indentation; earlier dead lines are left
  alone. `reset` removes every line for the key (including the bare flag form
  `maximize`).
- List keys (`font-family`, `font-feature`, …): `setList` keeps the longest
  run of existing lines that already matches the new list in order (so their
  comments stay put), removes the rest, and inserts new values next to the
  kept ones.
- Keyed keys (`keybind` by trigger, `palette` by index, `env` by name):
  `setKeyed` rewrites the last matching entry in place, drops earlier
  duplicates, and adds a new one after the key's last line. Trigger
  normalization (`cmd` = `super`, …) is the caller's `normalize`.

## Catalog (no hand-kept list)

`ghostty_config_schema_json(cfg, docs)` (`src/config/schema_json.zig`) emits,
for every `Config` field: formatted values (exactly what `+show-config`
prints), kind (`bool`/`int`/`float`/`enum`/`union`/`flags`/`string`/`other`),
`optional`, `repeatable`, enum/flag/union `options`, and (with `docs`) the doc
comment. On `ghostty_config_new()` it is the catalog (docs + defaults); on the
live config it is the effective values. A new key in `Config.zig` appears
under Advanced → All Settings automatically.

`SettingsPages.swift` is presentation only: which keys go on which page,
labels, and control types. `SettingsPagesTests` fails if a curated key or
enum option drifts from the schema (every option is checked against
Ghostty's own parser), or a key is on two pages. A popup also lists any schema
enum value without a curated label, so a new value is never hidden.

## Pages

Appearance (live preview, theme, font, cursor, window), Panes & Windows
(pane style, glass, dimming, `macos-window-gradient`, `macos-pane-sidebar`,
`macos-pane-min-width`/`-height`, `macos-hero-carousel-ratio`, new windows),
Terminal (shell, starting folder, env, scrollback, shell integration, copy &
paste, mouse, notifications), Keyboard, Sessions & Agent, Remote Machines,
Updates, Advanced (config file, includes, backups, All Settings).

- **Themes** (`ThemeCatalog`): bundled `Resources/ghostty/themes` plus
  `~/.config/ghostty/themes` (user themes win a name clash). Light vs dark is
  the background's luminance. "Light & dark themes" stores
  `theme = light:A,dark:B` and each tab lists ONLY themes of its kind, so the
  slots can't be mixed; a hand-edited mismatch shows a warning. "One theme"
  stores one name; the tabs are then just a filter. Switching to light & dark
  seeds the other slot from the same family when one exists (Latte ↔ Mocha).
- **Keyboard**: the shortcut guide (`users/dzearing/shortcut-guide`) owns the
  keybind catalog and list view; Settings will embed it with editing on
  (recording, conflicts, reset, `keybind = trigger=action` / `=unbind`
  lines). The "Open Shortcut Guide…" card appears only when something in the
  responder chain handles `showKeyboardShortcuts:`; until then the page shows
  the non-keybind keyboard settings and points at `keybind` under All
  Settings.
- **Sessions & Agent** reads the agent without spawning it
  (`LocalAgentManager.liveAgentPid` first; sessions and build only from a
  running agent).
- **Remote Machines** is read-only status plus "Host Settings…", the same
  prompt as the machine chooser's row menu (`MachineHostSettings.prompt`).

## Tests

- `ConfigFileTextTests` / `ConfigFileStoreTests` — the writer: comments,
  includes, repeatable/keyed keys, CRLF, BOM, quoting, flag form, missing
  file, symlinks, permissions, backups, outside edits, non-UTF-8.
- `SettingsModelTests` — validation before writing, include overrides,
  undo, keyed keybinds, load order.
- `SettingsPagesTests` — curated keys/options vs the schema.
- `SettingsViewRenderTests` — renders every page offscreen at 720 and 900pt
  (no window-server grants) and fails if any page is wider than the window;
  PNGs land in `$TMPDIR/ghoztty-settings-snapshots/` for inspection.
- Zig: `schema json: defaults, kinds and docs` (`src/config/schema_json.zig`).

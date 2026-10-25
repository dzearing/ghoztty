# Pane banners and link clicks

The sticky per-pane banner (`+set-banner`, OSC 7778, Cmd+R): markdown subset,
autolinking, the link-click table shared with viewer panes (`BannerLinkOpener`),
collapse/expand, persistence. Read before touching banner rendering, banner
links, or anything that opens a link from a pane.

## `ghoztty +set-banner`

Set or clear the sticky banner of a named pane or window. The banner is a native overlay rendered above the terminal content of a pane — it persists (survives scrolling, screen clears, and content updates) until changed or cleared. Setting a banner on a window target applies it to that window's focused pane (banners are per-pane).

```
ghoztty +set-banner --target=<name> [--clear] [text...]
```

- `--target`: Named pane or window. Required.
- `--clear`: Remove the banner (empty text does the same).
- All other arguments are treated as the banner text (multiple are joined with spaces).

Banner text supports a small markdown subset: `**bold**`, `*italic*` or `_italic_`, `__underline__`, `` `code` ``, and `[text](url)` clickable links (URL must include a scheme, e.g. `https://`). Note `__underline__` intentionally differs from CommonMark (where `__` is bold). `\` escapes the next character. Unterminated delimiters render literally. A literal `\n` in CLI banner text becomes a line break — banners can span multiple lines (display is capped at 10 lines).

**Autolinking.** Bare URLs and bare file paths become clickable without `[text](url)` syntax. A URL must carry a scheme — only `http://` and `https://` linkify, never a bare `www.example.com` or `config.io`, so prose is never falsely linked. A file path must start with `/`, `~/`, `./`, or `../`; the sigil is the whole signal (there is no filesystem check), which is why a bare relative `macos/Sources/Foo.swift` stays plain text. `~/` expands to the home directory and `./`/`../` resolve against **the pane's current working directory** at render time — a dot-relative path in a pane with no known cwd stays plain text rather than resolving against a guess. Trailing sentence punctuation stays outside the link (`See https://x.com.` links `https://x.com`), while brackets balanced *inside* the link are kept (`…/Foo_(bar)`). Autolinking never fires inside a `` `code` `` span, after a `\` escape, or inside an explicit `[label](url)` — the explicit link always owns its whole label.

**Link clicks.** A plain click hands the link *out* of Ghoztty; the modifiers bring it back in. Cmd opens a **viewer side pane** for either kind of link, and Cmd-Shift gives the link a surface of its own.

| | plain click | Cmd | Cmd-Shift |
|---|---|---|---|
| **URL** | default browser | side pane | new Ghoztty window |
| **file path** | reveal in Finder | side pane | open with default app |

A URL goes to the real browser by default because Ghoztty's `WKWebView` keeps its own cookie store with no relationship to Safari/Chrome — anything behind a login renders logged-out in a viewer pane, and OAuth sign-in never completes. A file path is only *revealed*, never opened, so a click can't launch whatever app claims the extension. A path that does not exist (autolinking has no filesystem check) reveals the nearest ancestor folder that does, since selecting a missing path in Finder does nothing visible. The right-click menu offers all of them (its first item is by contract the left-click default) plus Copy Link / Copy Path.

**This table is not banner-only.** It is `BannerLinkOpener`, and **viewer panes use the
same one** — for the links a viewer hands out (see Viewer Panes → Links) and for the
right-click menu on any link in a viewer page. One modifier scheme, one menu, one place
the ordering contract lives; a second copy is the drift the type exists to prevent. The
opener reaches its surface through a `LinkAnchor` (the terminal `SurfaceView` for a
banner, the `ViewerView` for a viewer pane), which is what supplies the window's
controller, the pane a side split anchors beside, and the origin directory a viewer
opened from the link inherits.

**Lists.** Consecutive lines that begin with a list marker render as a list block with table-like row spacing and a **shared marker gutter**, so every item's content left-aligns regardless of marker kind (bullets, numbers, and checkboxes in one run all line up). Supported markers:

- `- ` or `* ` → an unordered **bullet** (`•`).
- `1.`, `2.`, … (digits, a period, then a space) → an **ordered** item, rendered with the source number. A decimal like `1.5` (no space after the dot) stays plain text.
- `[x]`/`[X]` (checked) and `[ ]` (single space, unchecked) → a read-only **task-list checkbox**, drawn as a **native box** (rounded 2px corners; checked shows a green check on a faint green wash), not a plaintext glyph. A `- `/`* ` directly before a checkbox is the checkbox's marker, not a separate bullet (`- [x] done`). Checkboxes are display-only (no interactivity), and `[x](url)` is still a link (the `x` is link text). Checkboxes in **table cells** render the same native box. A checkbox that appears mid-paragraph in a wrapping (non-list) text line falls back to the `☑`/`☐` glyph.

**Separators.** A line of 3+ of the same `-`, `*`, or `_` (spaces allowed — `---`, `***`, `___`, `- - -`) is a **thematic break**, rendered as a full-width horizontal divider between the blocks above and below it (e.g. to separate a title, a table, and a trailing note). A `- `/`* ` bullet or `**bold**` on its own line is unaffected (they carry non-marker content or mixed characters). Each rule counts as one line toward the 10-line display cap.

Banners also support standard markdown pipe tables, rendered as an aligned grid with a bold header row: a `| a | b |` header line immediately followed by a `|---|---|` separator with the same column count, then `| 1 | 2 |` body rows. Separator cells may carry `:` alignment markers (`:---` left, `:---:` center, `---:` right). Cells support the full inline subset; `\|` puts a literal pipe inside a cell. Ragged body rows are padded/truncated to the header width. The separator row doesn't render; every other table row counts toward the 10-line display cap (a row still counts once no matter how many lines its cells wrap to). **Long cell text word-wraps** onto multiple lines and the row grows to fit, rather than truncating to one line — matching a normal markdown renderer. Column widths derive from the pane's current width, so the banner reflows live as the pane is resized and never blocks the pane from shrinking (even a long unbroken token breaks mid-string). A cell is capped at **3 wrapped lines** — a cell that would wrap further (e.g. a long unbroken string in a very narrow pane) is tail-truncated with an ellipsis on its last visible line, so one nasty cell can't blow up the banner height. A cell that contains a task-list checkbox stays a single line (its native box can't reflow around wrapping text), like list checkbox rows.

```bash
ghoztty +set-banner --target=dev "**Build status**\n| Job | State |\n|---|---:|\n| lint | ok |\n| tests | **3 failed** |"
```

```bash
ghoztty +set-banner --target=dev "**PR #123** — _3 files_, +120/−45 — [view](https://github.com/org/repo/pull/123)"
ghoztty +set-banner --target=dev --clear
```

Processes can also set the banner from inside the pane via OSC escape sequence: `\033]7778;<text>\007` (empty text clears). The interactive equivalent is Cmd+R ("Set Pane Banner…", also in the command palette), which opens a multi-line editor for the focused pane's banner (Return inserts a newline, Cmd+Return saves, Escape cancels). Cmd+R only reaches this while a **terminal** pane is focused — a focused viewer pane takes Cmd+R for reload (see Viewer Panes).

## Collapse / expand

Clicking the card (or its chevron) collapses it to its title row. **The user
never sees the terminal resize:**

- The terminal is resized ONCE, at the click, while a frozen copy of its last
  frame stands in for it (`SurfaceView.frozenFrame`: a copy of the renderer's
  IOSurface — same pixels, format and color space — not the surface itself,
  which the renderer draws into again). The live terminal comes back once it
  has redrawn at the new size and its frames have stopped changing
  (`resizeOutOfSight`, capped at 0.5s). That resize skips the 100ms debounce
  (`ghostty_surface_flush_resize`), so a shell's prompt redraw lands in a frame
  or two. (Resizing while the card animated made the prompt jump, vanish for a
  frame, and jump again.)
- The copy is shown by a view that sets its layer's contents in `updateLayer`
  (`FrozenLayerView`): contents set on a layer-backed view from outside are
  wiped by its next display.
- The copy and the live terminal move to where the content will land, along
  one path with the card's curve (`BannerGlide`); the core predicts the shift
  with the grid's own resize rules before resizing
  (`ghostty_surface_predict_resize_shift`). A prompt at the **top** rides the
  card's edge; content laid out to the **bottom** (a shell at the end of its
  scrollback; a full-screen program on the alternate screen, taken to lay out
  to the bottom like an agent's input box) holds still while the card covers or
  uncovers rows above it (masked at the card's animated edge, `bannerReveal`).
- The renderer's layer refuses a frame drawn earlier than the one it shows
  (`IOSurfaceLayer` frame sequence): on any resize, an async frame of the OLD
  grid at the NEW size could otherwise land after the synchronous redraw and
  leave an idle pane showing the wrong rows.
- The collapsed state lives on the surface (`paneBannerCollapsed`, ephemeral;
  a cleared banner comes back expanded).

Tests: `BannerCollapseWindowTests` (recorded at the display's frame rate;
frames in `/tmp/banner-collapse` and `/tmp/banner-collapse-prompt[-agent]`;
the prompt cases run in a plain local pane and in an agent-backed one, whose
shell redraws a round trip later).
Banners are persisted per pane in the session-layout manifest (keyed to the stable pane id), so a session-persistence restore brings them back with their text intact — across app quit/relaunch/upgrade re-attach and across an agent-restart relaunch alike. `+list --json` reports each terminal pane's current banner in a `banner` field (absent when no banner is set), which is also the CLI way to read a banner back.

A banner with a **title** — an `## ` heading on its first line, or a one-line banner opening with a standalone `**bold**` run — also **names its pane** in the pane sidebar and on a stacked pane's strip, in place of the pane title (see Stacked panes).

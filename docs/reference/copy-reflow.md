# Copy cleanup (TUI reflow)

Read before touching copy/selection formatting, `src/terminal/hard_wrap.zig`,
or regex link detection across rows.


**Cmd+C out of a TUI pastes as clean prose.** A TUI that word-wraps its own
output (Claude Code, anything built on Ink / wrap-ansi) writes every visual row
itself — real newlines, re-indented to the left margin of its text block — so a
plain copy brought the margin along on every line and broke each paragraph into
rows. That is not a soft-wrap bug: terminal autowrap is recorded in the grid
(`Row.wrap`) and was always unwrapped. These bytes genuinely exist, so the fix is
a **copy-time transform**, `formatter.Options.reflow`:

- **Rejoin**: a row the TUI hard-wrapped joins the row above it with a space —
  or with *nothing* when the wrap broke a token longer than a whole line (a URL,
  a path), so it comes back whole. The continuation's re-indentation is dropped.
- **Dedent**: the left margin shared by the selected lines is stripped;
  indentation deeper than it (code, nested lists) is kept. A first row the
  selection starts mid-way through doesn't count toward the margin, and a TUI
  gutter glyph (`⏺ `, `❯ `) hangs in the margin instead of pinning it at zero.
- Always on, on plain Cmd+C (and copy-on-select). Not a config flag. Rectangle
  selections (Option-drag) are left exactly as selected.

**The signal is geometry, and it is a heuristic** (`src/terminal/hard_wrap.zig`,
the one definition every caller shares). A row continues the one above it when
both belong to one block — the continuation sits exactly at the text column of
the row above (its margin, or the hanging indent after a bullet), opens with no
list marker / quote bar / gutter glyph / `label:`-after-`label:`, and neither row
is a table, box drawing, or columnar output (3+ interior blanks) — **and** the
word-wrap test holds: the next row's first token would not have fit in the
columns left on the row above (≤ 20 of them). A block in which any nearby row
*fails* that test while ending near the edge (a "near miss": a word that would
have fit was left behind) is never rejoined at all, because no word wrapper does
that — it is how a 72-column `git log` body in an 80-column pane stays
byte-identical instead of coming out half-joined. Every ambiguity resolves to
leaving the newline: a missed join costs what was already on screen, a wrong one
corrupts code.

**Links use the same seams.** Regex URL detection follows hard-wrapped rows
(`SelectLine.hard_wraps` + reflow), so a URL a TUI broke across re-indented rows
is one link — hover highlight (the renderer computes the viewport's seams under
the terminal lock, `hard_wrap.seams`), click, link preview and Copy URL all see
the whole URL, and the skipped margins are not part of it (`StringMap.Match.covers`).

| Caller | Reflowed? | Why |
|---|---|---|
| Copy / copy-on-select (`copySelectionToClipboards`, all formats) | yes | text leaving the terminal |
| `ghostty_surface_read_selection` (Services, accessibility, Look Up) | yes | the selection as the user means it |
| link match, click, hover preview, `copy_url_to_clipboard` | yes | a link across a seam reads back whole; one-row links are unchanged |
| `ghostty_surface_read_text` (`+read`, screen-contents APIs), quicklook word | no | reading the screen as laid out |
| `Surface.selectionString` (`search_selection`) | no | the needle must match the screen, which holds the wrapped form |

Known limits: a long token the TUI moved whole onto a fresh row keeps the
newline before it when the row above stopped >20 columns short; a TUI that wraps
narrower than the pane (a right margin) is not rejoined; two genuinely separate
lines that happen to pass the wrap test are joined — unavoidable from bytes
alone. Tests: `hard_wrap.zig`, `Screen: selectionString reflow …` (real
Claude Code renders, plus `ls -la`/`git log` that must stay byte-identical),
`StringMap … TUI hard wrap`, `renderCellMap URL across a TUI hard wrap`.

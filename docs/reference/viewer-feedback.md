# Worktree feedback capture

The viewer nav bar's feedback button, the composer, quoting, and the
`temp/feedback/new/` report format consumed by `/process-feedback`. Read before
touching the composer, `selection.js`, or the report schema.


When a viewer pane's content can be attributed to a **git worktree**, its
navigation bar gains a **feedback button** (labeled with the worktree's
basename, full path on hover) that opens a composer toolbar below the nav bar.
On send it writes a report — plus any pasted screenshots — into
`<worktree>/temp/feedback/new/` for an external watcher to drain (Ghoztty produces
the queue; consuming it is separate and not built here).

- **Provenance (strategy D — port lookup first, pane-origin fallback).** The
  worktree is derived live from the pane's *current* location, re-resolved on
  every navigation (a pane can move between a file, `localhost:3000`, and a
  remote site, each a different worktree or none):
  1. **File viewers** → the viewed file's own directory. An image pane is a
     file viewer for this purpose like any other, so a screenshot sitting in a
     repo files feedback to that repo.
  2. **`http://localhost:PORT` / `127.0.0.1` / `0.0.0.0` viewers** → the port's
     listening pid's cwd, via `lsof` (`-iTCP:<port> -sTCP:LISTEN -t`, then
     `-p <pid> -d cwd -Fn`) run off the main thread. lsof, not
     `proc_pidinfo`, because there is no port→pid syscall.
  3. **Fallback** (remote site, blank pane, or a port with no listener) → the
     pane's **origin directory**: `--working-directory` at `+split --view=` /
     `+new-window --view=` time, else the caller's cwd. `+split` now seeds the
     caller's cwd as `--working-directory` for `--view=` splits (terminal
     splits are unchanged so cwd inheritance still works). The origin is
     persisted in the session manifest (`viewerOriginDirectory`).

  Whatever directory results is resolved to a repo root via `git -C <dir>
  rev-parse --show-toplevel` (**any** working tree counts — a linked worktree
  or the main checkout). No repo ⇒ no feedback button. Resolutions are cached
  per (location, origin) for 15s so navigation never stutters and a dev server
  started later still makes the button appear.
  The button is **icon-only**, in the same 24pt square as the other chrome
  controls; the destination is on its tooltip and in the composer footer.
- **Composer.** A **pill** that grows with its content (one line up to ~6),
  with two **circular buttons inside its trailing edge**: `+` takes an
  interactive screen snapshot (`screencapture -i -o` to a temp file — never
  `-c`, which would clobber the user's clipboard), and `↑` sends. `Enter`
  inserts a newline, `Cmd-Enter` sends, `Escape` closes.
  Pasting a screenshot inserts an **`[Image #N]` chip** — one atomic
  `NSTextAttachment` (a single `U+FFFC` character), so it selects, copies, and
  deletes (one Backspace) as a unit. A **thumbnail carousel** below the input
  mirrors the chips; clicking a chip scrolls to its thumbnail and vice versa.
  **Chip numbers are stable, not positional** — deleting `[Image #2]` leaves
  the sequence 1, 3 in both the text and the carousel (never renumbered), so a
  number always points at the same image. Composer contents survive
  toggling the toolbar closed/open and a detach/undo (they live on the pane,
  not the toolbar).

  **⇧⌘S** adds a screenshot from the keyboard while the composer has focus
  (free: the app's shift+cmd letters are t/z/w/d/f/g/v/n/r/[/], and macOS's own
  capture shortcuts are ⇧⌘3/4/5).

  The text view **must** override `readablePasteboardTypes` to include image
  types. AppKit validates the Edit▸Paste menu item against that list, so
  without it Cmd-V is *disabled* for an image-only clipboard and the paste
  override never runs — a silent no-op. `importsGraphics = true` does **not**
  add those types; only the override does.
- **Quoting.** Selecting text in a viewer pops a small **Quote / Copy**
  toolbar (standard `format_quote` / `content_copy` glyphs) above the
  selection. It lives in `src/viewer/selection.js` and is injected as a
  **`WKUserScript` into every page** — it cannot ship inside `viewer.js`,
  which is a `<script src>` in `viewer.html` and therefore only ever runs on
  the bundled template, which is why quoting used to work on markdown and do
  nothing on a website. Because it runs inside pages we do not control, its UI
  lives in a **shadow root** so page CSS cannot restyle or hide it. *Copy* puts it on the clipboard; *Quote* opens
  the composer (if closed) and inserts the passage at the caret as its own
  block — indented, with a tinted panel and an accent bar down the left, drawn
  in `drawBackground(in:)` (a background-color attribute paints only tight line
  boxes, with no bar and no rounding). The run carries a `feedbackQuoteID`
  attribute, so deleting it drops its metadata from the report — the same
  derive-from-storage rule the image carousel uses. The body renders it as a
  real markdown blockquote. Typing never inherits quote styling: AppKit
  carries `typingAttributes` over from text around the caret *including text
  just deleted*, so select-all + delete + type used to leave the user trapped
  writing inside the quote (and resurrected its metadata). The delegate
  refuses quote attributes at the source.

  Each quote carries **referential context** so an agent can find what was
  being discussed (text alone is ambiguous — the same sentence can appear
  twice): the containing section's `headingId`/`headingText`, the containing
  block's `blockSelector` and full `blockText`, `offsetInBlock`,
  `documentOffset`, and — for file viewers — a 1-based **`sourceLine`**,
  resolved natively at send time by searching the file for the passage
  (mapping rendered DOM back to markdown source is unreliable; searching is
  not). It reports nil rather than a confidently wrong line.
- **Report output.** One **self-contained folder per submission**, so a report
  can be moved or handed to an agent as a unit:

  ```
  <worktree>/temp/feedback/new/<timestamp>-<suffix>/
      report.json
      images/image-1.png
  ```

  The whole folder is built under `temp/feedback/.staging/` and moved into place
  with a single **atomic `rename`** (same filesystem), so a watcher sees either
  nothing or a complete report with every image already present. Promoting one
  to an `in-progress/` queue is likewise a single `mv` — image paths in the
  report are folder-relative, so they survive the move.
  The queue lives under **`temp/`** because that name is already gitignored
  here (`.gitignore`) and conventionally elsewhere; a top-level `.feedback/`
  was not, so every filed report showed up as untracked in `git status`.
  **Format is JSON** (not markdown-frontmatter: a multi-line prose body with a
  `---` or `key:` line breaks naive frontmatter splitting; JSON has one parse
  path). `body` is markdown with each chip rendered as a
  `![Image #N](images/image-N.png)` reference relative to the folder.
  Alongside it, deliberately generous context so a downstream agent needn't ask
  follow-ups: `source` (`location`, `kind` — `file`, `web`, or **`image`**,
  which tells a reader up front that there will be no `selection` and no
  `quotes`, `filePath`, **`relativePath`** — repo-relative, `pageTitle`,
  **`selection`** — the text the user had selected, i.e. what they were
  pointing at, `paneID`, `viewport`), `worktree` (`path`,
  `name`, **`branch`**, **`commit`** — the exact revision they saw), `app`,
  `quotes` (see above), and `images` (with pixel dimensions and byte size). On success the composer
  clears and the toolbar shows a "Filed …" confirmation before closing.

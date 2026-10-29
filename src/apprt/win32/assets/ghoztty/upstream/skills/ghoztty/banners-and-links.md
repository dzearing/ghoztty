# Banners and `ghoztty://` links

Read from the `ghoztty` skill for banner formatting (headings, tables, links) and for linking a document to a terminal.

## `ghoztty +set-banner`

Set or clear a **sticky banner** rendered above a pane's terminal content. The banner is a native overlay — it persists across scrolling, screen clears, and content updates until you change or clear it. Ideal for pinning status, progress, or links (e.g. a PR link) above the pane you're working in.

```
ghoztty +set-banner --target=<name> [--clear] [text...]
```

| Flag / Arg | Description |
|------------|-------------|
| `--target=<name>` | Named pane or window. Required. For a window target, the banner is applied to its focused pane (banners are per-pane). |
| `--clear` | Remove the banner. Empty text does the same. |
| Positional args | Banner text (multiple args are joined with spaces). |

**Formatting** (markdown subset):

| Syntax | Result |
|--------|--------|
| `# text` … `###### text` | **heading** — larger than body text, on its own line. A banner's title line needs one; without a leading `#` it renders at body size and the banner reads as a wall of same-sized text. Requires the space after the `#`. |
| `**text**` | bold |
| `*text*` or `_text_` | italic |
| `__text__` | underline (differs from CommonMark, where `__` is bold) |
| `` `text` `` | monospace code |
| `[label](https://url)` | clickable link — the URL must include a scheme |
| `\*`, `\[`, `\\`, `\|`, … | backslash escapes the next character |
| `\n` | line break — banners can span multiple lines (display capped at 10) |

Styles nest (`**bold with a [link](https://…)**`). Unterminated delimiters render literally.

**Tables** (standard markdown pipe syntax): a `| a | b |` header line immediately followed by a `|---|---|` separator with the same column count, then `| 1 | 2 |` body rows, render as an aligned grid with a bold header. Separator cells accept `:` alignment markers (`:---` left, `:---:` center, `---:` right). Cells support the full inline subset; `\|` puts a literal pipe inside a cell. Ragged rows are padded/truncated to the header width. The separator row doesn't render, but every other table row counts toward the 10-line cap.

```bash
ghoztty +set-banner --target=dev "**PR #123** — _3 files_, +120/−45 — [view](https://github.com/org/repo/pull/123)"
# A titled banner: the title is a heading line, so it stands out from the body.
ghoztty +set-banner --target=dev "# Deploy blocked\nstaging smoke tests are red — [run 4821](https://ci.example.com/4821)"
ghoztty +set-banner --target=dev "## Build status\n| Job | State |\n|:---|---:|\n| lint | ok |\n| tests | **3 failed** |"
ghoztty +set-banner --target=dev --clear
```

Multi-line banners are **collapsible** in the UI: a chevron button (top-right) or a click anywhere on the banner background toggles between the full banner (default) and a collapsed single-line preview with a bottom fade. This is a display-only, per-pane UI state — it doesn't change the stored banner text, and there's no CLI flag for it.

Processes inside the pane can also set the banner without IPC via OSC escape sequence: `\033]7778;<text>\007` (empty text clears; note the OSC parser drops raw newlines, so OSC banners are single-line — use the CLI for tables/multi-line). Interactive users can press Cmd+R ("Set Pane Banner…", also in the command palette) for a multi-line editor (Return = newline, Cmd+Return = save).

## Pin a live status banner above your working pane

Post a PR link plus live stats above the pane you're working in, and keep it updated as work progresses. The banner is sticky — it stays put while the terminal scrolls underneath.

```bash
# When the PR is opened
ghoztty +set-banner --target=dev "**PR #123** — _draft_ — [view](https://github.com/org/repo/pull/123)"

# Update as work progresses (idempotent — just set it again)
ghoztty +set-banner --target=dev "**PR #123** — _3 files_, +120/−45 — CI __running__ — [view](https://github.com/org/repo/pull/123)"
ghoztty +set-banner --target=dev "**PR #123** — CI **green** — ready for review — [view](https://github.com/org/repo/pull/123)"

# Clear when done
ghoztty +set-banner --target=dev --clear
```

## Focus links: the `ghoztty://` URL scheme

A **link** can bring a Ghoztty window or pane to the front. This is the piece
that makes a generated document useful: a worktree dashboard, a status report,
a build summary can each carry a "jump to that terminal" link that works from a
browser, from a rendered doc in a viewer pane, or from a pane banner.

```
ghoztty://focus/<target>
```

That is the **only** form and `focus` is the **only** verb. `<target>` is
percent-decoded and handed to the same resolver `--target` uses, so it accepts
everything a `--target` accepts:

| `<target>` | Example |
|---|---|
| a registered window name | `ghoztty://focus/dev` |
| an auto-assigned window name | `ghoztty://focus/window-3` |
| a registered pane name | `ghoztty://focus/logs` — a link has no window of its own, so this fails ("can't tell which") once two windows have a `logs` pane; prefer a pane id |
| a pane id (`$GHOZTTY_PANE_ID`, case-insensitive) | `ghoztty://focus/8b1f1a2c-3d4e-4f50-9a6b-7c8d9e0f1a2b` |

Percent-encode anything awkward: `ghoztty://focus/my%20window`. Everything
after the verb is ONE target, so a name containing `/` survives either way
(`focus/feat%2Flogin` and `focus/feat/login` both mean `feat/login`).

**Nothing else is possible through a link — by design.** There is no
`ghoztty://new-window`, no `ghoztty://send-keys`, no way to run a command. Any
web page the user visits can fire a URL scheme with no prompt and no
same-origin check, so anything that could spawn a shell or type into a pane
would be remote code execution behind an `<a href>`. Raising a window that
already exists is the one verb whose worst case is a nuisance. If you find
yourself wanting a second verb, use the CLI — it is reachable only by code
already running as the user — and do not propose widening the scheme.

**A link that can't be followed says so.** If the target isn't open — it was
closed, it was never named, or Ghoztty was only just launched by this very
click — Ghoztty shows a warning naming the target ("Can't focus "dev""), and a
`ghoztty://` link it doesn't understand gets a warning naming the URL. What it
never does is act on a failure: no window is created and no "closest" window is
focused as a consolation. A burst of links produces one dialog, not one each.

So a stale link in a generated document is visible rather than mysterious —
but it is still a bad link. Regenerate dashboards rather than letting them rot,
and prefer targets that will still exist (below).

### Emitting links from a generated document

Write ordinary anchors:

```html
<a href="ghoztty://focus/ghoztty-url-protocol">ghoztty-url-protocol</a>
<a href="ghoztty://focus/8b1f1a2c-3d4e-4f50-9a6b-7c8d9e0f1a2b">that pane</a>
```

**Pick the target so the link survives.** This is the part that decides whether
a dashboard still works tomorrow:

| Situation | Target to write | Why |
|---|---|---|
| You are *creating* the window (e.g. one per worktree) | the `--target=` name you gave it | You chose it, so you can regenerate the same link without asking the app anything. |
| The window already exists and you are just describing it | the pane `id` from `+list --json` | Stable for the pane's whole life, including across app relaunch and session restore. |
| Linking to the pane you are running in | `$GHOZTTY_PANE_ID` | Already in your environment — no `+list` round trip. |

Prefer a **name you control** over an auto-assigned `window-N`: the auto names
are handed out per app run, so `window-3` can point at a different window after
a relaunch. Name the window when you open it and the link is stable by
construction:

```bash
# one window per worktree, named after it — the link is then predictable
for wt in ~/git/*/; do
  name="$(basename "$wt")"
  ghoztty +new-window --target="$name" --working-directory="$wt"
  echo "<li><a href=\"ghoztty://focus/$name\">$name</a></li>" >> dashboard.html
done
```

To build a dashboard from what is *already* open, walk `+list --json`. `splits`
is a recursive tree, so use `..` to pick out the `terminal` objects:

```bash
ghoztty +list --json | jq -r '
  .data.windows[] | .tabs[] | [.. | .terminal? | select(.)] | .[] |
  "<li><a href=\"ghoztty://focus/\(.id)\">\(.title)</a></li>"'
```

Markdown works too, in a viewer pane or anywhere else that renders links:

```markdown
| Worktree | Terminal |
|---|---|
| `ghoztty` | [open](ghoztty://focus/ghoztty) |
```

And in a banner (`[label](url)` needs the scheme, which this has):

```bash
ghoztty +set-banner --target=dev "Tests failing in [the build pane](ghoztty://focus/build)"
```

Clicking a `ghoztty://` link **inside** Ghoztty — a viewer pane, a pane banner
— is handled in process rather than routed back through macOS, so it always
means "this app". A banner link ignores the usual Cmd / Cmd-Shift modifiers
(there is no content to put in a pane or a window) and its right-click menu
offers just **Focus in Ghoztty** and **Copy Link**.

> **Debug builds use `ghoztty-debug://`.** The two builds register different
> schemes so LaunchServices never has to choose between them. Both builds
> *accept* both spellings for links clicked inside Ghoztty, so a document that
> hardcodes `ghoztty://` still works when a debug build renders it — but a link
> clicked in a **browser** reaches only the build that registered that exact
> scheme. Write `ghoztty://` unless you are specifically driving a debug build.

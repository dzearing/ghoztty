# Viewer panes, images and git diffs

Read from the `ghoztty` skill when you need more than its one-line `+split --view=` recipe.

## Viewer panes (`--view=<path-or-url>`)

Both `+new-window` and `+split` accept `--view` to open a **viewer pane** instead
of a terminal. This is the built-in way to honor "open the README in a side pane",
"show that doc beside this", or "preview this markdown" — **do not** shell out to
`less`/`cat`/`open` for that. The pane renders:

- **Markdown** files — fully rendered (GitHub styling, code highlighting, task
  lists), with **live reload** on save (scroll position preserved).
- **HTML** files (`.html`, `.htm`) — rendered as a **live page**, not as
  source: the file's own CSS, JS, images, and fonts load from its directory,
  and it **live-reloads on save** (scroll preserved). A static mock or
  prototype needs no server. Two limits: assets must live under the page's own
  directory (no `../shared/app.css`), and only the HTML file itself is
  watched — `+reload` picks up a changed sibling stylesheet or script.
- **Images** (`.png`, `.jpg`/`.jpeg`, `.gif`, `.webp`, `.heic`/`.heif`,
  `.avif`, `.tiff`, `.bmp`, `.ico`/`.icns`, `.svg`) — a real image viewer, not
  an `<img>` on a page: trackpad pinch-to-zoom, two-finger pan with elastic
  edges, and double-click (or two-finger double-tap) to toggle **best-fit ⇄
  100%**. It opens at best-fit, never upscaled past 100%, re-fits when the pane
  is resized, and live-reloads on save. Animated GIFs animate. **Cmd-F is
  declined** in an image pane — there is no text to find.
- **Text / code** files — syntax-highlighted, read-only.
- **Websites** — any `http(s)://` URL (this is the only mode that uses the
  network; file rendering is fully offline via bundled assets).

Every viewer pane carries the same **navigation bar** — back / forward /
reload / home and an editable address field — **always visible, in every
mode**. (It used to hover-peek in markdown and code panes; it no longer does,
so the pane's content is laid out below it from the first frame and never
reflows under the pointer.)

It follows the system/app light-dark theme automatically. Viewer panes are
**view-only** (no editing) and are ordinary leaves in the split tree, so
`--name`, `--target`, `--split-percent`, `+close`, and `+rearrange` all work on
them. Idempotent: re-running with the same `--name` in the same window reuses
the existing viewer instead of opening another (a different `--view` under that
name fails — `+close` it first). (Minor gap: while a viewer pane is focused, some
`goto_split` keybindings may not fire — click a terminal pane to regain them.)

```bash
# Open a README in a rendered pane to the right of YOUR pane
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --view=README.md

# A doc pane at 45% width, named so you can refocus/close it later
# (--working-directory here only resolves the relative --view path)
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --split-percent=45 \
  --name=docs --working-directory=/path/to/project --view=docs/design/overview.md

# A standalone viewer window for a webpage
ghoztty +new-window --target=changelog --view=https://example.com/changelog

# A screenshot beside the work (zoomable, not a terminal dump)
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --name=shot \
  --view=temp/feedback/new/2026-08-26-ab12/images/image-1.png

# Editor + live-rendered markdown preview, side by side (two steps)
ghoztty +new-window --target=notes --command="nvim NOTES.md"
ghoztty +split --target=notes --direction=right --name=preview --view=NOTES.md
```

## Git diff panes (`--view=git-diff:…` / `--view=git-status:`)

A viewer can also render a **git diff**: a changed-files tree with a filter on
the left, red/green syntax-highlighted hunks on the right, and
next/previous-change + unified ⇄ side-by-side controls in the nav bar. This is
how to answer "show me what's changed on this branch" or "show me my git
status" — **do not** dump `git diff` into the terminal for that.

It is the same `--view=` flag, so `--name`, `--pane`, `--split-percent`,
`+reload`, `+close`, and `+list` all work exactly as above.

| `--view=` | Shows | The user says |
|---|---|---|
| `git-status:` | Working tree: staged, unstaged, untracked, in three sections | "my git status", "what have I changed", "uncommitted changes" |
| `git-diff:main...HEAD` | `HEAD` against the **merge base** with `main` | "changes on this branch", "what's on my branch vs main" |
| `git-diff:` | This branch against the repo's mainline, auto-detected | "changes in this branch", no base named |
| `git-diff:<sha>` | That ONE commit's own changes | "what changed in `<sha>`", "show me commit `<sha>`" |
| `git-diff:<a>..<b>` | The literal comparison of two revisions | "diff `<a>` against `<b>`", "what's changed since `<tag>`" (`<tag>..HEAD`) |

Two things to get right:

- **Three dots for "this branch", two for "between these two."** `main...HEAD`
  goes against the merge base, which is what a person means by "what's on my
  branch" — it excludes whatever landed on `main` since they branched.
- **A bare revision means THAT COMMIT**, not "diff against it".
  `git-diff:abc123` answers "what changed in abc123"; a comparison is
  `git-diff:abc123..HEAD`.

**`--working-directory` is the exception to the usual rule.** For a plain split
you skip it (a split inherits your pane's cwd), but a `git-*:` spec is not a path — it is never path-resolved, and
`--working-directory` is what picks the **repository** the diff is taken in. A
split inherits your cwd, so you can omit it when you are already in the repo;
pass it whenever the diff is about a repo you are not sitting in. A directory in
no git working tree renders an explanatory card rather than an empty pane.

```bash
# "show me changes in the current branch against main" — beside your pane
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --split-percent=60 \
  --name=diff --view=git-diff:main...HEAD

# "show me files in my git status", for a repo you are NOT cd'd into
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --name=status \
  --working-directory=/path/to/project --view=git-status:

# one commit, and an arbitrary range
ghoztty +split --pane="$GHOZTTY_PANE_ID" --name=commit  --view=git-diff:a1b2c3d
ghoztty +split --pane="$GHOZTTY_PANE_ID" --name=release --view=git-diff:v1.2.0..v1.3.0

ghoztty +reload --target=diff        # re-run after new commits land
```

**The pane's location IS the spec.** `+list --json` reports it as the pane's
`url`, so you can tell whether a diff pane is already open on the right revspec
before opening another; `+reload`/Cmd+R re-runs it; the address bar shows and
accepts it. Since `--name` is idempotent, re-splitting with the same name and
spec reuses the existing pane, and a different spec under that name fails — to
retarget it, `+close` it and re-split.

A `git-status:` pane **re-checks the working tree every 2s**, so it needs no
`+reload` after an edit or a `git add`. A commit or range pane is a fixed pair
of trees and is not polled.

## Auto-preview conventions (build → show it beside the work)

When you produce something previewable, **show it in a viewer pane automatically**
— don't wait to be asked, and don't paste raw output into the terminal. Use a
**1/3 ⁄ 2/3 layout**: work panes stacked vertically in the left third, the
preview filling the right two-thirds. The `--split-percent=66` gives the new
right pane 2/3 of the width, leaving 1/3 for your work column.

**Trigger 1 — you author or edit a Markdown design doc / README / spec.**
Open it in a right-hand 2/3 viewer. Markdown viewers **live-reload on save**, so
you set this up once and every edit re-renders automatically (no `+reload`).

```bash
# From your working pane: doc preview fills the right 2/3
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --split-percent=66 \
  --name=preview --view=docs/design/spec.md
# ...keep editing docs/design/spec.md — the preview re-renders on each save.
```

**Trigger 2 — you scaffold or edit a static mock HTML app / prototype.**
Point the preview straight at the **file**. An `.html`/`.htm` file opened with
`--view` renders as a **live page** — its own CSS, JS, and images load from the
file's directory — and it **live-reloads on save**, exactly like markdown. No
server, no `+reload`.

```bash
# Preview the mock in the right 2/3 — that's the whole setup
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --split-percent=66 \
  --name=preview --view=/path/to/app/index.html
# ...keep editing index.html — the page re-renders on each save.
```

Two things to know:

- Only the **viewed file** is watched. Editing a sibling `style.css` or
  `app.js` does not trigger a reload on its own — `ghoztty +reload
  --target=preview` picks those up (it bypasses the cache).
- The page may read assets **inside its own directory** only. A prototype that
  reaches up out of its folder (`../shared/app.css`) won't resolve — either
  keep assets under the page, or serve the project (Trigger 3).

**Trigger 3 — the app needs a dev server** (a framework app: Vite, Next,
webpack, `npm run dev`). A build step or a router means there is no static file
to point at, so **host it** and view the URL. Run the dev server in a work pane
in the left third, then point the preview at its URL. URL viewers do **not**
auto-reload unless the dev server itself pushes HMR, so `+reload` the preview
after edits.

```bash
# 1. Run the dev server from a work pane stacked below your session (left third)
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=down --name=server \
  --working-directory=/path/to/app --command="npm run dev"

# 2. Preview the running app in the right 2/3
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --split-percent=66 \
  --name=preview --view=http://localhost:3000

# 3. After each edit, refresh the preview (URL viewers don't live-reload)
ghoztty +reload --target=preview
```

**Locking the exact 1/3-stacked ⁄ 2/3-preview layout.** When you have several
work panes and want them tiled deterministically in the left third with the
preview pinned to the right 2/3, name every pane and `+rearrange`. With no
`--target` it rearranges the window you are running in:

```bash
ghoztty +rearrange --layout='{
  "direction": "horizontal",
  "ratio": 33,
  "left": {
    "direction": "vertical",
    "ratio": 50,
    "left": {"pane": "session"},
    "right": {"pane": "server"}
  },
  "right": {"pane": "preview"}
}'
```

## `ghoztty +reload`

Reload a named **viewer pane** in place — no close/reopen. Website viewers re-fetch the page from origin (bypassing caches); file viewers re-render the file preserving scroll position, and image viewers re-decode it keeping the zoom. Local file viewers already live-reload on save, so this mainly matters for `--view=<url>` panes (e.g. refresh a dev-server preview after a rebuild) — and for an `.html` pane whose sibling CSS/JS changed, which the save-watcher does not see.

```
ghoztty +reload --target=<name>
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Named window or pane (or a pane id). Required. For a window target, the reload applies to its focused pane. |

- Targeting a terminal pane fails with `... is a terminal pane, nothing to reload` (exit 1) — mirroring how terminal-only commands reject viewer panes.

```bash
# Refresh a local dev-server preview after rebuilding
ghoztty +split --target=dev --name=preview --view=http://localhost:3000
# ... rebuild ...
ghoztty +reload --target=preview
```

## Review your own changes beside the work

Open the branch diff next to the pane you're working in, then re-run it as commits land. A `git-status:` pane is the better choice while you're still editing — it re-checks the working tree every 2s on its own.

```bash
# What's on this branch, against main
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --split-percent=60 \
  --name=diff --view=git-diff:main...HEAD

# ... commit some work ...
ghoztty +reload --target=diff

# Or watch the working tree live instead — no reload needed
ghoztty +split --pane="$GHOZTTY_PANE_ID" --direction=right --name=status \
  --view=git-status:
```

## Mistakes

- **Don't `less`/`cat`/`open` a file to show it in a pane** — that dumps raw text (unrendered markdown) or opens an external app. Use `+split --view=<path>` for a rendered, live-reloading viewer pane.
- **Don't `open` an image (or hand the user a path) to show them a picture** — `open` launches Preview outside Ghoztty, and a path is not a picture. `+split --view=<image>` puts it in a zoomable pane beside the work. This is the right move for a screenshot you were asked about, a generated chart or diagram, or an image already in the repo.
- **Don't leave a design doc or mock HTML app preview-less** — when you author Markdown or scaffold an HTML prototype, auto-open it in a right-hand 2/3 viewer (see *Auto-preview conventions*). Markdown and static `.html` files both render live and live-reload on save, so `--view` the file directly. Only a framework app that needs a dev server gets the serve-then-`--view`-the-URL treatment (and a `+reload` after edits).
- **Don't dump `git diff` into the terminal to show changes** — use `+split --view=git-diff:…` for a navigable diff with a file tree. Reach for the raw command only when you need the text yourself.
- **Don't read `git-diff:<sha>` as "compare against `<sha>`"** — a bare revision shows that commit's own changes. A comparison is `git-diff:<sha>..HEAD`.
- **Don't `+read`, `+send-keys`, `+set-state`, or `+set-banner` a viewer pane** — all four exit 1. The pane is for the user to look at; if you need a diff as text, run `git diff` yourself.

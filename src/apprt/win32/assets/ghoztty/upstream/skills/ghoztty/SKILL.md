---
name: ghoztty
description: Drive the Ghoztty terminal from the CLI. Use to open a file, README, HTML page, image, website or git diff (branch vs main, git status, a commit) in a side pane beside you; open or close windows and panes; read or type into a pane; set a pane's status banner; or link a document to a terminal (ghoztty://).
---

# Ghoztty

Ghoztty is a terminal with a `ghoztty` CLI for windows and panes. If `command -v ghoztty` finds nothing, tell the user to install it from https://github.com/dzearing/ghoztty/releases and stop.

**Nothing takes focus unless you pass `--focus`.** New windows and panes open without raising the app or moving the caret, so the user (and you) keep typing where you were. Use `--focus` only when the user asked to be taken there.

## Your own pane

Inside a Ghoztty pane, `$GHOZTTY_PANE_ID` is this pane's id (a UUID) and `$GHOZTTY_WINDOW_NAME` names its window. Don't call `+list` to find yourself. The CLI sends your pane with every command, so:

- `+split` with no target opens beside **your** pane, in **your** window.
- A name (`--target=logs`) means the pane of that name in **your** window first. Then it means a window of that name, then a pane of that name in the one other window that has it. If two other windows have one, the command fails and lists them. A pane id is always exact.

## Open something beside you (side pane)

```bash
ghoztty +split --view=README.md                    # rendered markdown, live-reloads on save
ghoztty +split --view=mock/index.html              # a live page (its CSS/JS load)
ghoztty +split --view=temp/screenshot.png          # zoomable image
ghoztty +split --view=https://example.com          # a website
ghoztty +split --view=git-diff:main...HEAD         # this branch vs main
ghoztty +split --view=git-status:                  # working tree, updates live
ghoztty +split --view=git-diff:a1b2c3d             # one commit's changes
```

Add `--direction=right|down|left|up` (default right) and `--split-percent=66` to give the new pane 2/3. **Read the reply line.** It is printed only after the pane exists, and it names the pane and its window:

```
created pane 4F2C…-… in window 'window-3', showing README.md
```

If it says the pane is **minimized to a strip**, tell the user rather than claiming it is on screen. A non-zero exit means no pane opened. Say what failed; don't report success.

**Names: skip `--name` unless you will target the pane later.** The reply gives you the pane id, and an id never collides:

```bash
id=$(ghoztty +split --view=docs/spec.md | grep -oiE '[0-9a-f-]{36}')
ghoztty +reload --target="$id"     # later
ghoztty +close --target="$id"
```

When a name helps (re-running the same launch reuses the pane instead of opening another), make it specific to the task, like `spec-preview` or `pr-123-diff`. Don't use a generic word like `draft` or `preview`. A pane name belongs to its window, so another window's `draft` never blocks yours. A different `--view` under a name your window already uses fails. `+close` that pane first.

Don't use `cat`/`less`/`open` to show a file, and don't dump `git diff` into the terminal. `--view` is the way.

## Windows and terminal panes

```bash
ghoztty +new-window --target=api --working-directory=~/src/api --command="npm run dev"
ghoztty +split --direction=down --command="tail -f app.log"   # a terminal beside you
ghoztty +close --target=api            # a window, a pane name, or a pane id
```

`--command` runs in the user's login shell (aliases and PATH work). A split inherits your cwd, so don't pass `--working-directory` to it. `+close` **ends** the pane's process; it is not "hide" (`+stash` hides). Closing something already gone succeeds.

## Read and type into a pane

```bash
ghoztty +read --name=<pane> --lines=40
ghoztty +send-keys --target=<pane> "npm test\n"   # the trailing \n submits
ghoztty +send-keys --target=<pane> C-c
```

Use one way of submitting: `\n`, `--enter`, or an `Enter` argument. They stack, so two of them submit twice. `+read`, `+send-keys`, `+set-state` and `+set-banner` fail on a viewer pane.

## Banner

A sticky markdown card above a terminal pane:

```bash
ghoztty +set-banner --target="$GHOZTTY_PANE_ID" "## Fix login\n**PR** [#123](https://github.com/org/repo/pull/123) — CI green"
ghoztty +set-banner --target="$GHOZTTY_PANE_ID" --clear
```

Don't `+set-state` your own pane, because the installed hooks own it.

## More (read the file when you need it)

| Read | For |
|---|---|
| `viewers.md` | Viewer and diff details, revspec rules, the auto-preview 1/3–2/3 layout, `+reload` |
| `layout.md` | Every flag of `+new-window`/`+split`, `+list --json`, `+rename`, `+rearrange`, `+stash`/`+restore`, colors, layout recipes |
| `terminal-io.md` | `+read`, all of `+send-keys` (keys, `--when-idle`, bracketed paste), `+set-state` |
| `banners-and-links.md` | Banner formatting (headings, tables, links), `ghoztty://focus/<target>` links in generated documents |
| `sessions-and-remote.md` | What `+close` ends, `+sessions`, `+new-remote-window` |

These files are in the same directory as this one.

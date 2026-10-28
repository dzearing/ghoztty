# Windows, splits and layout

Read from the `ghoztty` skill for the full flag tables, `+list`, `+rename`, `+rearrange`, `+stash`/`+restore`, colors and layout recipes.

## `ghoztty +new-window`

Create (or reuse) a terminal window. **Auto-launches Ghoztty if no instance is running.**

```
ghoztty +new-window [flags]
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Register window with a name. Window names are global: if that window already exists it is reused (raised only with `--focus`); if a *pane* holds the name, the command fails. |
| `--working-directory=<path>` | Working directory for the terminal. Relative paths are resolved from CWD. `~` is expanded. If omitted, uses the CWD where `ghoztty` is invoked. |
| `--command=<cmd>` | Command to run in the terminal. Auto-wrapped in the user's login shell with profile loaded. |
| `--view=<path-or-url>` | Open a **viewer** pane instead of a terminal: a rendered markdown file, an `.html`/`.htm` file rendered as a **live page**, a syntax-highlighted text/code file, an **image**, or a website (http/https URL). Relative paths resolve against `--working-directory` (else caller cwd). Mutually exclusive with `--command`/`-e`. |
| `--shell=<path>` | Shell to use for `--command`/`--split-command`, invoked with `-lic`. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`. |
| `--env=KEY=VALUE` | Environment variable for the spawned process. Repeatable. |
| `--focus` | Activate Ghoztty and raise the window (or the existing `--target`). Off by default — windows open in the background. |
| `--no-activate` | No-op, kept for compatibility: not taking focus is now the default. |
| `--title=<title>` | Override the window/tab title. |
| `--split=right\|down\|left\|up` | Atomically create a split pane alongside the main pane. |
| `--color=<#hex\|random>` | Background color for the window. Hex (`#rrggbb` or `#rgb`) or `random` for a random dark tint. |
| `--split-color=<#hex\|random>` | Background color for the split pane (only with `--split`). |
| `--split-command=<cmd>` | Command for the split pane (only with `--split`). |
| `--split-percent=<1-99>` | Percentage of space for the new split pane (default 50, only with `--split`). |
| `-e <args...>` | Everything after `-e` becomes the command. No more flags are parsed. |

## `ghoztty +split`

Create a split pane in a running window.

```
ghoztty +split [flags]
```

| Flag | Description |
|------|-------------|
| `--direction=right\|down\|left\|up` | Split direction. Default: `right`. |
| `--target=<name>` | Window or pane to split in — a name from `--target`/`--name`, or any pane id (e.g. `$GHOZTTY_PANE_ID`, no registration needed). Default: **your own pane** (`$GHOZTTY_PANE_ID`), falling back to the most recently focused window when there is none. |
| `--pane=<name-or-id>` | Split adjacent to **this exact pane** — where `--target` anchors at whichever pane its window has focused. Your own pane is now the default, so reach for this to name a *different* pane, or to state the anchor out loud (`--pane="$GHOZTTY_PANE_ID"`). Unlike the implicit default, a `--pane` that names nothing is an error, not a fallback. |
| `--name=<name>` | Register the new pane with a name, **in the window it lands in** — another window may hold a pane of the same name. If this window already has one showing the same thing, it is reused (focused only with `--focus`); if it shows something else, the command fails. Omit it unless you will target the pane later; the reply line gives the pane id either way. |
| `--focus` | Move keyboard focus to the new pane, raise its window, and activate Ghoztty. Off by default — the pane that had focus keeps it. |
| `--command=<cmd>` | Command to run in the new pane. Auto-wrapped in the user's login shell with profile loaded. |
| `--view=<path-or-url>` | Open the new pane as a **viewer** (rendered markdown / live HTML page / highlighted code / image / website) instead of a terminal. Relative paths resolve against `--working-directory` (else caller cwd). Mutually exclusive with `--command`/`-e`. This is the way to "open a file/README/doc/screenshot in a side pane". |
| `--shell=<path>` | Shell to use for `--command`, invoked with `-lic`. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`. |
| `--env=KEY=VALUE` | Environment variable for the spawned process. Repeatable. |
| `--color=<#hex\|random>` | Background color for the new pane. |
| `--working-directory=<path>` | Working directory for the new pane. |
| `-e <args...>` | Everything after `-e` becomes the command. |

## `ghoztty +stash` / `ghoztty +restore`

Put a pane out of the way **without ending it**: `+stash` takes it out of its window's split layout and into the window's pane sidebar, where it keeps running. `+restore` puts it back in the slot it left. Use it for helper panes you started (a log tail, a dev server) that the user doesn't need to watch.

```
ghoztty +stash --target=<pane>
ghoztty +restore --target=<pane> [--focus]
```

| Flag | Description |
|------|-------------|
| `--target=<pane>` | Registered pane name or pane id. Required. A window target is an error. |
| `--focus` | (`+restore` only) Also focus the restored pane and raise its window. Without it focus stays where it is. |

- A stashed pane stays **fully targetable**: `+send-keys`, `+read`, `+set-banner`, `+set-state`, `+close`, `+reload` all keep working on it, and `+list` marks it `[stashed]` (JSON: `"stashed": true`).
- Both are idempotent. Stashing the **last pane on screen** in its window fails (exit 1) — a window always shows at least one pane.
- `+split` anchored at a stashed pane, and `ghoztty://focus/<stashed pane>`, restore it first.
- **Don't stash your own pane** — the user is looking at it.

```bash
ghoztty +split --name=logs --direction=down --command="tail -f app.log"
ghoztty +stash --target=logs          # still tailing, out of the way
ghoztty +read --name=logs --lines=20  # still readable
ghoztty +restore --target=logs        # back in its slot
```

## `ghoztty +list`

List all open windows, tabs, and panes. Human-readable tree view by default, `--json` for machine-readable output. Requires a running Ghoztty instance.

```
ghoztty +list [flags]
```

| Flag | Description |
|------|-------------|
| `--json` | Output machine-readable JSON instead of the default tree view. |

**Human-readable output:**

```
Window: "Editor" [target: editor] (focused)
  Tab 1: "Editor" (selected)
    ├─ ~/projects  /Users/david/projects  pid:12345  /dev/ttys003  [name: main-editor]
    ├─ ~/logs  /Users/david/logs  pid:12346  /dev/ttys004  [name: logs]
    └─ ~/src  /Users/david/src  pid:12347  /dev/ttys005  [name: terminal] *
Window: "~/docs"
  Tab 1: "~/docs" (selected)
    ~/docs  /Users/david/docs  pid:12348  /dev/ttys006 *
```

- Single-pane tabs show the terminal inline (no tree characters)
- Multi-pane tabs use `├─`/`└─` tree connectors
- `*` marks the focused terminal in each tab
- `[target: X]` and `[name: X]` shown when set
- Empty state prints `No windows open.`

**JSON output structure (`--json`):**

```json
{
  "success": true,
  "data": {
    "windows": [
      {
        "id": "tab-group-8f436dd60",
        "title": "Editor",
        "target": "editor",
        "focused": true,
        "title_set_by_user": false,
        "tabs": [
          {
            "id": "tab-8f5985200",
            "title": "Editor",
            "index": 1,
            "selected": true,
            "splits": {
              "type": "leaf",
              "terminal": {
                "id": "485DECDE-...",
                "title": "~/projects",
                "working_directory": "/Users/david/projects",
                "pid": 12345,
                "tty": "/dev/ttys003",
                "name": "main-editor",
                "focused": true,
                "exit_code": null
              }
            }
          }
        ]
      }
    ]
  }
}
```

**Key JSON fields:**
- **`target`** (on windows): User-provided name from `+new-window --target=X`, or auto-generated (`window-1`, `window-2`, etc.)
- **`name`** (on terminals): User-provided from `+split --name=X`, else the pane id
- **`splits`**: Recursive tree — `"type":"leaf"` contains a `terminal` object, `"type":"split"` contains `direction` (`horizontal`/`vertical`), `ratio`, `left`, `right`
- **`title_set_by_user`** (on windows): `true` when the user typed the window's title (the sidebar, Change Window Title). `+rename` will not change it.
- **`focused`**: On windows = frontmost window. On terminals = focused pane in its tab.
- **`exit_code`**: `null` if the process is still running, or the exit code (e.g. `0`, `1`) if it has exited. Human-readable output shows `running` or `exited(N)`.

Every `target`, `name` and `id` in the output is immediately usable as a `--target`. A pane `name` is looked up in *your* window first; when two other windows hold panes of that name, use the `id`.

**Don't use `+list` to find yourself.** If you are running inside a pane, `$GHOZTTY_PANE_ID` already names it (see SKILL.md). Reach for `+list` when you need to inspect *other* windows/panes.

## `ghoztty +rename`

Change the display title of a named window. The target registry name is **not** affected.

```
ghoztty +rename --target=<name> --title=<new-title>
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | The named window or pane whose title to change. Required. |
| `--title=<new-title>` | The new display title for the window/tab title bar. Required. |

Returns an error if the target doesn't exist in the registry.

**A title the user typed always wins.** If the user renamed the window (in the sidebar or with Change Window Title), `+rename` leaves it as it is and fails with an error naming the user's title — it neither replaces nor clears it. Treat that as expected, not something to retry: check `title_set_by_user` in `+list --json` first if you want to skip the call, and run `+rename` with `|| true` when tagging a title (`(prep)`, `(ready)`). Once the user clears their title, `+rename` works again.

## `ghoztty +rearrange`

Rebuild the split tree of a window to match a declarative JSON layout. **Preserves terminal state** — running processes, scrollback, and focus are kept intact. Panes are reparented in the tree, not destroyed and recreated.

```
ghoztty +rearrange [flags]
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Window to rearrange. Default: **your own window** (the one holding `$GHOZTTY_PANE_ID`), falling back to the most recently focused window when there is none. |
| `--layout=<json>` | JSON layout descriptor (required). See format below. |

**Layout JSON format:**

The layout is a tree with two node types:

- **Leaf**: `{"pane": "<name>"}` — references an existing named pane
- **Split**: `{"direction": "horizontal|vertical", "ratio": <0-100>, "left": <node>, "right": <node>}`

| Field | Description |
|-------|-------------|
| `direction` | `"horizontal"` (left\|right) or `"vertical"` (top\|bottom) |
| `ratio` | Percentage given to the left/top child. Default: 50. Clamped to 10–90. |
| `left`, `right` | Child nodes (each is a leaf or another split) |

**Behavior:**
- Every leaf must name a pane **of that window** (a `--name`, or a pane id).
- A layout may name **viewer panes** (`--view=`) alongside terminals; a viewer keeps its rendered page and scroll position.
- Panes **not** mentioned in the layout are removed from the tree.
- Focus is preserved if the focused pane is in the new layout; otherwise moves to the first leaf.
- Supports undo (Cmd+Z restores the previous layout).

**Example — editor at 40%, three workers stacked vertically:**

```bash
ghoztty +rearrange --target=ide --layout='{
  "direction": "horizontal",
  "ratio": 40,
  "left": {"pane": "editor"},
  "right": {
    "direction": "vertical",
    "ratio": 33,
    "left": {"pane": "worker1"},
    "right": {
      "direction": "vertical",
      "ratio": 50,
      "left": {"pane": "worker2"},
      "right": {"pane": "worker3"}
    }
  }
}'
```

**Example — swap two panes:**

```bash
# Before: editor left, terminal right
# After: terminal left, editor right
ghoztty +rearrange --target=ide --layout='{
  "direction": "horizontal",
  "ratio": 50,
  "left": {"pane": "terminal"},
  "right": {"pane": "editor"}
}'
```

**Example — query then rearrange:**

```bash
# Get current state, then rebuild layout
state=$(ghoztty +list --json)
# Parse pane names from $state, construct new layout, then:
ghoztty +rearrange --target=mywin --layout='...'
```

## Background Colors

- `--color=#1a1a2e` sets a specific hex background color on a window or pane.
- `--color=random` on a WINDOW gives it its own gradient background (one random hue, lit from the top center and darkening toward the bottom-right) in the default elevated pane style; in the `flat` style, and on a split, it generates a random dark-tinted terminal background (charcoal with subtle hue).
- When splitting a pane (ctrl-d or `+split`), the child pane automatically inherits a slightly lighter version of the parent's background for visual depth.
- Right-click a pane → "Background Color..." opens a live color picker.

## Key Behaviors

1. **Idempotency**: Re-running a command with the same `--target` or `--name` reuses the existing window/pane (in the same window, for a pane name) instead of creating a duplicate, and leaves focus alone unless you pass `--focus`. This makes commands safe to retry.
2. **Auto-launch**: `+new-window` launches Ghoztty.app if no instance is running. `+split` and `+close` require a running instance.
3. **Atomic splits**: Use `+new-window --split=<dir>` to create a window with a split in one command, avoiding timing issues from sequential `+new-window` then `+split`.
4. **Shell initialization**: `--command` auto-wraps in the user's login shell with profile loaded, so aliases, PATH, nvm, etc. work out of the box. Use `--shell` to override which shell is used.

## Patterns

### Open a named window with a command

```bash
ghoztty +new-window --target=myapp --working-directory=/path/to/project --command="nvim ."
```

### Two-pane layout (editor + shell)

```bash
ghoztty +new-window \
  --target=dev \
  --working-directory=/path/to/project \
  --command="nvim ." \
  --split=down \
  --split-command="exec zsh -l"
```

### Three-pane layout (built sequentially)

```bash
ghoztty +new-window --target=ide --command="nvim ."
ghoztty +split --target=ide --name=term --direction=down --command=zsh
ghoztty +split --target=ide --name=logs --direction=right --command="tail -f app.log"
```

### Launch Claude Code in a named window

```bash
wt_path="$(cd /path/to/project && pwd)"
ghoztty +new-window \
  --target=task-name \
  --working-directory="${wt_path}" \
  --title="project: task-name" \
  --command="cl \"your prompt here\""
```

### Rename a window's title

```bash
ghoztty +rename --target=dev --title="Project: my-feature"
```

### Discover what's running, then target it

```bash
# Get JSON state
state=$(ghoztty +list --json)
# Parse with jq to find a specific pane, then close it
target=$(echo "$state" | jq -r '.data.windows[0].target')
ghoztty +close --target="$target"
```

### Rearrange: prioritize one pane, tile the rest

```bash
# Create 4 panes
ghoztty +new-window --target=work --command=zsh
ghoztty +split --target=work --name=main --direction=right --command=zsh
ghoztty +split --target=work --name=aux1 --direction=down --pane=main --command=zsh
ghoztty +split --target=work --name=aux2 --direction=right --pane=aux1 --command=zsh

# Rearrange: main gets 70% left, aux panes tile 2x1 on right
ghoztty +rearrange --target=work --layout='{
  "direction": "horizontal",
  "ratio": 70,
  "left": {"pane": "main"},
  "right": {
    "direction": "vertical",
    "ratio": 50,
    "left": {"pane": "aux1"},
    "right": {"pane": "aux2"}
  }
}'
```

### Pass environment variables

```bash
ghoztty +new-window \
  --target=api \
  --env=API_KEY=sk-123 \
  --env=DEBUG=true \
  --command="node server.js"
```

### Clean teardown (reverse order)

```bash
ghoztty +close --target=logs
ghoztty +close --target=term
ghoztty +close --target=ide
```

Closing a nonexistent target is a no-op, so teardown scripts are safe even if some panes were already closed.

## Mistakes

- **Don't use `+split` before `+new-window`** — there must be a running instance and a target window.
- **Don't manually wrap with `zsh -lic`** — `--command` auto-wraps in the user's login shell. Use `--shell` only if you need a different shell.
- **Don't use sequential `+new-window` then `+split`** for the initial layout — use `--split` and `--split-command` on `+new-window` for atomicity.
- **Don't assume `--working-directory` propagates to `--split-command`** — the split pane must `cd` explicitly if it needs the same directory.

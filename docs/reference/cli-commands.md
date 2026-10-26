# IPC commands (`ghoztty +…`)

Developer reference for the window-management commands: behavior, contracts
and where they live. Focus, name lookup, pane ids, caller anchoring and
socket selection are shared by every command — see
[cli-targeting.md](cli-targeting.md). User-facing flag tables and recipes are
in the bundled skill (`macos/Resources/Ghoztty/skills/ghoztty/`); keep both in
step when a flag changes. Commands documented elsewhere:
`+set-banner` → [banners.md](banners.md), `+new-remote-window` →
[remote-machines.md](remote-machines.md), `+sessions` internals →
[session-persistence.md](session-persistence.md).

## `ghoztty +new-window`

Create or focus a terminal window. Auto-launches Ghoztty if no instance is running.

```
ghoztty +new-window --target=<name> --working-directory=<path> --command=<cmd> --view=<path-or-url-or-diff> --shell=<path> --title=<title> --split=right|down|left|up --split-command=<cmd> --focus -e <args...>
```

- `--focus`: activate Ghoztty and raise the window (or the existing `--target`).
- `--shell`: shell for `--command`/`--split-command`, invoked with `-lic` so
  the profile is loaded. Falls back to config `command-shell`, then `$SHELL`,
  then `/bin/zsh`.
- `--view`: the window's single pane is a **viewer** ([viewer-panes.md](viewer-panes.md))
  — a file (markdown, HTML as a live page, code, an image), a website, or a
  git diff (`git-status:` / `git-diff:<revspec>`). Mutually exclusive with
  `--command`/`-e`.
- `--title`: set the **window title**. A window title pins the titlebar — it
  wins over any tab or pane title and survives pane focus changes and shell OSC
  title updates — until cleared. The titlebar falls back to window title →
  active tab's title → active pane's title. Interactive equivalents:
  Cmd+Shift+R ("Change Window Title", also sets/clears it), plus separate
  "Change Tab Title" and "Change Pane Title" commands in the menu and command
  palette. `ghoztty +rename --target=<name> --title=<title>` changes it later
  (`--title=""` clears the pin).

## `ghoztty +split`

Create a split pane in a running window.

```
ghoztty +split --direction=right|down|left|up --target=<name> --name=<name> --command=<cmd> --view=<path-or-url-or-diff> --shell=<path> --working-directory=<path> --focus -e <args...>
```

- `--focus`: move keyboard focus to the new (or existing `--name`) pane, raise
  its window, activate Ghoztty. Otherwise the caller's pane keeps focus.
- `--direction`: default `right`.
- `--target`: named window to split in. Default: **the caller's pane**
  (Caller anchoring), falling back to the most recently focused window.
- `--view`: a viewer pane instead of a terminal (as `+new-window --view`).
  Mutually exclusive with `--command`/`-e`. Works with `--pane` targeting,
  including splitting off an existing viewer pane. `+split --view=` seeds the
  caller's cwd as `--working-directory` (terminal splits don't, so cwd
  inheritance still works).
- `--name`: register the new pane for later targeting. A pane name belongs to
  the window it is in, so only a pane of that name in the window the split
  lands in, or a window of that name, collides. Re-running the same split
  reuses the pane; anything else fails rather than doing nothing:
  - **Matches** (a terminal again, or a viewer showing that `--view` or opened
    with it): no split, exit 0, stdout `pane '<n>' already exists in this
    window ('<w>'); reused it, no split created`.
  - **Doesn't match** (another `--view`, a terminal where a viewer stands or
    the reverse, or the name is a window's): exit 1, stderr names the pane and
    what it shows. Nothing is retargeted. Use another `--name`, or `+close` it
    first.

  Policy: `SplitNameCollision`; tests: `SplitNameCollisionTests`,
  `PaneNameScopeWindowTests`.

**The reply is sent after the split, and says what happened.** `handleSplit`
waits, bounded (10s), for the pane to exist and be laid out, then replies
(the line is the response's additive `message` field; an older CLI ignores
it). Previously the reply went first and a failed split only logged
unpersisted, so `+split` could not fail.

- **Created**: exit 0, stdout `created pane '<n>' (<id>) in window '<w>',
  showing <view>` — or `created pane <id> in window '<w>'` without `--name`.
- **Created, minimized**: the same line ending `; it is minimized to a strip,
  since its row has no room for it on show`. Exit 0. (Rare given the side-pane
  rule in [stacked-panes.md](stacked-panes.md).)
- **Failed**: exit 1, reason on stderr — a `--target`/`--pane` naming nothing,
  an ambiguous name, or a split that did not finish within the wait (it may
  still appear; the message says so).

An **agent-backed terminal split** (session persistence, a remote machine)
asks the agent for the parent's cwd off the main thread and is created a beat
later; `newSplit`'s `onFinish` reports that path's outcome too, so it is waited
on like a local one. On-show is read from the layout
(`PaneStackState.stackMinimizing`) once laid out; a window that never lays it
out (not on screen) gets no on-show claim either way.

**Every `+split` is logged at `.notice`** (persisted): caller pane, resolved
window, anchor pane, name and view, outcome (created / reused / name collision
/ failed / timed out) and whether the new pane is on show. Ambiguous name
lookups are logged the same way. Read them with `/usr/bin/log show --last 1h
--predicate 'subsystem BEGINSWITH "com.dzearing.ghoztty" AND category ==
"IPCServer"'`.

## `ghoztty +close`

```
ghoztty +close --target=<name>
```

Close a named pane or window. Closing a nonexistent target succeeds silently.
For a session-persistence pane this ENDS the agent session (the process is
killed once the close's undo window expires) — same as closing the pane in the
GUI; only an app quit keeps sessions alive. For a pane on a REMOTE machine
`+close` likewise ends the session: the interactive Disconnect answer
([remote-machines.md](remote-machines.md)) is not offered, because a modal on
the IPC path would wedge every later `ghoztty +…` command. `+close` never
prompts for viewer panes.

## `ghoztty +read`

```
ghoztty +read --name=<pane> --lines=<N>
```

Print the last N lines (default 50) of a named pane's output. `--name` is
required. Reads the screen as laid out (no copy reflow; see
[copy-reflow.md](copy-reflow.md)).

## `ghoztty +list`

```
ghoztty +list [--json] [--tty=<tty>]
```

List windows, tabs, and panes (human tree, or `--json`). Listing
auto-registers every pane it discovers, so returned names are immediately
usable as targets.

- `--tty`: print only the registered name of the pane whose terminal matches
  the tty (`ttys014` or `/dev/ttys014`; raw padded `ps -o tty=` output is
  accepted), then exit; exit 1 if no match:
  `ghoztty +list --tty="$(ps -o tty= -p $PPID)"`.
- JSON per pane: leaf `id` (pane id), `state` (terminal; machine token),
  `banner` (absent when none), `"stashed": true` (absent otherwise),
  `"type": "viewer"` + `"url"` for viewers (where the pane currently IS, not
  where it was opened). The human tree marks viewers `view:`, non-idle panes
  `[busy]` / `[question]`, and stashed panes `[stashed]`.

## `ghoztty +sessions`

```
ghoztty +sessions [--json]
```

List the persistent sessions owned by the local `ghoztty-agent`. Unlike the
other commands it dials the agent **directly** over its 0600 unix socket
(`~/.config/ghoztty/local-agent[-debug]/agent.sock`), not the app's IPC socket,
so it works with the app closed (as long as the agent runs). Requires
`session-persistence = true` (the default).

Each row: session id, liveness (`alive`, or `dead(<code>)` for a tombstone),
`attached` when a viewer is attached, activity (`idle`/`busy`/`needs_input`),
child pid, `pinned` when exempt from the agent's idle-TTL reaper (persistent
local panes are pinned; cross-machine sessions are not), working directory
(when known), and command. `--json` emits one object per session.

## `ghoztty +send-keys`

```
ghoztty +send-keys --target=<name> [flags] <text|key>...
```

> **To submit, end the text with `\n`** — `ghoztty +send-keys --target=t "prompt\n"`.
> (`--enter`, or a separate `Enter` argument, do the same thing. Use one, not
> two — they stack, and two of them submit twice.)

- `--target` (required): named pane or window.
- `--enter`: press Enter after the text; with no text, just presses Enter.
- `--when-idle`: poll the pane's recent output every 500ms until it no longer
  contains `esc to interrupt` (Claude Code's busy marker), then send; sends
  anyway after `--idle-timeout=<seconds>` (default 30) or if the pane can't be
  read.
- Positionals are text or key names, written in order. Keys: `C-c`, `C-d`,
  `C-z`, …; `Enter`, `Tab`, `Escape`, `Space`, `Backspace`. Escapes in text:
  `\n`, `\t`, `\r`, `\\`, `\e`.

```bash
ghoztty +send-keys --target=term "hello\tworld\n"   # types, then submits
ghoztty +send-keys --target=term "ls -la" Enter
ghoztty +send-keys --target=term --enter "ls -la"
ghoztty +send-keys --target=term C-c
ghoztty +send-keys --target=term -- "--not-a-flag" Enter
```

**A trailing newline is a keypress; an interior one is content.** The trailing
run of `\n`/`\r` is peeled off and delivered as that many Enter presses, so
`"a\nb\n"` pastes two lines then submits. This runs after escape processing,
so the two-character `\n` and a real newline byte behave identically. Accepted
cost: you cannot paste text ending in a literal newline without submitting
(a trailing newline in a paste means "commit" essentially always, and a
program without bracketed paste sees `\r` mapped back to `\n` by the tty's
`ICRNL` anyway).

**Any unknown `--flag` is a hard error** (exit 1), naming the three submit
spellings (`--press-enter` used to be typed into the pane at exit 0).
Single-dash arguments (`-la`, `-p`) are ordinary text. A bare `--` stops flag
parsing but not key notation.

**Text and keys stay distinguishable.** Argument boundaries survive to the
write. When a call mixes text with keys, adjacent same-kind arguments merge
into runs; each **text** run is written as a **bracketed paste**
(`ESC[200~` … `ESC[201~`) and each **key** run bare, outside the frame. That is
what makes `"some message" Enter` submit in a TUI: flattened into one burst
ending in `\r`, paste detection reads the `\r` as a pasted newline. Framing is a
property of the bytes, not timing — no delays anywhere.

- A text run is framed **in a single PTY write**. Split across writes, a lone
  `ESC[200~` in its own `read()` is not reliably associated with the content
  after it (measured against Claude Code).
- Framing happens only when the pane's program has **enabled bracketed paste**
  (DEC mode 2004). Otherwise (`cat`, a script's `read`) bytes go verbatim.
  Text containing `ESC[201~` is sent unframed rather than closing the frame
  early.
- Single-kind calls (`"text"`, `Enter`, `C-c` alone) are sent byte-for-byte.

## `ghoztty +set-state`

```
ghoztty +set-state --target=<name> --state=<idle|busy|needs_input>
```

Set the activity state of a named window or pane (both required). State is
aggregated across a window's panes (priority `needs_input` > `busy` > `idle`)
and shown as a title suffix and a custom `AXWindowActivityState` accessibility
attribute. Processes can also set it via OSC: `\033]7777;<state>\007`.

`idle`/`busy`/`needs_input` are the **machine tokens** — the vocabulary of the
flag, the OSC 7777 payload and `AXWindowActivityState`. They are a public API
(hooks call the CLI; external tools like ztabby read the attribute) and do not
change. The **title suffix** and every other UI show a human label, which
differs for one state: `needs_input` renders as `(question)`. Consumers must
read the attribute, not parse the title.

**An agent should not set the state of its own pane.** The installed hooks own
it (`macos/Resources/Ghoztty/hooks/ghoztty-activity-state.sh`, the single owner
of the ordering), including holding the pane `busy` while background subagents
outlive the main loop — `Stop` fires when the main loop goes quiet, not when
the work ends. Live subagents are one marker file each under
`/tmp/ghoztty-<runtime>-agents-<session_id>/`, recovered by the owner pid baked
into the filename or by a missed heartbeat past `GHOZTTY_AGENT_STALE_MIN`
minutes (default 30, which must exceed the longest single *tool call*).
`+set-state` is for *other* panes. Tests: `scripts/test-activity-state.sh`.

**`needs_input` means a question is actually on screen.** Set by
`AskUserQuestion`/`ExitPlanMode` (PreToolUse), `PermissionRequest`, and only
the `permission_prompt`/`elicitation_dialog` **Notification** types — never
`idle_prompt`, which Claude fires ~60s after *every* turn ends. The generated
hook narrows Notification with a matcher
(`ClaudeHookSpec.blockingNotificationMatcher`), and the script's `pause` also
filters by `notification_type`, failing closed on an unknown or missing type
(so a hook installed before the matcher is fixed by the script alone). A pause
is undone by the next main-thread tool call **or a submitted prompt** (a
dismissed permission prompt or a question answered in prose runs no tool), and
`session-start` drops a marker its pane's previous session left.

Wired for Claude Code; Copilot CLI gets only the session-start sweep and the
settle, because its tool/subagent/permission hook vocabulary is undocumented
(see `CopilotHookSpec`).

## `ghoztty +reload`

```
ghoztty +reload --target=<name>
```

Reload a **viewer pane** in place. `--target` (required) is a window, pane, or
pane id; a window target reloads its focused pane. Website viewers re-fetch
from origin (bypassing caches); file viewers re-render preserving scroll (they
live-reload anyway, but an **HTML** pane's watcher doesn't cover sibling
CSS/JS, which this bypasses the cache for); image viewers re-decode, keeping
zoom/scroll unless the pixel dimensions changed; diff viewers re-run their git
command, keeping the open file and scroll. A terminal target fails with `... is
a terminal pane, nothing to reload` (exit 1). Interactive equivalent: Cmd+R in
a focused viewer.

## `ghoztty +stash` / `ghoztty +restore`

```
ghoztty +stash --target=<pane>
ghoztty +restore --target=<pane> [--focus]
```

Move a pane out of the split layout into the window's pane sidebar without
ending it, and back ([pane-sidebar.md](pane-sidebar.md)).

- `--target`: a pane name or id (a window target is an error).
- `--focus` (`+restore`): also focus the restored pane and raise its window.
- Idempotent both ways. Stashing the **last pane on screen** in a window fails
  (exit 1): a window always shows at least one pane. Quick Terminal panes have
  no sidebar and are refused.
- A stashed pane stays fully targetable (`+send-keys`, `+read`, `+set-banner`,
  `+set-state`, `+close`, `+reload`).
- `+split` anchored at a stashed pane, and `ghoztty://focus/<stashed pane>` /
  the `--focus` idempotent hits, **restore it first** (a pane beside an
  invisible one would be invisible). `+rearrange` keeps a stashed pane its
  layout omits stashed.

## Viewer panes and terminal-only commands

`+read`/`+send-keys`/`+set-state`/`+set-banner` against a viewer fail with
`... is a viewer pane, not a terminal` (exit 1). `+close` works normally.

## Example: three-pane layout

```bash
ghoztty +new-window --target=ide --command="nvim ."
ghoztty +split --target=ide --name=term --direction=down --command=zsh
ghoztty +split --target=ide --name=logs --direction=right --command="tail -f app.log"
ghoztty +read --name=logs --lines=5
ghoztty +close --target=logs
ghoztty +close --target=term
ghoztty +close --target=ide
```

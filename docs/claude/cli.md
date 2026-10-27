# Ghoztty CLI reference

> Progressive-disclosure doc routed from `/CLAUDE.md`. Load this when driving
> ghoztty from a script or agent, using or changing ANY CLI verb or its IPC
> semantics, targeting windows/panes, or handling `ghoztty://` links and links
> in terminal output. Remote-machine dialing (`+new-remote-window`, the
> connection pill, relay sign-in) lives in `docs/claude/remote.md`; viewer-pane
> behavior in `docs/claude/viewers.md`.

## CLI Window Management

IPC commands communicate with a running Ghoztty instance over a local IPC
endpoint (a Unix domain socket on macOS, a named pipe on Windows — see
Architecture in `/CLAUDE.md`). All commands are idempotent — named targets that already exist
are focused instead of recreated, as long as they match the request; a `+split
--name` that names a different pane fails instead of silently reusing it (see
`+split`). On macOS pane names belong to the window they were created in, and a
name is looked up in the caller's window first (see Naming; Windows: T2250). Since T135, that focus is no longer silent
about what it dropped: `+new-window` against an existing target replies
`outcome: "focused"` (vs `"created"`) and, when create-only flags
(`--command`, an explicit `--working-directory`, `--view`, …) were passed, a
`note` naming them — which the CLI prints to stderr while keeping exit 0. The
CLI's auto-inserted cwd is marked `--cwd-implicit` on the wire so a bare
re-focus stays quiet. (win32 server done; Mac server half is T523 — the
shared CLI already prints any note it receives.) The verbs, flags, and semantics below are the
same on both platforms.

**No command takes focus unless it is asked to** (main 3081022ec on macOS,
T1797 on Windows). `+new-window` (terminal, `--view`, `--split`,
`--from-focused`), `+split` (every anchor, terminal and viewer),
`+new-remote-window`, and the idempotent `--target`/`--name` hits all open in
the BACKGROUND: the app is not activated, the window is not raised, and the
pane that had keyboard focus — normally the caller's own — keeps it, so an
agent opening a side pane never interrupts the user. `--focus` (or
`--focus=true`; `--focus=false` is the default spelled out) restores the old
raise-and-focus. `--no-activate`, the old opt-out, is accepted as a no-op and
never overrides `--focus`. A background window is placed directly behind
Ghoztty's frontmost window, never over the app the user is in and never at
the bottom of the z-order where nobody would find it. Surfaces the user opens
(keybinds, menu, palette, File Open, the dock or a shortcut — Windows'
single-instance launch handoff sends `--focus` for exactly this reason) and
the `ghoztty://focus` scheme are unchanged. One Windows-only limit: a
background window does not open MAXIMIZED even where the placement memory
says so, because Windows has no show command that maximizes without
activating; it opens at its restored size. Acceptance:
`test/win32/cli-focus-policy.ps1`; the Mac half is `IPCFocusPolicyTests`.

**A flag this list does not contain is an error, not a no-op** (T489, T852).
Every verb — the ones that parse their own flags and the ones that forward
their whole command line to the running instance — rejects an unknown `--flag`
by name, suggests the nearest real spelling when the typo is close, and exits
non-zero without doing its work:

```
$ ghoztty +split --dirction=right
+split: unknown flag --dirction (did you mean --direction?)
run 'ghoztty +split --help' for usage
```

**So is a real flag in the wrong shape** (T950). A flag that carries a value
is always written `--flag=value`; a space instead of the `=` is refused and the
message shows the form to write. A switch (`--no-activate`, `--from-focused`,
`--clear`, `--config`) takes no value and refuses one — except `--focus`,
which also takes exactly `=true` or `=false`:

```
$ ghoztty +close --target dev
+close: --target needs a value; write it as --target=dev
```

The SERVER stays tolerant of flags it does not know — that is the
compatibility contract that lets a week-old running instance accept a
CLI that learned a flag this morning — so the check lives in the CLI, which
knows exactly what each verb accepts (`src/cli/verb_flags.zig` for the
forwarding verbs). Two things are deliberately never checked: everything after
`-e`, which is the command, and single-dash arguments, which are content. To
pass literal text starting with `--` (banner text, `+send-keys` payloads), put
it after a bare `--`, which stops flag parsing.

### `ghoztty +new-window`

Create a terminal window, or find an existing `--target`. Auto-launches Ghoztty if no instance is running.
The launched app opens only the requested window, not a blank startup window beside it: on Windows
the launch passes `--initial-window=false`, which defers the blank window for a few seconds and opens it
only if nothing else did (T2162). (Mac currently refuses instead of launching: T2189.)

```
ghoztty +new-window --target=<name> --name=<pane-name> --working-directory=<path> --command=<cmd> --view=<path-or-url-or-diff> --shell=<path> --title=<title> --split=right|down|left|up --split-command=<cmd> --focus -e <args...>
```

- `--focus`: Activate Ghoztty and raise the window (or the existing `--target`). Without it the window opens in the background — see the focus rule above.

- `--shell`: Shell to use for `--command`/`--split-command`, invoked with `-lic` so profile is loaded. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`.
  **With no `--command`, `--shell` names the pane's interactive shell** (T1665): `+new-window --shell=pwsh` and `+split --shell=pwsh` open a pwsh pane, with `session-persistence` on or off. On Windows the off path used to read `--shell` only to wrap a command, and `+split --shell=` alone took the "nothing explicit, inherit" shortcut on the agent path, so both quietly opened the default shell. Acceptance: arm K of `test/win32/ipc-command-keepalive.ps1`. The macOS half is T1750.
  On Windows the fallback is `command-shell` then `cmd.exe`, and the invocation is per-flavor (the shell stays alive after the command): `pwsh`/`powershell` → `-NoExit -Command`, `cmd` → `/K`, `wsl` → `-e /bin/sh -lic "<cmd>; exec \"$SHELL\" -li"` in the default distro, `nu` → `-e`, anything else (e.g. git-bash) → `-lic "<cmd>; exec shell -li"`.
  **The keep-alive is argv-shaped here, and that is why the agent-backed path needs its own wiring** (T468). With `session-persistence` on — the default — every local pane's shell is spawned by `ghoztty-agent`, which synthesizes its own `<shell> /c <cmd>` and exits the moment the command returns. POSIX hides this because its keep-alive lives INSIDE the command string (`<cmd>; exec <shell> -li`), which rides `OPEN.command` untouched; `cmd /K` and `-NoExit -Command` cannot. So a local-agent pane sends the wrapped invocation as `OPEN.argv` (the agent's exec-verbatim seam) while `OPEN.command` still carries the raw command as the session's label. Only for the LOCAL agent — a cross-machine agent is a different machine and applies its own convention. `-e` is never wrapped, on either path: it means "exec exactly this". Acceptance: `test/win32/ipc-command-keepalive.ps1`.
  **`wsl` is the row that takes an ARGV rather than a command string, which is why it looks different** (T656). `wsl -- <cmd>` hands the rest of the *Windows* command line to the distro's default shell **as written**, so the quoting Windows applies to a spaced argument survived into the distro and bash looked for a program literally named `"echo hi"` — `command not found` naming the whole line, on both paths, with the pane dying with it. `-e` execs an argv instead, so the command reaches the inner shell as one properly-unquoted argument. `/bin/sh` because it is the one interpreter every distro is guaranteed to have (dash on Ubuntu, and dash accepts `-lic`); `exec "$SHELL" -li` because the pane must be left in the user's REAL login shell, exactly as the posix row leaves it — `$SHELL` comes from the distro's passwd entry, with `/bin/sh` as the fallback. Acceptance: arm I of `test/win32/ipc-command-keepalive.ps1`.
  **Quoting inside `--command` is the pane shell's, on both platforms** (T1601). The value is the command line that shell runs, quoted the way you would quote it at its prompt — so a path with a space in it is quoted: `--command=powershell -nop -File "C:\a b\x.ps1"`. On macOS this falls out of handing the string to `sh -lic` as one argument, and on Windows four of the five flavors get it for free because they parse their command line by the same CRT rules the spawn writes it with. `cmd.exe` — the Windows default — does not: CRT quoting renders an inner `"` as `\"` and cmd has no backslash escape, so until T1601 a `--command=` needing a quoted path had **no working form at all** and the pane ran nothing. The cmd row now re-splits the value into the argv elements that render back into the line cmd needs (`apprt.ipc.args.cmdShellArgs`): split on unquoted whitespace, syntactic quotes dropped so the spawn puts real ones back, and a cmd operator the caller quoted (`"a&b"`) caret-escaped so it stays data. Unquoted `&&`, `|` and `>` go on being operators. The one shape that cannot survive is an EMPTY quoted argument (`""`), which the spawn renders as nothing — use `-e` when you need argv elements to be exact. Acceptance: arm J of `test/win32/ipc-command-keepalive.ps1`.
- `--view`: Open a window whose single pane is a **viewer** (see `docs/claude/viewers.md`) instead of a terminal — a file, a local **HTML page**, a website, or a **git diff** (`git-status:` / `git-diff:<revspec>`, see Git diff panes in that doc). Mutually exclusive with `--command`/`-e`.
- `--title`: Set the **window title**. A window title pins the titlebar — it wins over any tab or pane title and survives pane focus changes and shell OSC title updates — until cleared. The titlebar falls back to window title → active tab's title → active pane's title. Interactive equivalents: Cmd+Shift+R ("Change Window Title", also sets/clears it), plus separate "Change Tab Title" and "Change Pane Title" commands in the menu and command palette. `ghoztty +rename --target=<name> --title=<title>` changes it later (`--title=""` clears the pin).

### `ghoztty +split`

Create a split pane in a running window.

```
ghoztty +split --direction=right|down|left|up --target=<name> --name=<name> --command=<cmd> --view=<path-or-url-or-diff> --shell=<path> --working-directory=<path> -e <args...>
```

- `--direction`: Split direction. Default: `right`.
- `--target`: Named window to split in. Default: **the pane the command was
  invoked from** (see Caller anchoring), falling back to the most recently
  focused window. A **pane** name here resolves to that pane's window and splits
  the window's *active* pane, not the named one.
- `--pane`: Named pane to split off — the exact pane, whatever has focus. Use
  this, not `--target`, to split a specific pane: `--target=<pane>` silently
  splitting a different pane once built a three-high column that the
  stacked-panes layout then tucked out of sight (T2163).
- `--name`: Register the new pane with a name for later targeting. **A pane
  name belongs to the window the pane is in** (see Naming; macOS main
  71da9a680, Windows T2250): only a pane of that name in the window the split lands in, or a
  window of that name, collides. A pane called `draft` in another window does
  not — this split creates this window's own. (Names used to be one namespace
  across every window. Session A's `+split --name=draft --view=…` and session
  B's same command, in another window, collided: B got exit 0 and "reused" A's
  pane in A's window, and the agent reported a side pane the user never saw.
  With a different `--view`, B got exit 1, retried, and the user had to say
  "open it!".) Window names stay global, and a pane never takes one. Re-running the same
  split reuses the pane; anything else fails rather than doing nothing (T2184,
  main c2057a810 — identical on both platforms, wording included):
  - **Matches** (a terminal again, or a viewer showing that `--view` or opened
    with it): no split, exit 0, stdout says `pane '<n>' already exists in
    <window>; reused it, no split created`. On Windows a local path matches
    regardless of case and slash direction, since it names the same file.
  - **Doesn't match** (another `--view`, a terminal where a viewer stands or the
    reverse, or the name is a window's): exit 1, stderr names the pane, its
    window and what it shows. Nothing is retargeted — the pane belongs to
    whatever opened it, often another agent. Use another `--name`, or `+close`
    it first.
  - **Created**: stdout says which pane and where (below). A `--target` that
    names nothing fails.

  The line travels in the response's additive `message` field, which the CLI
  prints to stdout; a CLI older than the app ignores it. Policy and wording:
  `src/apprt/ipc/split_name_collision.zig` (Mac: `SplitNameCollision.swift`);
  acceptance: `test/win32/split-name-collision.ps1`. Mac tests:
  `SplitNameCollisionTests`, `PaneNameScopeWindowTests`.
- **The reply is sent after the split, and says what happened** (macOS, main
  71da9a680; Windows: T2250). It used to be sent first (`created …`) with the
  split run afterwards on the main queue, where a failure (the anchor gone from
  its tree, the insert refused) only logged at a level that is not persisted —
  so `+split` could not fail, and an agent reported a pane that never opened.
  Now `handleSplit` waits, bounded (10s), for the pane to exist and be laid
  out, and replies with one of:
  - **Created**: exit 0, stdout `created pane '<n>' (<id>) in window '<w>',
    showing <view>` — or `created pane <id> in window '<w>'` without `--name`.
    The pane id is there so a caller can target the pane without naming it.
  - **Created, minimized**: the same line ending `; it is minimized to a strip,
    since its row has no room for it on show`. Exit 0; the pane exists. (With
    the side-pane rule in Stacked panes this is rare.)
  - **Failed**: exit 1 and the reason on stderr — including a `--target` /
    `--pane` that names nothing, an ambiguous name, and a split that did not
    finish within the wait (it may still appear; the message says so).

  An **agent-backed terminal split** (session persistence, a remote machine)
  asks the agent for the parent's cwd off the main thread and is created a beat
  later; `newSplit`'s `onFinish` reports that path's success or failure too,
  so it is waited on like a local one. On show is read from the layout
  (`PaneStackState.stackMinimizing`) once the pane is laid out; a window that
  never lays it out (not on screen) gets no on-show claim either way.
  On Windows the split itself is synchronous on the GUI thread (an
  agent-backed pane's reply is still held until its session binds, T1612), and
  on show is read from the stacked-panes grid as laid out (`is_tucked`;
  `IpcHandlers.paneOnShow`). Wording: `apprt.ipc.args.splitCreatedMessage`.
- **Every `+split` is logged at `.notice`** (persisted; macOS) — on Windows as
  an `IPC +split:` info line in the app log (T2250): the caller
  pane, the window it resolved to, the anchor pane, the name and view, the
  outcome (created / reused / name collision / failed / timed out) and whether
  the new pane is on show. Ambiguous name lookups are logged the same way. Read
  them with `/usr/bin/log show --last 1h --predicate 'subsystem BEGINSWITH
  "com.dzearing.ghoztty" AND category == "IPCServer"'`.
- `--focus`: Move keyboard focus to the new pane, raise its window, and activate Ghoztty. Without it the pane that had focus keeps it.
- `--view`: Open a **viewer** pane (see `docs/claude/viewers.md`) instead of a terminal — a file, a local **HTML page**, a website, or a **git diff** (`git-status:` / `git-diff:<revspec>`, see Git diff panes in that doc). Mutually exclusive with `--command`/`-e`. Works with `--pane` targeting, including splitting off an existing viewer pane.

On Windows, `ghoztty +list --pid=<pid>` prints just the name of the pane
whose shell is an ancestor of the given process id — the tty-less way for a
process inside a pane to discover its own pane (e.g. `ghoztty +list
--pid=$(cat /proc/$$/winpid)` from git-bash — `$$`, not `self`: the pid must
still be alive when the server walks ancestry, and `/proc/self` read via
`cat` names the already-exited `cat` — or `--pid=$PID` from PowerShell).

### `ghoztty +close`

Close a named pane or window. Closing a nonexistent target succeeds silently.
For a session-persistence pane this ENDS the agent session (the process is
killed once the close's undo window expires) — same as closing the pane in the
GUI. Only an app quit keeps sessions alive for re-attach.

```
ghoztty +close --target=<name>
```

### `ghoztty +rearrange`

Replace a window's active tab's whole split layout with one given as JSON —
every leaf names an already-existing pane, so this MOVES panes rather than
creating them.

```
ghoztty +rearrange --target=<name> --layout='{"direction":"horizontal","ratio":30,"left":{"pane":"a"},"right":{"pane":"b"}}'
```

**A pane the new layout omits is CLOSED, session and all** (T128, win32; the
Mac half is T683). Dropping a pane out of the layout destroys it, so it ends
its agent session exactly as `+close` on that pane would — it used to DETACH
instead, leaving the child running under the agent forever, pinned against the
idle reaper with no pane anywhere that could reach it. A pane the new layout
still names is only being moved and is never touched: the marking runs through
`agent_recovery.closesDepartingLeaf` → `sessionSpared`, so a session the new
tree still references is never ended (main's `e65cfa4d5` invariant, which is
what keeps recovery-style tree swaps safe). Acceptance:
`test/win32/rearrange-session-drop.ps1`.

**A rearrange can be undone** (T2234, Mac "Rearrange Layout"): Ctrl+Shift+Z
puts the previous layout back and Ctrl+Shift+Y redoes it, on the same
per-window undo stack as a closed pane. So "omits is CLOSED" happens when
`undo-timeout` (default 5s) expires, not at the call: until then an omitted
pane is hidden and out of `+list`, with its shell and session untouched, and
the undo brings it back with its name. `undo-timeout = 0` restores the
immediate close. Glue in `src/apprt/win32/LayoutUndo.zig`, the pure layout
logic in `layout_undo.zig`; acceptance `test/win32/rearrange-undo.ps1`.

### `ghoztty +read`

Read the last N lines of terminal output from a named pane and print to stdout.

```
ghoztty +read --name=<pane> --lines=<N>
```

- `--name`: Named pane to read from (required).
- `--lines`: Number of lines from the end of scrollback (default: 50).

**An empty pane is an answer, not an error** (T181, win32; the Mac half is
T481). A terminal pane that has printed nothing yet exits 0 with empty output,
the way `tail` of an empty file does — that is the state of *every* pane for
the first fraction of a second of its life (the window is registered, and
`+list --json` already reports its pane id and its child's pid, before the
shell has painted a prompt) and the permanent state of a pane running something
silent. It used to answer `failed to read terminal content from '<pane>'`,
which a caller could not tell apart from a missing or wedged pane — so a caller
that read once recorded "the pane produced no output" as a verdict. Every
remaining failure names a distinct state: `not found in registry`, `is no
longer alive`, `is a viewer pane, not a terminal`, `is not readable: its
terminal never finished starting up`, and `failed to read terminal content`
(now only a genuine internal failure). `+send-keys` splits the same two
liveness states apart. The "last N lines" rule itself lives in
`src/apprt/ipc/read_tail.zig` so both platforms describe it identically.

**A pane on the alternate screen reads back the visible screen** (T193,
win32; the Mac half rides with T481). A TUI pane — htop, a pager, a
full-screen installer — answers `+read` with what a user looking at the pane
sees, because the dump reads the *active* screen; the alternate screen has no
scrollback by design, so the visible frame is the whole truthful answer. When
the program leaves the alt screen (`ESC[?1049l`), the primary screen's
scrollback is readable again. Regression arm: G in
`test/win32/ipc-read-race.ps1`.

### `ghoztty +list`

List open windows, tabs, and panes (human-readable tree, or `--json`). Listing auto-registers every pane it discovers, so returned names are immediately usable as targets.

```
ghoztty +list [--json] [--tty=<tty>]
```

- `--tty`: Print only the registered name of the pane whose terminal matches the given tty (`ttys014` or `/dev/ttys014`; raw padded `ps -o tty=` output is accepted), then exit. Exits 1 if no match. Lets a process find its own pane: `ghoztty +list --tty="$(ps -o tty= -p $PPID)"`.

`--json` windows carry a **`chrome`** object reporting where the tab strip's
clickable regions ARE (T231) — `{"dpi": 120, "tab_strip": {"band", "tabs",
"new_tab", "menu"}}`, every rect in the window's CLIENT coordinates, physical
pixels, right/bottom exclusive. They are not a fresh layout pass: they are the
rects the window's own hit tests read, so what is reported and what a click
reaches cannot drift. **`null` means there is nothing there to hit** — the
`menu` on a window whose caption hosts the menu (T260), a tab the strip could
not fit, every region of a strip that has not painted yet — and `tab_strip:
null` means the window shows no strip at all, which is a different answer from
the whole `chrome` key being absent (a server that cannot say). `band` is where
strip content may sit: inside both insets, the buttons' own vertical band, and
on a merged caption row its right edge is the seam rather than the window edge.

This exists because the alternative is a second implementation of
`tab_strip_layout` in whatever language the caller is written in, and that
cannot be type-checked against the first: the win32 acceptance harness kept one
and it rotted twice — a fixed "46px left of the right edge" that landed inside
the menu button at 125% DPI, then a modelled tab width that stopped matching
when T235 sized tabs to their titles. Both produced failing assertions against
a completely healthy product. Consumers ask
`Get-TestStripRegions` (`test/win32/lib/ChromeGeometry.ps1`); a pixel scan is
now only for asserting that something is PAINTED, never for finding a click
target. (win32 server since T231; the Mac server half is T735.)

`--json` terminal panes carry a **`readonly`** field when the pane is in
read-only mode (T574) — the machine-readable half of the badge the pane wears.
This is the question an automation asks when `+send-keys` reported success and
nothing happened: read-only drops every keystroke on the floor, so a read-only
pane and a wedged pane look identical from the outside unless the wire says
which one it is. The field is **additive** — absent, not `false`, when the mode
is off, and absent from viewer panes — so an older client sees exactly the
shape it always saw. (Both servers since T574.)

`--json` terminal panes carry a `session_id` field when the pane is bound to a
session-persistence agent session — the join key against `+sessions --json`,
so a script can answer "which pane is this session open in" (and vice versa)
without app logs. Absent for plain non-persistent panes and viewers. (win32
server since T332; the Mac server half is T553.)

**It is readable the moment the creating verb returns — no poll** (T1612).
`+new-window` and `+split` answer only once their new pane's agent session is
bound, so one `+list --json` straight after the verb carries the id. Before
this the verb answered as soon as the window existed and the OPEN landed
250-774 ms later, so a cold-start query read no id 11 times in 15. The wait is
**bounded** (3 s, `ipc_session_await.budget_ms`) and a pane whose OPEN *failed*
ends it at once, so the verb still answers or explains rather than blocking:
past the budget the reply goes out as before (the app log says so), and a
script that got no id then is looking at an agent that is not answering, not
at a race. It holds only the one request's reply — the GUI keeps pumping and
other IPC clients are served meanwhile. (win32 since T1612; the Mac server
has to hold the same contract once T553 gives it the field.)

The join answers in BOTH directions, and the two are not interchangeable:
`+list --json`'s `session_id` goes pane -> session and needs the app running,
while `+sessions --json`'s `pane_id` goes session -> pane and dials the agent
directly, so it is the only one that answers with the app CLOSED (T552). The
agent records it from the `$GHOZTTY_PANE_ID` the viewer bakes into the OPEN's
env, and persists it, so a relaunchable tombstone still names its pane after a
reboot. Null when the app that opened the session was too old to bake the var,
and absent entirely from an older agent. For a cross-machine window it names a
pane on the VIEWING machine while the session runs on the agent's — the join a
script wants in both cases, since it already knows which agent it dialed.

### `ghoztty +sessions`

List the persistent terminal sessions owned by the local `ghoztty-agent` (the daemon that keeps session-persistence PTYs alive across app restarts). Unlike the other IPC commands, this dials the agent **directly** over its 0600 unix socket (`~/.config/ghoztty/local-agent[-debug]/agent.sock`) — NOT the app's IPC socket — so it works even when the Ghoztty app is not running (as long as the agent is). Requires `session-persistence = on`. On Windows the agent's local transport is instead an owner-only-DACL **named pipe** (`\\.\pipe\ghoztty-agent[-debug]-<user>`); the endpoint is discovered from the agent's `pipe` field in `%LOCALAPPDATA%\ghoztty\local-agent[-debug]\port.json`, and the same-uid guarantee comes from the pipe DACL rather than a peercred check.

```
ghoztty +sessions [--json] [--agent]
```

Each row reports the session id, liveness (`alive`; `dead(relaunchable)` for a tombstone that RELAUNCH can still revive — e.g. after a reboot or agent restart; or `dead(<code>)` for a genuinely exited session), whether a viewer is currently `attached`, the activity state (`idle`/`busy`/`needs_input`), the child pid, `pinned` when the session is protected from the agent's idle-TTL reaper (persistent local panes are pinned so they survive the viewer quitting indefinitely; cross-machine sessions are not), the working directory (when known), and the command. `--json` emits one object per session for scripts and agents — including `pane_id`, the pane the session was opened for, which the human table deliberately omits (a pane id is a UUID nobody reads off a terminal).

```bash
ghoztty +sessions
ghoztty +sessions --json
```

**`--agent` answers which BUILD is running** (T662), instead of listing
sessions. The agent outlives the app on purpose, so it is routinely a different
build than everything around it — and until this existed that comparison
happened only in an app log line, on a box where the app had already been
restarted past the interesting moment:

```
running:  20260719-574fe0805  (pid 24228)
bundled:  20260730-e69d41755
status:   stale - 11 days behind, 4 live sessions
next:     Ghoztty restarts it onto the bundled build when no sessions are open, or when you confirm the restart it offers.
```

`status` is a machine token — `current`, `stale`, `newer`, `unknown` (the
bundled binary could not be read), `not_running` — and `--json` emits it with
`running`, `bundled`, `days_behind`, `live_sessions`, `sessions`, `agent_pid`,
`handoff` and `legacy_sessions`. **No agent running is an answer, not an error**: it exits 0 with
`not_running`, because the next persistent session simply starts the bundled
build. `days_behind` is calendar days between the two `YYYYMMDD` stamps, and is
absent rather than 0 or negative whenever there is no honest number to give (a
`dev` stamp, a pre-versioned agent, a same-day rebuild, a newer running agent).
Staleness itself is defined in exactly one place for both readers —
`src/remote/agent_build.zig`, shared by this CLI and the win32 upgrade policy
(`agent_upgrade.zig`) — so the number a user reads and the decision the app acts
on cannot disagree. Acceptance: `test/win32/sessions-agent-build.ps1`.

**How a long-lived box adopts a newer agent** (the state this command exists to
make visible). Since **T907** the answer on Windows is: **the agent replaces
itself, and no session closes.** `handoff` is the machine token for that, and it
is what the `next:` line is written from:

- `ready` — a newer build beside it is adopted on the agent's own schedule, with
  nothing asked and nothing lost. `next:` says so.
- `draining` — it will, but not yet: `legacy_sessions` counts the live sessions
  whose ConPTY the agent owns DIRECTLY. Those cannot be carried across a process
  boundary at all, so each one has to close first. (`draining` is also what an
  unreadable roster reports, because "your update costs nothing" is a promise and
  that case did not verify it.)
- `unsupported` — an older agent, or a seat where the mechanism has not landed.
  Then the pre-T907 answer applies, and it is the one that could go unreached
  indefinitely: restart at zero live sessions, or the mandatory confirmation. On
  a box whose panes never all close, neither happens — the morning app-only
  refresh (T525) deliberately never swaps `ghoztty-agent.exe` and defers that
  confirmation, and the check re-runs only at launch and when the last persistent
  window closes. There the documented path stays an **attended full delivery**
  (`scripts/launch-upgrade.ps1` without `-AppOnly`, which does prompt).

Mechanism and contract: `docs/claude/sessions.md`; design:
`docs/design/agent-nondestructive-handoff.md`.

### `ghoztty +send-keys`

Send text input to a named pane's terminal PTY.

```
ghoztty +send-keys --target=<name> [flags] <text|key>...
```

> **To submit, end the text with `\n`** — `ghoztty +send-keys --target=t "prompt\n"`.
> (`--enter`, or a separate `Enter` argument, do the same thing. Use one, not
> two — they stack, and two of them submit twice.)

- `--target`: Named pane or window to send input to. Required.
- `--enter`: Press Enter after the text. Same as a trailing `\n` or a trailing `Enter` argument. On its own, with no text, it just presses Enter.
- `--when-idle`: Poll the target pane's recent output every 500ms until it looks idle before sending: the tail unchanged across ~1s (busy TUIs animate spinners/timers every second; an idle prompt is static — this catches any working program, no tool-specific marker needed) AND none of the caller's `--busy-marker` texts present. Sends anyway after `--idle-timeout=<seconds>` (default 30) or if the pane can't be read.
- `--busy-marker=<text>`: Extra busy signal for `--when-idle` — while `<text>` appears in the pane's last lines, the pane counts as busy even if its tail is static. Repeatable; any match counts. The CLI deliberately bakes in no tool's chrome (T517/D11): a caller that knows what its program prints while working names it here (e.g. older Claude Code rendered `esc to interrupt`; current versions animate, which motion detection already catches).
- `--keys-file=<path>`: Send the file's bytes **verbatim** — no key notation, no
  `\n` escape processing. It keeps its position among the positional arguments,
  so `--keys-file=p.txt Enter` sends the file and then a carriage return. **Use
  this for any text the caller did not author by hand** (a prompt, a path,
  anything with quotes or backslashes): PowerShell 5.1 does not escape an
  embedded `"` when it builds a native command line, so such text arrives as a
  positional argument with its quotes stripped, re-tokenized and concatenated
  without separators, or broken outright. Length is not the hazard — the
  transport is byte-exact at 10,000 characters (T210). **The trailing-newline
  rule below does not apply to it**: the CLI sends a file exactly as it is on
  disk, trailing newline included, because "verbatim" is the flag's whole reason
  to exist and a generated prompt file routinely ends in a newline nobody meant
  as "submit". Submit one with a following `Enter` (or `--enter`). Like any
  text run it follows the paste convention below, so the file's own trailing
  newline reaches a bracketed-paste program (every TUI) as a literal newline
  and does not submit.
- Positional arguments are text or key names, written to the PTY in order.
  Adjacent arguments of the same kind merge into one **run**, and the run
  boundaries survive to the PTY write: a text run is framed as a **bracketed
  paste** (`ESC[200~` … `ESC[201~`, one write) when the program in the pane has
  mode 2004 enabled, and key runs are written bare, outside the frame. That is
  what makes `+send-keys --target=t "a long prompt" Enter` submit — an unframed
  trailing `\r` reads to a TUI as a newline *inside* pasted text, and the
  message sits in the composer unsent. Framing is a property of the bytes, not
  of their timing, so no sleep in the path substitutes for it.
- Key notation: `C-c` (Ctrl-C), `C-d` (Ctrl-D), `C-z` (Ctrl-Z), etc.
- Named keys: `Enter`, `Tab`, `Escape`, `Space`, `Backspace`
- Escape sequences in text: `\n`, `\t`, `\r`, `\\`, `\e`

```bash
ghoztty +send-keys --target=term "hello\tworld\n"   # types, then submits
ghoztty +send-keys --target=term "ls -la" Enter
ghoztty +send-keys --target=term --enter "ls -la"
ghoztty +send-keys --target=term C-c
```

**A trailing newline is a keypress; an interior one is content.** The trailing run of `\n`/`\r` is peeled off a text argument and delivered as that many Enter presses, so `"a\nb\n"` pastes two lines and then submits. **What is counted is line endings, not bytes** (T658): a trailing `\r\n` is ONE line ending written the Windows way and presses Enter once, while repeated endings still count separately (`"a\n\n"` and `"a\r\n\r\n"` both press twice, and a bare `"a\r\r"` still presses twice). Counting bytes there submitted a CRLF-terminated argument twice — the caller's message, then an empty line after it, which a chat-style TUI reads as a second, blank turn — and Windows is where CRLF text comes from. This is a deliberate divergence from upstream main's byte-counting peel (`a7f7476e1`), which T604 ported verbatim; round 17 of `test/win32/send-keys-bracketed.ps1` is the on-wire oracle. This runs after escape processing, so `\n` written as the two-character escape and a real newline byte behave identically. The accepted cost: there is no way to paste text ending in a literal newline without submitting — a trailing newline in a paste means "commit" essentially always, and a program that has not enabled bracketed paste sees `\r` mapped back to `\n` by the tty's `ICRNL` anyway. (`--keys-file=` is exempt; see above.)

**A newline inside a text run follows the paste convention, on both platforms** (T661). A program that has enabled bracketed paste receives it as a literal `\n` — it is a line break in the pasted content, which is what makes `"a\nb\n"` type two lines into a composer and then submit. A program that has NOT receives `\n` mapped to `\r`, which is what xterm has always done for an unbracketed paste (`src/input/paste.zig`) and what makes the same send run two commands in a shell. macOS reaches the second half for free, because a POSIX pty accepts LF as a line terminator; Windows has to do the mapping, because conhost's VT input translation **swallows a bare LF** — without it `+send-keys "echo A\necho B\n"` reaches `cmd.exe` as `echo Aecho B`. The win32 rule is `IpcHandlers.prepareSendKeysRun`; rounds 11, 12 and 15 of `test/win32/send-keys-bracketed.ps1` measure both halves on the wire.

That rule needs to know the CLI already spelled `Enter` as CR, and a flat `--keys=` payload cannot say so by itself, so **every `+send-keys` request carries `--keys-resolved=1`**. A request without it came from a CLI old enough that a bare `\n` meant Enter and is normalized unconditionally, exactly as before — a server ignores the argument it does not know, and macOS, which never normalized at all, ignores it forever. Round 16 is that control.

**Any unknown `--flag` is a hard error** (exit 1), naming the submit spellings. `--press-enter` used to become a text positional and get typed into the pane at exit 0, which is how agents got this wrong without noticing. Single-dash arguments (`-la`, `-p`) are ordinary text. To send literal text starting with `--`, put it after a bare `--`, which stops flag parsing but not key notation:

```bash
ghoztty +send-keys --target=term -- "--not-a-flag" Enter
```

**Text and keys stay distinguishable.** Argument boundaries survive all the way to the write. When a call mixes text with keys, adjacent arguments of the same kind merge into a run, and each **text** run is written to the pane as a **bracketed paste** (`ESC[200~` … `ESC[201~`) while each **key** run is written bare, outside the frame.

This is what makes `+send-keys --target=t "some message" Enter` actually submit. Flattened into one burst of bytes ending in `\r`, a TUI's paste detection reads that `\r` as a newline inside pasted text — correctly, since that is exactly how a real multi-line paste looks — and the message sits unsent in the composer. Framing states which bytes were pasted, so the `\r` after the closing fencepost is unambiguously a keypress. It is a property of the bytes, not of their timing, so there is no delay anywhere in the path.

Two consequences worth knowing:

- A text run is framed **in a single PTY write**. Splitting the frame across writes lets the opening fencepost land in its own `read()` on the far side, and a receiver that sees a lone `ESC[200~` does not reliably associate it with the content after it (measured against Claude Code, which then falls back to its length heuristic and swallows the `\r` again).
- Framing only happens when the program running in the pane has **enabled bracketed paste** (DEC mode 2004) — which every modern TUI and interactive shell does. A pane running something that has not (`cat`, a shell script's `read`) gets the bytes verbatim, so nothing can inject literal `[200~` junk into a program that would not understand it. Text containing `ESC[201~` is also sent unframed, rather than emitting a frame that would close early.

Single-kind calls — `"text"` on its own, `Enter` on its own, `C-c` on its own — have no boundary to disambiguate and are sent byte-for-byte as they always were.

**Delivery integrity is measured, not assumed** (T664). A pane read cannot tell a byte that never arrived from a byte the grid lost, which is how one sighting of a text run missing its FIRST character — a `--keys-file` run landing a beat after a bare Enter — stayed an anecdote. Rounds 13–14 of `test/win32/send-keys-bracketed.ps1` pin that shape on the wire, byte for byte, including a payload long enough to cross the 64-byte pooled write buffer in `termio.Exec.queueWrite` (the only seam that splits one run across two PTY writes). `test/win32/send-keys-soak.ps1` repeats it a few hundred times with randomised gaps, judged by a receipt file the in-pane shell writes rather than by the screen; it is **on-demand, not part of P1–P3**. 315 measured sends found no loss, so nothing in our write path is known to truncate a run — the unexplained leg, if it recurs, is conhost's VT input translation and cygwin's console reader.

**A boundary the CLI cannot see is a boundary it cannot encode.** Framing spans one call, so a caller that must split the text and the Enter into two calls — the self-upgrade does, because it verifies the prompt arrived before submitting it — gets a flat text run and a naked CR no matter what the CLI does. Such a caller submits with `" " Enter` rather than a bare `Enter`: the throwaway space makes the *submitting* call a mixed send, so a closing fencepost lands immediately before the CR. A trailing space means nothing to the receiver, which is what makes it safe — a submit that instead withheld the prompt's own last character would submit a truncated prompt if that character were dropped. Shared helper: `Get-LoopSubmitArgs` in `scripts/loop-session.ps1` (T438); byte-level oracle: rounds 6–8 of `test/win32/send-keys-bracketed.ps1`.

### `ghoztty +set-state`

Set the activity state of a named window or pane. The state is aggregated across all panes in a window (priority: `needs_input` > `busy` > `idle`) and shown as a title suffix and custom `AXWindowActivityState` accessibility attribute.

`idle`/`busy`/`needs_input` are the **machine tokens** — the vocabulary of this flag, of the OSC 7777 payload, and of `AXWindowActivityState`. They are a public API (hooks call the CLI, external tools like ztabby read the attribute) and do not change for readability. The **title suffix** shows a human label instead, and the two differ for one state: `needs_input` renders as `(question)`. Consumers must read the accessibility attribute rather than parsing the title.

```
ghoztty +set-state --target=<name> --state=<idle|busy|needs_input>
```

- `--target`: Named window or pane. Required.
- `--state`: Activity state. Required. One of `idle`, `busy`, `needs_input`.

```bash
ghoztty +set-state --target=dev --state=busy
ghoztty +set-state --target=dev --state=needs_input
ghoztty +set-state --target=dev --state=idle
```

Processes can also set state via OSC escape sequence: `\033]7777;<state>\007`

**`needs_input` means a question is actually on screen.** It is set by
`AskUserQuestion`/`ExitPlanMode` (PreToolUse), `PermissionRequest`, and only
the `permission_prompt`/`elicitation_dialog` **Notification** types — never
`idle_prompt`, which Claude fires ~60s after *every* turn ends with no input
(pausing on it turned each idle pane into "question" a minute after it
finished). The generated hook narrows Notification with a matcher
(`ClaudeHookSpec.blockingNotificationMatcher`), and the script's `pause` also
filters by `notification_type`, failing closed on an unknown or missing type,
so a hook installed before the matcher is fixed by the script alone. A pause is
undone by the next main-thread tool call **or by a submitted prompt** (a
dismissed permission prompt or a question answered in prose runs no tool), and
`session-start` drops a marker its pane's previous session left. `+list --json`
reports each terminal pane's `state` (machine token); the human `+list` marks
non-idle panes `[busy]` / `[question]`. **Windows:** the win32 generated hook
(`src/apprt/win32/ClaudeHookSpec.zig`) still has the unmatched Notification
hook — T2001.

### `ghoztty +set-banner`

Set or clear the sticky banner of a named pane or window. The banner is a native overlay rendered above the terminal content of a pane — it persists (survives scrolling, screen clears, and content updates) until changed or cleared. Setting a banner on a window target applies it to that window's focused pane (banners are per-pane).

```
ghoztty +set-banner --target=<name> [--clear] [text...]
```

- `--target`: Named pane or window. Required.
- `--clear`: Remove the banner (empty text does the same).
- All other arguments are treated as the banner text (multiple are joined with spaces).

Banner text supports a small markdown subset: `**bold**`, `*italic*` or `_italic_`, `__underline__`, `` `code` ``, and `[text](url)` clickable links (URL must include a scheme, e.g. `https://`). Note `__underline__` intentionally differs from CommonMark (where `__` is bold). `\` escapes the next character. Unterminated delimiters render literally. A literal `\n` in CLI banner text becomes a line break — banners can span multiple lines (display is capped at 10 lines).

**Autolinking.** Bare URLs and bare file paths become clickable without `[text](url)` syntax. A URL must carry a scheme — only `http://` and `https://` linkify, never a bare `www.example.com` or `config.io`, so prose is never falsely linked. A file path must start with `/`, `~/`, `./`, or `../` — **plus, on Windows, a drive path (`D:\…`, `D:/…`), a UNC share (`\\server\share\…`), and the backslash spelling of each relative sigil (`~\`, `.\`, `..\`)**; the sigil is the whole signal (there is no filesystem check), which is why a bare relative `macos/Sources/Foo.swift` or `docs\design\foo.md` stays plain text. `~/` expands to the home directory and `./`/`../` resolve against **the pane's current working directory** at render time — a dot-relative path in a pane with no known cwd stays plain text rather than resolving against a guess. Trailing sentence punctuation stays outside the link (`See https://x.com.` links `https://x.com`), while brackets balanced *inside* the link are kept (`…/Foo_(bar)`). Autolinking never fires inside a `` `code` `` span, after a `\` escape, or inside an explicit `[label](url)` — the explicit link always owns its whole label. Shared rules, one implementation per platform: `SurfacePaneBanner`'s `autolink` on macOS, `banner_markdown.autolink` on Windows (T539), where the pass runs **ahead of the backslash-escape branch** because a UNC path opens with the escape character itself — `\\server\share` would otherwise be eaten one `\` at a time. Acceptance: section 6j of `test\win32\pane-banner.ps1`.

**"At render time" means the link follows a `cd`** (T758). The same banner text, left untouched, points into whatever directory the pane is in when a link is clicked — macOS gets that for free by taking the cwd on every render pass. Windows caches parsed blocks and repaints far more often than a directory moves, so it re-parses on the *move* instead: when the pane reports a new cwd (OSC 7 / shell integration), and — for the shells that report nothing, `cmd.exe` above all — from a bounded read of the shell's real working directory taken the instant before a banner link is acted on. Only the banners that carry a `.\…`/`..\…` link are ever re-parsed (`banner_markdown.dependsOnCwd`); absolute paths, UNC shares, `~\…` and URLs need no context, so a `cd` cannot move them and does not make them re-parse. Acceptance: section 6k of `test\win32\pane-banner.ps1`.

**Link clicks.** A plain click hands the link *out* of Ghoztty; the modifiers bring it back in. Cmd (**Ctrl on Windows**) opens a **viewer side pane** for either kind of link, and Cmd-Shift (**Ctrl-Shift**) gives the link a surface of its own.

| | plain click | Cmd / Ctrl | Cmd-Shift / Ctrl-Shift |
|---|---|---|---|
| **URL** | default browser | side pane | new Ghoztty window |
| **file path** | reveal in Finder / File Explorer | side pane | open with default app |

A URL goes to the real browser by default because Ghoztty's `WKWebView` (WebView2 on Windows) keeps its own cookie store with no relationship to Safari/Chrome/Edge — anything behind a login renders logged-out in a viewer pane, and OAuth sign-in never completes. A file path is only *revealed*, never opened, so a click can't launch whatever app claims the extension. The right-click menu offers all of them (its first item is by contract the left-click default) plus Copy Link / Copy Path.

**Link hover affordance.** A banner link's underline is **dotted at rest and solid while the pointer is over it** (plus the pointing-hand cursor), so a link reads as a link before you click and tells you which one a click would take. Hovering lights the WHOLE link, not the fragment under the pointer — a link split by wrapping or by nested styling goes solid together. The underline is drawn by hand rather than by the font's own underline attribute, because there is exactly one of those and it is solid: a link would otherwise either always look hovered or never look like a link. Shared with the same click/menu model on both platforms (win32: `banner_link.zig` + `banner_layout.linkUnderline`, T165).

**Lists.** Consecutive lines that begin with a list marker render as a list block with table-like row spacing and a **shared marker gutter**, so every item's content left-aligns regardless of marker kind (bullets, numbers, and checkboxes in one run all line up). Supported markers:

- `- ` or `* ` → an unordered **bullet** (`•`).
- `1.`, `2.`, … (digits, a period, then a space) → an **ordered** item, rendered with the source number. A decimal like `1.5` (no space after the dot) stays plain text.
- `[x]`/`[X]` (checked) and `[ ]` (single space, unchecked) → a read-only **task-list checkbox**, drawn as a **native box** (rounded 2px corners; checked shows a green check on a faint green wash), not a plaintext glyph. A `- `/`* ` directly before a checkbox is the checkbox's marker, not a separate bullet (`- [x] done`). Checkboxes are display-only (no interactivity), and `[x](url)` is still a link (the `x` is link text). Checkboxes in **table cells** render the same native box. A checkbox that appears mid-paragraph in a wrapping (non-list) text line falls back to the `☑`/`☐` glyph.

**Separators.** A line of 3+ of the same `-`, `*`, or `_` (spaces allowed — `---`, `***`, `___`, `- - -`) is a **thematic break**, rendered as a full-width horizontal divider between the blocks above and below it (e.g. to separate a title, a table, and a trailing note). A `- `/`* ` bullet or `**bold**` on its own line is unaffected (they carry non-marker content or mixed characters). Each rule counts as one line toward the 10-line display cap.

Banners also support standard markdown pipe tables, rendered as an aligned grid with a bold header row: a `| a | b |` header line immediately followed by a `|---|---|` separator with the same column count, then `| 1 | 2 |` body rows. Separator cells may carry `:` alignment markers (`:---` left, `:---:` center, `---:` right). Cells support the full inline subset; `\|` puts a literal pipe inside a cell. Ragged body rows are padded/truncated to the header width. The separator row doesn't render; every other table row counts toward the 10-line display cap (a row still counts once no matter how many lines its cells wrap to). **Long cell text word-wraps** onto multiple lines and the row grows to fit, rather than truncating to one line — matching a normal markdown renderer. Column widths derive from the pane's current width, so the banner reflows live as the pane is resized and never blocks the pane from shrinking (even a long unbroken token breaks mid-string). A cell is capped at **3 wrapped lines** — a cell that would wrap further (e.g. a long unbroken string in a very narrow pane) is tail-truncated with an ellipsis on its last visible line, so one nasty cell can't blow up the banner height. A cell that contains an *inline* task-list checkbox stays a single line (its native box can't reflow around wrapping text).

**Everything wraps, by one rule.** Paragraphs, headings and list rows wrap exactly the way table cells do (T377) — greedy word wrap against the pane's current content width, a long unbroken token broken mid-string, and the same **3-line cap** with a tail ellipsis on the last visible line. A wrapped list row's continuation lines start at the shared marker gutter, not back under the marker, and a task-list row wraps like any other (its checkbox is the row's *marker*, drawn in the gutter, so nothing has to reflow around it). The wrapped height is what the renderer reports upward, so the band, the pane inset and the terminal below all follow it. The 10-line display cap still counts a wrapped block **once**, the way a wrapped table row counts once.

**The collapse chevron owns the card's right strip.** Content — every block, not just the first line — stops a clear 4 DIP short of the chevron's box, so no paragraph, heading, list row, table cell or rule ever paints under it. The reservation is pure geometry (`banner_layout.contentWidth`, asserted at 1.0/1.25/1.5/2.0) and applies only when the banner is collapsible, i.e. when a chevron is actually drawn.

**Collapsing animates the card and only the card.** The card eases between its expanded and collapsed heights over 180ms (`banner_layout.COLLAPSE_MS`, Mac's `easeInOut(0.18)`), while the band the window layout reserves — and therefore the terminal grid below it — moves to the settled height in ONE step per click. Both platforms arrive there from opposite directions: Mac drives its inset off a hidden, animation-free copy of the banner content so the Metal surface never chases intermediate frames; win32 simply never lets the animation into `stripHeight()`, and lets the still-tall card overhang the terminal for the length of a collapse. A second click mid-flight reverses from the height the card is actually at, and users who turned off Windows' "animation effects" (`SPI_GETCLIENTAREAANIMATION`, read in one place: `App.clientAreaAnimationsEnabled`) get the instant toggle. What win32 does NOT do yet is Mac's parallel cross-fade of the body — it clips the content to the animating card with the existing bottom fade instead, filed as T677. Acceptance: section 6f2 of `test/win32/pane-banner.ps1` (T149).

```bash
ghoztty +set-banner --target=dev "**Build status**\n| Job | State |\n|---|---:|\n| lint | ok |\n| tests | **3 failed** |"
```

```bash
ghoztty +set-banner --target=dev "**PR #123** — _3 files_, +120/−45 — [view](https://github.com/org/repo/pull/123)"
ghoztty +set-banner --target=dev --clear
```

Processes can also set the banner from inside the pane via OSC escape sequence: `\033]7778;<text>\007` (empty text clears). The interactive equivalent is Cmd+R ("Set Pane Banner…", also in the command palette), which opens a multi-line editor for the focused pane's banner (Return inserts a newline, Cmd+Return saves, Escape cancels). Cmd+R only reaches this while a **terminal** pane is focused — a focused viewer pane takes Cmd+R for reload (see `docs/claude/viewers.md`). On Windows the editor chord is Ctrl+Shift+B and Ctrl+Enter saves (plain Ctrl+R belongs to the shell).

**Collapse/expand never shows the terminal resizing** (macOS, main a81db68f9;
Windows: T2252). Clicking the card (or its chevron) collapses it to its title
row. The terminal is resized ONCE, at the click, while a frozen copy of its
last frame stands in for it (`SurfaceView.frozenFrame`: a copy of the
renderer's IOSurface — same pixels, format and color space — not the surface
itself, which the renderer draws into again); the live terminal comes back once
it has redrawn at the new size and its frames have stopped changing
(`resizeOutOfSight`, capped at 0.5s). That resize skips the 100ms debounce
(`ghostty_surface_flush_resize`), so a shell's prompt redraw lands in a frame
or two. The copy is shown by a view that sets its layer's contents in
`updateLayer` (`FrozenLayerView`): contents set on a layer-backed view from
outside are wiped by its next display, which blanked the copy for a few frames
now and then. The copy and the live terminal move to where the content will
land, along one path with the card's curve (`BannerGlide`): the core predicts
it with the grid's own resize rules before resizing
(`ghostty_surface_predict_resize_shift`). So a prompt at the **top** of the
screen rides the card's edge down or up, and content laid out to the
**bottom** (a shell at the end of its scrollback; a full-screen program on the
alternate screen, taken to lay out to the bottom like an agent's input box)
holds still while the card covers or uncovers rows above it (the terminal is
masked at the card's animated edge, `bannerReveal`). It used to resize while
the card animated: the prompt jumped a row, vanished for a frame (it is
cleared on resize for the shell to redraw) and came back, and jumped again
when the card finished. Separately, the renderer's layer refuses a frame drawn
earlier than the one it shows (`IOSurfaceLayer` frame sequence): on any resize
an async frame of the OLD grid at the NEW size could land after the
synchronous redraw, and an idle pane then kept the wrong rows, cursor gone,
until something printed. The collapsed state lives on the surface
(`paneBannerCollapsed`, ephemeral; a cleared banner comes back expanded).
Tests: `BannerCollapseWindowTests` (recorded at the display's frame rate;
frames in `/tmp/banner-collapse` and `/tmp/banner-collapse-prompt[-agent]`;
the prompt cases run in a plain local pane and in an agent-backed one, whose
shell redraws a round trip later).

Banners are persisted per pane in the session-layout manifest (keyed to the stable pane id), so a session-persistence restore brings them back with their text intact — across app quit/relaunch/upgrade re-attach and across an agent-restart relaunch alike. **The banner slot belongs to the pane** (T422): the session-interrupted notice an agent-restart prints is always folded into the pane's scrollback, but only claims the banner slot when the pane has no banner of its own — a restored banner is never overwritten by it. `+list --json` reports each terminal pane's current banner in a `banner` field (absent when no banner is set), which is also the CLI way to read a banner back.

A banner with a **title** — an `## ` heading on its first line, or a one-line banner opening with a standalone `**bold**` run — also **names its pane** in the pane sidebar and on a stacked pane's strip, in place of the pane title (see Stacked panes). **Windows:** the sidebar half landed in T2085; strips arrive with stacked panes (T2081).

### `ghoztty +reload`

Reload a named **viewer pane** (see `docs/claude/viewers.md`) in place — no
close/reopen. Website viewers re-fetch the page from origin (bypassing
caches); file viewers re-render the file preserving scroll position (they
already live-reload on their own, so this mainly matters for URL viewers);
**diff viewers re-run their git command**, picking up commits, staging, and
edits, and keeping the open file and its scroll position. A rendered `.html`
file is re-fetched bypassing caches like a website — the verb is the explicit
"these bytes are stale" one, which is how it picks up an edited sibling
stylesheet that the file watcher never saw.

It is also how a script tells a running instance to **re-read its own
configuration** — `--config`, the app-wide form, which names no pane. That is
the only external trigger for a config reload (T893): the menu's Reload
Configuration comes back in-process from `TrackPopupMenuEx` and never as a
postable `WM_COMMAND`, and the keybind needs a foreground keyboard, so before
this nothing an automation could send reached `onConfigChange` — and
everything a reload changes (fonts, colors, tooltip themes, dividers) was
unreachable by the acceptance harnesses.

```
ghoztty +reload --target=<name>
ghoztty +reload --config
```

- `--target`: Named window or pane (or a pane id). Required unless `--config`
  is given. For a window target the reload applies to its focused pane.
- `--config`: Reload the application configuration from disk, app-wide (a
  HARD reload: the file is re-parsed and its diagnostics surface exactly as at
  startup). Cannot be combined with `--target` — the two are different
  requests, and naming both fails with `--config cannot be combined with
  --target` (exit 1).
- Targeting a terminal pane fails with `... is a terminal pane, nothing to
  reload` (exit 1), mirroring how terminal-only commands reject viewer panes.
- Interactive equivalent: **Cmd+R** while a viewer pane is focused (see
  Viewer Panes → Keyboard).

```bash
ghoztty +split --target=dev --name=preview --view=http://localhost:3000
ghoztty +reload --target=preview
```

### `ghoztty +stash` / `ghoztty +restore`

Take a pane out of its window's split layout and into the window's **pane
sidebar** without ending it, and put it back. See Pane sidebar below.

```
ghoztty +stash --target=<pane>
ghoztty +restore --target=<pane> [--focus]
```

- `--target`: a registered pane name or a pane id (a window target is an error).
- `--focus` (`+restore`): also focus the restored pane and raise its window —
  like every command, it leaves focus alone otherwise.
- Idempotent both ways. `+stash` of the **last pane on screen** in its window
  fails (exit 1): a window always shows at least one pane. Quick Terminal panes
  have no sidebar and are refused.
- A stashed pane stays fully targetable — `+send-keys`, `+read`, `+set-banner`,
  `+set-state`, `+close`, `+reload` — and `+list` marks it `[stashed]`
  (`--json`: `"stashed": true`, absent otherwise, like `banner`).
- A pane folded into a stacked row's strip (a row too narrow for every pane
  at the 225 DIP minimum) is still running and targetable, and `+list` marks
  it `[minimized]` (`--json`: `"minimized": true`, absent otherwise). A
  background tab reports the strips it shows when selected. Windows since
  T2103; the Mac half is T2148.
- `+split` anchored at a stashed pane, and `ghoztty://focus/<stashed pane>` /
  the `--focus` idempotent hits, **restore it first**: a new pane beside an
  invisible one would be invisible, and raising a pane you can't see raises
  nothing. `+rearrange` keeps a stashed pane its layout omits stashed.

**Windows** (T1827): the same verbs, refusals and messages, plus the
`stash_pane` keybind (default **Ctrl+Shift+M**, Mac's Shift+Cmd+M with Cmd
carried as Ctrl+Shift) and `restore_stashed_pane` (unbound, as on Mac). The
stash is a mark on the pane itself (`PaneView.stash_seq`, model in
`src/apprt/win32/pane_stash.zig`), and every split geometry walk collapses a
split whose one side is all stashed panes (`Window.splitRects`). The stash
survives a restart (T1838): the session manifest records a per-leaf
`stash_index` (0 = top, Mac's `stashIndex`) and the restore re-stashes in that
order. Not yet on Windows: the sidebar to SEE the stash in (T1828) - use
`+list` to find stashed panes. Acceptance: `test\win32\ipc-stash.ps1`,
`test\win32\stash-restore.ps1`.

### Naming

- `+new-window --target=<name>` registers a **window**. Window names are
  global: one window holds a name, and a name a pane holds cannot be taken by
  a window (`+new-window --target=` fails rather than "reusing" a pane).
- `+split --name=<name>` registers a **pane**, in the window it lands in.
  **Pane names belong to their window**: two windows can each have a pane
  called `draft` (macOS 71da9a680; Windows T2250).
- `+new-window --name=<name>` registers a **pane** too (T968): the window's
  first pane, or with `--split` the inline split pane. It is idempotent, by
  the name alone (on both platforms it has not taken `+split --name`'s
  match-or-fail rule) — a live pane already under that name is focused instead of
  a second window opening (unless `--target` is also given, which decides
  first). It used to be accepted and silently dropped for a window without
  `--split`, so the next `--target=<name>` answered `not found`.
- `+split --target`, `+close --target`, and `+send-keys --target` reference either kind

**How a name is looked up** (`TargetLookup`, the one policy;
`IPCServer.lookup` applies it). Every command carries the pane it was run from
— the CLI writes `$GHOZTTY_PANE_ID` into each request as a top-level
`caller_pane` field — and the name means, in order:

1. a pane of that name in **the caller's window**;
2. a window of that name;
3. a pane of that name in another window, **if exactly one window has one**.

Two or more other windows holding the name is **ambiguous**: the command
fails (exit 1) naming the windows and pointing at the pane id, rather than
pick one — picking would act on another agent's pane at random. A caller with
no pane (a plain shell, a `ghoztty://` link) starts at step 2. A pane id is
always exact and needs none of this. An explicit `--target=<window>` /
`--pane=<id>` still reaches across windows.

This applies to `+split --name`/`--pane`/`--target`, `+close`, `+send-keys`,
`+read`, `+set-banner`, `+set-state`, `+reload`, `+stash`, `+restore`,
`+rename` and `+rearrange` (whose layout names panes of the window it
rearranges). `caller_pane` is a field rather than an argument because it must
be additive both ways: an older app's decoder ignores an unknown field, where
an extra argument would have become text in its `+set-banner`. The server
folds it into the arguments as `--caller-pane=` (in front of any `-e`), the
one spelling every handler reads (`IPCRequest.resolvedArguments`). A name
follows its pane when the pane moves to another window. Tests:
`TargetLookupTests`, `PaneNameScopeWindowTests` (two real windows: split,
close and send-keys from each). **Windows (T2250):** the CLI sends
`caller_pane` on every request (`ipc_client.buildRequest`, T2249), and the
win32 server scopes by it at dispatch rather than folding it into the
arguments: `IpcHandlers.dispatch` resolves the caller pane's window into
`App.ipc_caller_window` for the request's lifetime, and every `ipcLookup`
starts there (`IpcRegistry.lookup`, policy `apprt.ipc.target_lookup`, the
Mac's wording). A not-found reply becomes the ambiguity error when that is
the reason (`missingResponse`), and `+close` of an ambiguous name fails
instead of "succeeding" idempotently. Acceptance: arms J and L-P of
`test/win32/split-name-collision.ps1`.

A window opened without an explicit `--target=` (Cmd-N, or a bare
`+new-window`) still gets an **auto name** — `window-1`, `window-2`, … — which
is exported to its panes as `$GHOZTTY_WINDOW_NAME` and shown as `target` in
`+list`. That name is targetable immediately: `resolveTarget` falls back to
scanning live windows by name, so no `+list` is needed first. (It used to be
registry-only, so every `--target=window-N` failed with `not found in
registry` until something walked the tree — invisibly, for the many callers
that discard stderr.)

`$GHOZTTY_WINDOW_NAME` is baked at spawn, like every env var, and a session
restore bakes it too: the restored window's name is settled **before** its
panes are built, so an agent restart (reboot) RELAUNCHes each shell with it
(`AppDelegate.sessionLayoutLeafConfig`; it used to come back with
`GHOZTTY_PANE_ID` only). The name is the persisted target when it is still
free, else a fresh `window-N` — never a name another window holds, which
`+close --target=$GHOZTTY_WINDOW_NAME` would then close
(`AppDelegate.restoredWindowName`; tests: `SessionLayoutRestoreTests`). A
target name never changes after creation (`+rename` changes the title, not
the target), but a process keeps the value it was spawned with, so a pane
whose window could not re-adopt its name on restore holds a stale one. **The
authoritative lookup is `+list --json`, keyed by `$GHOZTTY_PANE_ID`**; the
env var is the cheap, usually-right shortcut. **Windows:** restored panes get
`GHOZTTY_WINDOW_NAME` too (T1883).

### Pane identity

Every pane has a **stable, ghoztty-owned pane id** (a UUID):

- Exported to the pane's processes as `$GHOZTTY_PANE_ID` (baked at spawn).
- Shown as the leaf `id` in `+list --json`.
- Accepted directly by every `--target`/`--name` (case-insensitive), with no
  prior registration or `+list` needed: `ghoztty +set-banner
  --target=$GHOZTTY_PANE_ID …` works from inside any local pane.
- Stable for the pane's whole life: persisted in the session-layout manifest and
  restored on app relaunch (session-persistence panes keep the same id AND the
  same baked env; a **viewer** pane keeps its id across the same restore too,
  having no shell env to bake), preserved across remote reconnect swaps, and re-applied to
  the respawned shell when the agent relaunches a session after its own restart
  (the RELAUNCH carries the pane's env/TERM/argv).

Prefer the pane id over pid/tty matching for self-identification: pids and ttys
belong to the machine the process runs on and are meaningless for remote panes.
(`+list --tty=<tty>` still works for local panes as a fallback.)

### Caller anchoring

A command that needs a pane or window and was given none anchors at **the pane
it was invoked from**, not at whatever window happens to be focused. The CLI
forwards `$GHOZTTY_PANE_ID` as `--caller-pane=<id>`; the app prefers it over its
own focused-window fallback.

This is the same shape as Instance addressability below (the CLI reads a baked
env var; one resolution site each side) and exists for the same reason: the
default used to be read on the app's side **at handle time**, so the answer was
whichever window was key by then. An agent in pane A asking for a viewer side
pane, plus a user clicking window B in the meantime, put the pane in B. The race
does not need a user, either — an agent's command is asynchronous with respect
to focus.

- **Name lookup is a different use of the same pane** (see Naming): every
  command sends it as the request's `caller_pane` field, explicit anchors or
  not, and a name is looked up in that pane's window first. Anchoring is only
  for commands that need somewhere to put a pane.
- **Applies to `+split` and `+rearrange`.** Both took the focused-window
  fallback. `+new-window` creates a window and needs no anchor, and
  `--from-focused` (on `+split` and `+new-window`) is the caller asking for the
  focused window BY NAME, so neither changed.
- **Anything explicit wins**: `--target`, `--pane`, `--from-focused`.
- **Absent or empty ⇒ the old behavior**, so a CLI run from a plain non-Ghoztty
  shell, or from a pane baked by an older app/agent, is unchanged.
- **A pane id that no longer resolves falls back rather than failing** — a
  script outliving its own pane is ordinary. That is why the wire flag is
  `--caller-pane=` and not `--pane=`: an explicit `--pane=` naming nothing is a
  typo and stays a hard error.
- One resolution site on the CLI side for both platforms:
  `apprt.ipc.seedCallerPane()` (`src/apprt/ipc.zig`), which inserts the flag
  ahead of anything from `-e` on. One on each server side too:
  `IPCServer.callerAnchorPane` (Swift) on macOS, and
  `apprt.ipc.args.callerAnchorPane` — the pure precedence rule, unit tested in
  both zig lanes — behind `IpcHandlers.callerAnchorPaneView` on Windows (T1079).
  Acceptance: `test/win32/caller-anchor.ps1`, which drives two windows and asks
  where each split went.

### Instance addressability

An IPC command run inside a pane targets **the app instance that owns that
pane**, not whichever build the `ghoztty` binary on `$PATH` happens to be. Every
pane's env is baked with `$GHOZTTY_IPC_SOCKET` — the absolute path of its own
app's IPC socket — and the CLI prefers it over the compile-time
`ghostty[-debug]-<uid>.sock` derivation. So `ghoztty +split` run from a
debug-build pane splits the **debug** window even though `ghoztty` on `$PATH` is
the release binary (before this, it silently drove the release app).

- Baked on every pane path: plain local spawn, session-persistence agent panes
  (the agent replays the pane env on RELAUNCH), and remote panes — a remote
  pane's IPC still belongs to the *local* app.
- Absent or empty ⇒ today's derivation, so a CLI run from a plain non-Ghoztty
  shell is unchanged, as is a pane baked by an older app or agent.
- Override it (`GHOZTTY_IPC_SOCKET=<path> ghoztty +list`) to aim a single
  command at a specific instance.
- One resolution site each side: `apprt.ipc.socketPath()` (`src/apprt/ipc.zig`)
  for the CLI, `IPCSocket.path` (Swift) for the server.
- **Windows uses the same var for a pipe name** (T118): the value is
  `\\.\pipe\ghoztty[-debug]-<user>`, not a socket path, and the name was kept
  identical rather than adding a sibling — the var is baked into long-lived
  panes that outlive the app, and neither side ever parses the value. The CLI
  resolves it in `ipc_client.clientEndpointPath()`
  (`src/os/ipc_client.zig`), which `apprt.ipc.socketPath()` delegates to there.
- **An explicit `GHOZTTY_PIPE_SUFFIX` outranks the baked value** on Windows.
  The suffix is how a harness aims at the instance it just launched, and a
  script inherits the environment of the pane it was started from — without
  this rule every `test\win32\*.ps1` run from one of the user's panes would
  drive the user's terminal. Precedence: suffix → baked → derivation.
- **Only clients read it.** The IPC *server* binds `ipc_client.endpointPath()`,
  the pure derivation, and the win32 App drops any inherited
  `$GHOZTTY_IPC_SOCKET` from its own environment at startup — otherwise a dev
  build launched from a pane of the installed release would try to bind (or
  forward its startup `new-window` to) that release instance's endpoint.
  Acceptance: `test/win32/ipc-instance-addressability.ps1`.

### Starting Ghoztty when Ghoztty is already running

**A second launch does not become a second app.** It loses the race for the IPC
endpoint (`FILE_FLAG_FIRST_PIPE_INSTANCE`; `IpcServer.init` answers
`AlreadyRunning`), forwards a `new-window` to the winner and exits — one app,
one tray icon, one session list, a new window. That is the Mac app-bundle
behavior and Windows Terminal's, and the user chose it in D79 over two copies
quietly sharing one agent and one saved layout.

- **The launch's own arguments ride along** (T487): the working directory and
  `-e`/`--command` are re-emitted as `+new-window` flags
  (`App.forwardedNewWindowArgs`), so `ghoztty -e pwsh` typed in a project
  directory opens *that* command in *that* directory rather than a bare shell
  wherever the running app happens to sit. The handoff happens in `App.init`
  before any window, tray icon or agent connection exists, so nothing of the
  second app is ever half-created.
- **The instance identity is the endpoint, which is keyed on the build
  LINEAGE** — the `-debug` suffix, or an explicit `GHOZTTY_PIPE_SUFFIX`. A
  debug `zig-out` build and the installed release therefore never join each
  other, which is what keeps side-by-side development (and every acceptance
  script) working.
- **Two copies of ONE lineage do join**, because they already share that
  endpoint, the agent and the saved layout. The installed release and the
  Desktop portable copy are exactly that pair — so a shortcut pointing at one
  can hand you a window belonging to the other, which D79 named as its one con.
- **A build mismatch is therefore not silent** (T1022). The launch carries its
  own `{version, commit, exe}` across the handoff as an additive `handoff`
  object on the request (`ipc_client.buildRequestWithHandoff`); when it differs
  from the running instance's, the reply carries a `note` (the CLI prints it to
  stderr) and the app shows a desktop balloon naming the copy that actually
  owns the window. Same build ⇒ nothing is said: the two copies are the same
  bits and the join is invisible on purpose. Text and comparison:
  `src/os/ipc_handoff.zig`. Acceptance:
  `test/win32/single-instance-join.ps1`.

### Every verb answers or explains — it never just waits

**No CLI verb blocks indefinitely on the app** (T755). The bound is 30s per
exchange, with a "still waiting" line on stderr at 5s, and `GHOZTTY_IPC_TIMEOUT_MS`
overrides it (`0` waits forever, for a caller who genuinely wants that — a
debugger attached to a stopped app). The timeout message names the verb, which
half of the exchange was waiting, and the env var: *"Timed out after 30.0s
trying to get a response from Ghoztty for '+list'."*

It is a structural hazard, not a rare one. The server reads a request on a
listener thread and marshals it to the GUI thread with no timeout of its own,
and from the client side a GUI thread that is busy — a cold start, a session
restore — is indistinguishable from one that is wedged. On 2026-08-11 a
`+list` fired during `ipc-p1.ps1`'s cold auto-launch was still blocked **34
minutes later** with 0.06s of CPU, against an app that was alive and rendering.
There was no way out because a synchronous `ReadFile` on a named pipe cannot be
interrupted: no output, no error, no exit code, and a caller capturing that
child's stdout hung with it. So the client's pipe is opened
`FILE_FLAG_OVERLAPPED` and every read carries an OVERLAPPED that can be
cancelled; posix gets the same bound from `SO_RCVTIMEO`/`SO_SNDTIMEO`, so the
Mac CLI is bounded by the same policy without a second implementation of it.

Two things that look like details and are not:

- **The bound and the handle are separate facts.** `Conn.owned` says this
  process opened the handle (and may therefore bound it); `Conn.timeout_ms`
  says how long. Folding them into one field made `GHOZTTY_IPC_TIMEOUT_MS=0`
  hand an overlapped handle to a synchronous `ReadFile` — documented as
  unpredictable, and measured here as a read that neither completed nor timed
  out. The win32 IPC **server** wraps each accepted pipe instance in a `Conn`
  it did not open, which is exactly what the `owned: false` default protects.
- **A typo must not reinstate the hang.** An unparseable
  `GHOZTTY_IPC_TIMEOUT_MS` falls back to the 30s default, never to forever;
  only a literal `0` opts out.

The auto-launch wait `+new-window` performs is a different question and has its
own budget (`ipc_timeout.auto_launch_ms`, 30s): there the peer is a process we
just started, and its cold start includes the loader, Defender scanning a
freshly built binary, config parsing and a session restore. The old budget —
20 fixed attempts of 500ms — was reached in the wild, costing `ipc-p1.ps1`'s
first section three assertions on one cold run that passed clean on the re-run,
which reads as a regression and is not one. Waiting nearly three times as long
is only safe because the wait now WATCHES the process it launched: an instance
that dies during startup ends the wait immediately rather than burning the
budget on a peer that is never coming.

Policy (numbers, env parsing, wording) is pure and asserted in the `none` lane:
`src/os/ipc_timeout.zig`. Acceptance: `test/win32/ipc-timeout.ps1`, driven by
`ipc-fake-server.ps1 -Wedge` — a peer that accepts, reads the request and
answers nothing, so nothing there depends on timing luck — with a replying
server as the control and the harness itself capped, so a regression of the
bound fails the script instead of hanging it.

### Example: three-pane layout

```bash
ghoztty +new-window --target=ide --command="nvim ."
ghoztty +split --target=ide --name=term --direction=down --command=zsh
ghoztty +split --target=ide --name=logs --direction=right --command="tail -f app.log"
# read output from a pane
ghoztty +read --name=logs --lines=5
# teardown
ghoztty +close --target=logs
ghoztty +close --target=term
ghoztty +close --target=ide
```

## The `ghoztty://` URL scheme

A **link** can raise a Ghoztty window or pane. This is the piece that makes a
generated document (a worktree dashboard, a status report) able to say "jump to
that terminal" — from a browser, from a doc rendered in a viewer pane, or from
a pane banner.

```
ghoztty://focus/<target>
```

One verb, one shape. `<target>` is percent-decoded and passed to the same
target resolver `--target` uses, so there is one naming system, not two: a
registered window name, an auto `window-N`, a registered pane name, or a pane
id (`$GHOZTTY_PANE_ID`, case-insensitive). On macOS (`IPCServer.lookup`) a
link has no caller pane, so a pane name is looked up across every window (see
Naming): once two windows each hold a pane of that name the link is
**ambiguous** and reports so (`Failure.ambiguousTarget`, "Can't focus …")
instead of raising one of them at random. A pane id never is. Windows
(T2250): the in-app link path reports it the same way
(`url_scheme.Failure.ambiguous_target`); a cold click from outside goes
through `+focus`, whose refusal reads as not found.
Everything after the verb is ONE target, so a name containing `/` survives encoded (`focus/feat%2Flogin`) or not
(`focus/feat/login`). The path form is canonical over `ghoztty://<target>`
(nowhere to put a verb) and over `ghoztty://focus?target=…` (a second escaping
context for no gain). Parsing is strict: unknown verb, empty target, and bare
`ghoztty://<name>` all yield nothing rather than a lenient guess. **There is no
`+focus` CLI verb on either platform** — the scheme is a link surface, and a
verb that existed on one CLI and not the other is the divergence this project
does not ship.

**Focus is the only capability, and that is the design, not a first
increment.** A registered URL scheme is reachable by any web page the user
visits — no prompt, no gesture beyond a click, no same-origin check, no way to
know who asked. Everything the IPC endpoint exposes is safe there only because
a 0600 unix socket (an owner-only-DACL named pipe on Windows) is reachable only
by code already running as the user; none of that holds for a link. A scheme
that could spawn a shell (`--command`), type into a pane (`+send-keys`), or open
a viewer would be remote code execution behind an `<a href>`. Raising an
already-existing window is the one verb whose worst case is a nuisance. The
parser reads a verb rather than hardcoding one shape so a future verb *could* be
added — but wanting a second verb to make something work is a signal to stop and
ask, not to add one.

Consequences, all deliberate and the same on both platforms:

- **The debug build registers `ghoztty-debug://`**, the release builds
  `ghoztty://` — the same split as the IPC endpoint (and, on macOS, the bundle
  id). Otherwise the shell picks between them and the user's links start landing
  in a debug build. macOS declares it in `CFBundleURLTypes` (the
  `GHOSTTY_URL_SCHEME` build setting); Windows has no `Info.plist`, so the app
  writes its own per-user handler at launch —
  `HKCU\Software\Classes\<scheme>` with the `URL Protocol` marker and
  `shell\open\command` = `"<this exe>" "%1"`, off the GUI thread, idempotent and
  rewritten every launch so an upgrade or a move re-points it. `HKCU`, never
  `HKLM`: Ghoztty installs per user and a machine-wide association would need
  elevation. `GHOZTTY_URL_SCHEME=0`/`off` skips registration.
- **On Windows the release scheme is also gated by LOCATION** (T1124): a build
  whose exe sits inside a source checkout — any ancestor directory holding
  `build.zig` — registers nothing. The build-mode split alone was not enough,
  because the staging release we package deliveries from lives at
  `zig-out-release\bin` *in the checkout*: it is a release build, so one launch
  of it pointed the user's `ghoztty://` links at a scratch directory that
  ordinary development rebuilds and deletes. The installed release and a
  portable unpack are both outside a checkout and are unaffected.
  `GHOZTTY_URL_SCHEME=force` skips the gate; `=gate` applies it to a debug build
  too, which is how `test\win32\url-scheme.ps1` measures it.
- **Both spellings parse in both builds.** Links clicked *inside* Ghoztty are
  short-circuited in process and never reach the shell, so a document that
  hardcodes `ghoztty://` still focuses the right pane when a debug build is
  rendering it.
- **A link that resolves to nothing says so** (`url_scheme.Failure`): a warning
  naming the target for `target_not_found`, or naming the URL plus the one
  supported form for `unsupported_link`. A click that appears to do nothing is
  indistinguishable from a broken app, and both failures are ordinary (the
  window was closed; the document predates this build). What failure never does
  is *act*: no window is created and no "closest" window is focused as a
  consolation. Presentation is **coalesced** so a burst — any page can fire a
  scheme — is one dialog, not one per link: macOS behind an
  `isPresentingFailure` flag (`application(_:open:)` takes a whole array),
  Windows behind a named mutex as well, because there every click is its own
  short-lived process and a flag cannot see the burst. A URL that isn't ours at
  all is ignored silently; nobody clicked a Ghoztty link. The wording lives on
  `Failure` rather than in the presenter so it is testable.
- **App not running:** the honest answer is the same as any other miss —
  nothing is open by that name — because a focus link must never create a
  window as a side effect. macOS cannot decline the launch LaunchServices does,
  so the app comes up with its normal `initial-window` behavior (that belongs to
  *launching Ghoztty*, exactly as `open -a` does, not to the focus verb) and the
  link reports not-found. On Windows the activation process reports it and
  exits without starting a terminal at all.
- **Viewer panes** intercept `ghoztty://` ahead of the live-page passthrough
  (the engine cannot load the scheme, so an allowed navigation is a dead click,
  and handing it to the shell would route it to whichever BUILD registered the
  scheme). A `target="_blank"` focus link resolves to a *command* destination
  instead of falling through "non-web scheme ⇒ open a Ghoztty window", which is
  how it used to create a viewer window pointed at the command string.
- **Rendered markdown** needs `viewer.js` to widen DOMPurify's
  `ALLOWED_URI_REGEXP` by exactly these two schemes. markdown-it keeps a
  `ghoztty://` href, and the sanitizer then stripped it — the link rendered as
  dead text. Keep the regex in sync when the vendored DOMPurify is bumped.
- **Banner links** ignore the Cmd / Ctrl modifier scheme: the link names a
  window, not content, so there is nothing to open in a side pane or a new
  window. The right-click menu is **Focus in Ghoztty** + **Copy Link**.

The grammar and the failure wording are ONE definition per platform —
`src/apprt/ipc/url_scheme.zig` on Windows, `GhozttyURLScheme.swift` on macOS —
so the launcher, the viewer and the banner cannot disagree about what a link
means. Windows entry points: `main_ghostty.zig` (an activation is answered
before the single-instance bind, or it would forward a `new-window` and open a
terminal), `ViewerPane` for viewer link clicks and popups, `BannerOverlay` for
banner clicks; all funnel into `apprt/win32/url_scheme.zig` →
`IpcHandlers.focusTarget` (the external path through the internal `focus` IPC
action). Acceptance: `test/win32/url-scheme.ps1`.

## Links in terminal output

Text a program prints into a pane becomes clickable — ctrl-hover (⌘ on macOS)
underlines it, ctrl-click opens it — by matching one regex against the hovered
LINE. That regex is shared core, `src/config/url.zig`, wired in as the default
`link` in `Config.default`, and it is the same string on both platforms.

**Windows paths are part of it** (T757). Before that the regex had three
branches and every one of them was POSIX-only: all three path branches were
built from a `path_chars` class with **no backslash**, and none knew a drive
letter, so `D:\Users\me\clip.mp4` printed by any tool could not match anything
and stayed dead text — on the surface a Windows user looks at all day, and for
most of what a path in a terminal is *for*. Branch 4 adds a drive prefix
(`D:\…`, `D:/…`, either case) and a UNC share (`\\server\share\…`), and reuses
the POSIX branch's own dotted/undotted split so `C:\Program Files\app.exe`
matches whole while `D:\a\b C:\c\d` stays two paths. `foo\bar.md` with no
sigil stays text, exactly as it does in a pane banner (T539, whose sigil set
this follows).

Two consequences worth knowing:

- **The branch is live on EVERY platform**, not comptime-gated on Windows. A
  `D:\…` string means nothing on macOS so it costs that seat nothing, a Mac
  window attached to a Windows agent shows Windows paths in its panes, and a
  shared core that quietly matches different text per platform is the kind of
  divergence that rots. `test "url regex"` therefore runs the Windows cases on
  both seats.
- **A single letter and a colon is never a URI scheme**, which is what keeps
  the `s:/` inside `https://` from reading as a drive — the same call
  `banner_link.kindOf` makes on the banner side. It is a lookbehind, not a
  scheme list, so it also protects every scheme nobody has added yet.

**What a click DOES is open, not reveal** — and that is deliberate, not an
oversight of the banner rule. A banner link only ever *reveals* a file
(T165), because a banner is chrome; the TERMINAL's link click opens with the
default application, on macOS (`NSWorkspace.shared.open`) as on Windows
(`App.openUrl` → `ShellExecuteW("open")`). Making Windows reveal instead
would be the divergence, not the parity.

Acceptance: `test/win32/terminal-link-paths.ps1`, whose oracle is a
**ctrl+right-click** — a right-press selects the link the terminal found
(else the plain word) before showing the context menu, so the selection is
the terminal's own answer, readable through ctrl+c, and nothing is launched.
Column 0 is what makes it unambiguous: `:` is a word boundary and `\` `/` `.`
are not, so the `Q` of `Q:\Users\…` selects as the whole path when the link
is found and as the lone character `Q` when it is not. The double-click
gesture is NOT the oracle: it reaches link detection with no modifier at all
and finds the link, and then the selection is replaced by a plain word-select
before anything can read it — filed as **T802**.

## Copy cleanup (TUI reflow)

Imported from main's CLAUDE.md at the T1796 merge (main d886ba4b5). The
shared core carries it on both platforms; the Windows copy path is T1799.

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

## Pane sidebar

A per-window list of **every pane in the window**, into which a pane can be
**stashed**: out of the split grid, still running. Design:
`docs/design/pane-sidebar.md` (it records the alternatives and the choices
the interactive mock settled).

- Two modes, **collapsed ⇄ expanded**, switched by ONE button at the top of
  the bar (`setPaneSidebarExpanded`). Both are ONE raised glass card, in the
  same margins (the grid's gutters), with the same top and height —
  **collapsed** at the 44pt rail's width (one-letter tiles), **expanded** at
  the panel's width (full rows) — and every row is one height
  (`PaneSidebarRow.height`), so a pane's icon sits at the same height in both
  (`iconsStayAtTheSameHeightExpandedOrCollapsed`). (Expanded used to be a flat
  edge-to-edge panel, its rows a different height.) **No pin, no hover-open**: hovering the rail
  opens nothing, because the rail is where its tiles are dragged.
  **Collapse/expand glides**: the grid's cards glide over to their new places
  (`PaneStackState.noteColumnShift` → `PaneStageView.apply` seeds the glide
  from where they were on screen), each terminal held at its size and resized
  once after the motion, while the sidebar's width animates on the same curve
  and rail and panel crossfade (`PaneSidebarState.columnAnimation`). It used to
  snap. **The edge grip is the gutter beside the sidebar in both modes**
  (`PaneSidebarState.edgeGrip`: the grid's margin, elevated; the rail card's
  own margin, flat) — never over the rail, where its bar used to sit on the
  tiles. Dragging it resizes the panel; pulling the rail's gutter past the
  panel's minimum (180) brings the panel out at that width, and pushing the
  panel well under it (< 120) tucks it back into the rail, both ways within one
  drag (`PaneSidebarState.edgeDrag`; between the two it stops at its minimum).
  **The sidebar is a row's first item in a divider drag**: in a row spanning
  the grid, a gutter pushed left past every pane it has tucked away tucks the
  expanded sidebar into its rail as a pane tucks at its minimum
  (`BaseTerminalController.sidebarAwareRow`, after `dividerTuckGive` —
  24–80pt), and dragged back in the same drag brings it out; tucked, the row
  measures the room it gained. Every mode change is logged at `.notice` with
  its cause (category `PaneSidebar`) — it must never change on its own.
  Only collapse/expand and hide/show change the column, so nothing else
  resizes a terminal. A window narrower than 720pt shows the rail even when
  expanded (its expand button is off). **Ctrl+Cmd+S** hides/shows the sidebar
  entirely. **Windows:** T2274 (one rail, one button, the glide, the
  unfocused-pane card), T2277 (a divider drag tucks the sidebar).
- A row (and a rail tile) names its pane the way a stacked strip
  does: the **banner's title** when it has one, else the pane's title
  (`PaneView.displayLabel`; see Stacked panes). The subtitle is then the
  working directory — a titled banner's first line IS the title, so showing
  it again said nothing — and the banner's first line only when the banner
  has no title. The all-windows search still matches the pane's own title.
  The all-windows **window** names are not affected: they group by window
  title (`<project>: <worktree>`), which a pane banner has no say in.
  **Windows:** T2085.
  **A rail tile is its row with the text taken away**: the same pill (hover
  wash, the accent selection), the same kind glyph at the same place — the
  rail card is exactly that pill (`railCardWidth` = 52) — so collapsing or
  expanding moves no icon, either way. The glyph is in the pane's own hue
  (`PaneSidebarHue`: golden-ratio steps along its tree position; light and
  soft on a dark theme, deeper on a light one, for contrast), a touch quieter
  unless its pane is focused or hovered. **Hovering a row or tile tints its
  pane in that hue** — a wash and a rim on the pane's card
  (`PaneSidebarHover`, `PaneSidebarHoverTint`: 10% wash, 45% rim), in over
  0.12s, out over 0.2s — so the sidebar says which pane an icon is. (Earlier
  takes — one letter per tile, then glass tiles tinted whole — made the two
  modes look like two different things.) **Windows:** T2279 (landed: rail = rows
  minus text), T2278 (hues, hover tint).
- Rows: grid panes (focused one selected), then — **right after the last of
  them**, under a divider, in the same scrolling list — the **tray** of
  stashed panes. (It was first anchored at the bottom of the bar, far from the
  panes it is for.) A drag slides the list, the tray's header and the tray as
  one sequence, so a row crossing into the tray moves the divider with it
  (`PaneSidebarView.slideIndices`). An empty tray is still a visible target: a faint
  dashed well with a tray glyph ("Drag a pane here to stash it" when
  expanded), lit in the accent while a drag would land in it. Click focuses /
  restores to the exact slot it
  left; **Option-click** swaps a stashed pane with the focused one. Hover
  offers only stash (−) / restore (↩).
- **Drag to reorder, in both modes.** A drag over the sidebar resolves to one
  of two lists, split at the tray's divider (`PaneDropCandidate.Sidebar.trayTop`):
  above it `PaneDropTarget.sidebarOrder` — a grid pane moves in the LIST ONLY
  (the grid never changes), a stashed pane is restored into it, another
  window's pane joins this window there; below it `.stash`. Any pane — a row,
  a tile, a grid pane's grab handle — goes into the tray to stash and out to
  restore; a row into the grid places it as before. ONE resolver, ONE drag
  (`PaneDragSession`), no parallel drop path. **A row dragged in the list
  only ever rearranges** (`PaneDragSession.isListDrag`): the pointer is held
  to its own sidebar before resolving, so letting go beside the bar, over the
  grid or past the window, is the place in the list (or tray) level with the
  pointer — it used to resolve as a grid move, or `.newWindow`, which took
  the pane out of the window. A pane's grab handle still drops anywhere.
  **The row itself follows the
  pointer — up and down only, never sideways, kept inside the bar** — not a
  drag image (`PaneSidebarRowDrag`: the row's drag source draws no preview and
  feeds the pointer's travel; `PaneSidebarView.ghost` draws the row there,
  lifted, over a solid backing). Let go, it glides to where it landed. The
  others **slide by its height** to make room (`PaneSidebarOrder.shift`, a
  bounded 0.2s animation, none at the drop). The index is read off the rows
  as LAID OUT: each row's frame is measured by a background attached OUTSIDE
  its slide offset (`rowFrameReader`) — a reader inside an `.offset` moves
  with it, and the index then chased the sliding rows (a row slid into the
  gap reported the gap's place). The order is per window (`PaneSidebarState.order`,
  reconciled by `PaneSidebarOrder.arranged`): a new pane goes after its tree
  neighbour (a split lands beside its parent), a stashed pane keeps its place
  for when it comes back, closed panes are pruned, and empty means tree
  order. Tests: `PaneSidebarOrderTests`, `PaneDropResolverSidebarTests`,
  `dragReordersTheListAndTheTrayStashesAndRestores` (both modes). Hovering an
  expanded row offers −/↩ (stash/restore) and **×** (another window's row:
  × only), and a hovered window or project header puts × where its count was,
  in the same column. **Every close from the sidebar asks nothing, takes no
  focus and ends what it closes** (Mac 345be6b02, `closePaneFromSidebar`,
  `closeWindowsFromSidebar`; right-click → Close Pane too): no running-process
  confirmation, no remote Disconnect offer, no window raised, sessions
  CLOSE-on-free - undoable for the usual undo window. **There is no trash
  mode** any more.
  The **collapse/expand button is the header's first item**, centered on the
  rail's width (`PaneSidebarView.toggleLeading`), so it does not move when
  toggled. **Windows:** T2275 (order), T2276 (tray), T2280 + T2298 (landed:
  every row's × and the right-click Close Pane are `Window.paneSidebarCloseNow`
  - unconfirmed, undoable, never raising another window, and a pane that is not
  the focused one closes without moving the caret; a header's × is
  `App.closeTabsQuietly`, run on the next loop turn as one undo group, so a
  window closes itself from its own sidebar. `test\win32\pane-sidebar-close.ps1`).
- Activity: a **busy** pane's row — or tile — sheens, in two layers both
  slanted 45° ("/") and moving right to left: a faint band of light (25%)
  sweeps across its pill every 2s, starting and ending fully off it, top
  corner included, over a slow seamless drift (one period every 5s, 2–8%
  white on dark, 1.5–5% black on light) inside a 0.5pt hairline rim
  (`PaneSidebarTileSheenLayer`, Core Animation; geometry in
  `PaneSidebarSheen`). A **rail tile** (never a full row) also has a glassy
  rim lit from above (`PaneSidebarRow.tileBorder`), fading with the rail on
  expand/collapse. No spinner, no glow, no glyph shimmer. **Busy is `PaneView.isWorking`**: the hook-set activity
  state OR a progress report on screen (OSC 9;4 — what animates the pane's
  border, `SurfaceBusyBorder`), so an icon animates whenever its pane's border
  does (it read only the activity state, and the two disagreed). **The sidebar
  shows no question state** — no badge on a row, a tile or a window header:
  it did not work reliably, and was removed. Both animations run on **Core
  Animation**, never an endless SwiftUI animation, which
  re-renders the whole sidebar every frame (measured: ~90% of the main thread
  at rest with 40 windows; `PaneSidebarAnimationLayers.swift`). **Windows:**
  T2279 (landed: tiles are the rows minus their text on a 52 DIP rail card,
  kind glyphs, the right-to-left pill sheen with its 0.6s fade on a window
  timer - `pane_sidebar_motion.zig` - and busy includes a live OSC 9;4
  report, `PaneSidebar.isWorking`), T2280 (landed: no question state -
  no row chip, tile disc, header badge or breathing ring), T2309 (landed:
  the slant, the drift and its rim, and the tiles' glassy rim -
  `pane_sidebar_motion.Overlay`, painted by `PaneSidebar.paintOverlay`; a
  Windows selection is neutral, so Mac's on-accent rim has no counterpart).
- **All-windows** header toggle (off by default) groups every window's panes.
  Its caption counts the windows. Every window starts **folded** except this
  one (search unfolds all; `PaneSidebarState.isWindowFolded`). **Windows:**
  T1924.
  Windows are **sorted by name** (Finder order; stable as focus moves), and a
  window titled **`<project>: <worktree>`** is grouped under a collapsible,
  **sticky** project header and labeled by its worktree alone
  (`PaneSidebarWindowGrouping`, `PaneSidebarWindowGroupingTests`). Other
  windows sort among the projects at the top level. All windows also brings a **search
  field**: whitespace-separated terms, all of which must appear in a pane's
  window title, title, banner, or directory/location (`PaneSidebarFilter`);
  Return goes to the first hit, Escape clears. Switching scopes slides the
  lists past each other (this window on the left, all windows on the right).
- **A stashed pane never leaves the tree** — `SplitTree.stashed` sits beside
  `zoomed`; the grid renders `visibleTree` and spatial ops lift their ratios
  back. That is what keeps stashing from marking a session CLOSE-on-free
  (`PaneStashSessionSafetyTests`) and keeps every tree walker (IPC, close
  confirmation, the manifest) seeing the pane.
- **A stashed pane keeps its geometry**: it stays mounted, invisible, behind the
  grid, in the slot it would occupy (`StashedPaneSlots`), so it is never sized
  to the 800×600 placeholder (49×17) — even when stashed at launch — and
  restoring it is not a reflow. Tested in `PaneSidebarWindowTests`.
- Persisted: the stash (manifest per-leaf `stashIndex`; `SplitTree` coding for
  AppKit restoration), the expanded/hidden flags and the list's order
  (`paneSidebarOrder`, by pane id). The expanded flag is stored under its
  pre-rename name `paneSidebarPinned` (UserDefaults: `PaneSidebarExpanded`,
  falling back to `PaneSidebarPinned`) — pinned WAS the full panel, so old
  state decodes as expanded/collapsed unchanged. The all-windows scope is
  never persisted.
- Keybinds (macOS defaults): `toggle_pane_sidebar` Ctrl+Cmd+S, `stash_pane`
  Shift+Cmd+M, `restore_stashed_pane` (unbound); Window menu items for all three.

## Pane style (`macos-pane-style`)

`elevated` (the default) presents a window's panes as slightly raised
rounded cards (11pt radius, a soft two-layer shadow, a hairline rim) on a soft
blue-to-teal **ocean** gradient. ONE spacing, 10pt, is every gutter: pane to
pane (the gaps are still the dividers), pane to window edge, and around the
rail (which takes no trailing margin of its own — the grid's is that gap).
**A window opened by hand (Cmd-N, the New Window menu item / palette
command) gets a random gradient by default**, exactly as
**`+new-window --color=random`** does — in this style that gives the window its OWN
gradient (`PaneDeskVariant`: a persisted seed; ONE random hue from the whole
wheel — the tones `--color=random` always drew from — with a soft spotlight
from the top center, getting darker toward the bottom-trailing corner on a
dark theme and lighter on a light one, where a dim pool of the
**complementary** hue subtly lights that corner) and leaves the terminals their theme
color; an explicit `--color=#hex`, `random` on a split, and `random` in the
`flat` style still tint the terminal background as before. `flat` is the classic
edge-to-edge look with a 1px `split-divider-color` line, drawn down the middle
of a 6pt gutter (`PaneLayout.Metrics.flatGap`) — a real gutter, because the
gutters are where the resize grips live (see Stacked panes → Resizers live in
the gutters) — and its panes stack like any other. Geometry and palette live once in
`PaneElevation`/`PaneDesk`/`PaneCard` (`Features/Splits/PaneElevation.swift`),
which the grid AND the hidden stashed-pane slots both use — the slots must lay
out exactly like the grid or a restored pane would reflow. The expanded pane
sidebar goes translucent so the gradient runs under it.
**Windows** (T1831) reads the same `macos-pane-style` key with the same default
and geometry (10 DIP margin and gap, 11 DIP corners, the ocean desk). The
parent window paints the desk, the shadows and each card's antialiased fill and
rim (`pane_elevation.zig` / `PaneDesk.zig`); each pane's child window sits one
rim width inside its card, clipped to a rounded window region. The Quick
Terminal stays flat. Random per-window desks landed too (T1832,
`desk_palette.zig`): Ctrl+Shift+N, the New Window menu item and palette
command, and `+new-window --color=random` give the window its own gradient,
derived from Mac's seed with Mac's generator draw for draw - so one seed is one
gradient on both platforms - and persisted as `desk_variant` in the session
layout (a Mac blob's `deskVariant.seed` is read across). The machine chooser's
Local row, like Mac's, opens a plain ocean window. Not yet on Windows: the
sidebar over the desk (T1850), card-shaped header/banner bands (T1851),
translucent windows (T1852), glass (T1833), the focus glow (T1834).
**Glass panes** (`macos-pane-glass`, default `true`, elevated only): each pane
is a translucent sheet tinted 40% with the terminal's own background (Liquid
Glass on macOS 26, a plain tint before — `PaneGlass`), so the gradient's light
and shade read through every pane. The renderer stops drawing the terminal's
background (`generic.zig` `pane_glass`, the same switch the `macos-glass-*`
blur styles use), the banner strip skips its base fill and the **banner card is
a pane of glass of its own, layered on top** — the pane's sheet thins out
under the card (`PaneGlass.bannerTint`, 25% against the pane's 40%; the card publishes its frame up to `PaneCard` as
`PaneBannerCardKey`), and the card itself is rim and drop shadow only, no white
wash and no sheen (`SurfacePaneBanner.isGlass`): a white lift over glass greyed
the gradient into a flat slab ~17 levels lighter than the pane, and a second
Liquid Glass sheet over the pane's greys it further
(`bannerOnGlassLetsTheGradientThrough`; `flat` and elevated-without-glass keep the wash;
**Windows:** T2255 - `BannerOverlay` lays the band's sheet and, under the card,
the same sheet at `pane_elevation.Sheet.underBanner`, and `banner_card.renderGlassOn`
adds only the rim and the shadow), viewer template pages
(markdown/code/diff/image) go see-through (`ViewerView.isOnGlass`, a
`pane-glass` class in `viewer.css`) while websites and HTML files keep their
own background, and the gradient runs up under the titlebar: the transparent
titlebar window turns on `.fullSizeContentView` and `titlebarAppearsTransparent`
(macOS 26 otherwise backs it with a material), and the desk sits behind the
whole content stack. Any `.background(Color)` in that stack must pass
`ignoresSafeAreaEdges: []` — SwiftUI's default extends it behind the titlebar
(the debug-build warning did). The sidebar's card, in both modes, is an
**unfocused pane's card** (`PaneSidebarCard` → `PaneCard`): the same corner radius, hairline
rim, glass sheet and shadow as the panes beside it (it was the viewer side panel's glass card —
rounder, a specular rim, a thinner sheet — and did not match). On glass the sidebar header is no band of its
own (the list starts below it),
and the sidebar's glyphs are the mock's icon set drawn natively
(`PaneSidebarSymbol`), not SF Symbols. Folding a window or project group animates. In the elevated style the
**focused pane** (of several) reads as **backlit**: a soft white light behind the
card spills past its edges onto the desk (masked to outside the card, so it never
lightens the pane's own glass) — a subtle outer glow only, nothing inside the
pane (`PaneFocusGlow`, driven by
`PaneView.isFocusedPane`; `PaneFocusGlowTests`).
**On glass, focus changes only the rim and the glow.** The focused pane's
hairline rim is lighter (34% white, against 10%) and it is backlit
(`PaneFocusGlow`); its sheet and its content are exactly those of every other
pane (`PaneGlass.tint`, 40%), nothing faded. An unfocused pane used to get a
thinner sheet (15%) and fade its terminal by `unfocused-split-opacity`, so
focusing a pane read as the pane itself lighting up; that is gone. Upstream's
unfocused dimming — a wash of `unfocused-split-fill` drawn OVER the pane — is
still not drawn on glass; `flat`, and `elevated` without glass, keep the wash
and honor both config keys as before. **Windows:** T2281.
**A stacked row has no solid cards.** A tucked card, on either side of the
run, is a card of the strip's size (see Stacked panes), so nothing lies under
a card on show and every card — every strip too — is glass. (Cards used to be drawn whole with most of them under
their neighbours, so every stacked card was filled 92% opaque — a row that did
not fit lost its glass altogether.) **Hero mode** shows its pane as that
same glass card — the hero container paints no fill of its own on glass
(`HeroPaneContainer.isGlass`); it used to fill with the terminal background,
an opaque slab where every other pane is glass. Measured on the composited window — how
much of the desk in the gutter beside a pane its glass hides — by
`glassPanesLookTheSameFocusedOrNot`, `stackedRowCardsOnShowStayGlass` and
`heroModeIsGlassLikeAFocusedPane` (`PaneSidebarWindowTests`); the layout rule by `noCardIsDrawnOverAnother`
(`PaneLayoutTests`). **Windows:** focus on glass changes only the rim (34% / 20%) and the glow since T2281 - every pane keeps the 40% sheet and no glass pane carries a dim wash (`dim_math.shouldDim`'s `glass`); measured by `pane-elevation.ps1` run 1d. T2086's thinner, faded unfocused sheet is gone with it. Hero as a glass card is T2104, stacked rows on glass T2105, the eased fade T2106. Glass itself is T1833.

**Resizes are debounced before they reach the program** (`src/termio/Thread.zig`
`Coalesce`): applied once resizes stop arriving for 100ms, never held back more
than 350ms. Each one is a SIGWINCH on which a full-screen TUI (Claude Code)
clears and repaints; at the old fixed 25ms coalesce a 600ms divider drag was 35
repaints — the resize flicker — and is now ~4
(`aDragDoesNotStormTheProgramWithResizes`). **A shell at its prompt is not
debounced** (`Termio.resizePace`): the grid reflows at once, and the next
resize waits only for the shell's redraw of the last, so a drag reflows the
prompt as it goes. It used to wait out the 100ms, and a drag reflowed only
every 350ms (`aResizeReflowsThePromptAsItHappens`, local and agent panes). A
program running (the cursor's content is output, or the alternate screen) is
debounced as above. **A resize never shows the
prompt blank.** With the cursor at a prompt, a resize clears the prompt for
the shell to redraw (`Screen.resize`, shell integration), and every frame
drawn before the redraw arrived showed it gone — for a round trip, longer
through the session agent, where the redraw can also arrive in pieces. The
renderer now holds the last frame (`Terminal.flags.awaiting_prompt_redraw`)
until the cursor's line (its row, or a row it soft-wraps from: a wrapped
prompt's last row can hold just the space before the cursor) shows text
again and the output has been quiet 15ms,
capped at 250ms (`termio.Thread.prompt_redraw_ms`) for a shell that never
redraws. That cap is armed after `loop.update_now()`: the IO loop's cached
clock is seconds stale after an idle stretch, and a timer measured from it
fires at once. Tests: `aResizeNeverBlanksThePrompt` (window resizes, local
and agent panes; frames in `/tmp/banner-collapse-resize[-agent]`). The pacing
and the frame hold are shared core, so Windows has them since T2249, proven
through ConPTY and the session agent by `test/win32/prompt-reflow.ps1` (T2251:
cmd and Windows PowerShell, local and agent panes, plus a running program
that must keep the debounce). One Windows-only rule: conhost's post-resize
paint ends cmd's input region (`133;I`) at its first row break, so on a ConPTY
child the pace also takes the cursor sitting on the prompt's own row
(`Termio.conptyPromptRow`) - pacing only, since nothing is cleared there.
The debug build states each decision on stderr (`resize pace=.. content=..
row=..`, `resize applied`, `prompt redraw released by=redraw|cap`).
`resize-overlay` defaults to
`never` in this fork (the dimensions popup on every divider drag). Verified by `glassPanesLetTheGradientThrough`,
which also writes a ScreenCaptureKit capture of its own window. A translucent terminal
(`background-opacity` < 1) gets an equally translucent gradient. Settled in the
pane-sidebar mock (`docs/design/pane-sidebar.md` → Pane style).

**Windows status (2026-10-11 intake):** none of this section exists on win32 yet.
The sidebar is T1828 (all-windows scope T1829), the hover grab handle T1830, the
elevated style T1831, per-window gradients T1832, glass panes T1833, the focus
glow T1834. The resize debounce is shared core and arrives with the merge; T1835
proves the win32 resize paths and the overlay default against it.

## Stacked panes

**A pane is never narrower than 225pt, or shorter than 125pt.** A row of panes that
cannot fit side by side at that minimum becomes a **stack**: as many panes as
fit stay on show (the **run**), and the rest are **minimized** into strips at
the edge they live on — the pane's own card at the strip's size (the same
glass, rim and unfocused tint as any card on show), its content faded out and
its name down it. Nothing is
ever squeezed below the minimum to make room. Layout is one pure function,
`PaneLayout.compute` (`Features/Splits/PaneLayout.swift`), used by the live grid
AND the stashed-pane slots, so a restored pane never reflows. **Windows:**
the 225x125 minimum is T2284.

- **A strip is named by its pane's banner title** when the banner has one,
  else by the pane's own title (else its directory's name, else its kind) —
  `PaneSidebarText.label`, the same name its pane sidebar row shows
  (`PaneView.displayLabel`). The banner title wins because somebody chose it:
  the banner hook sets it to the task, while Claude Code retitles the pane
  (OSC 0/2) with whatever it is doing. It is live — `+set-banner`, OSC 7778
  and Cmd+R relabel the strip at once, and clearing the banner (or a banner
  with no title) brings the pane's own title back. **What counts as a banner
  title** (`PaneSidebarText.bannerTitle`, pure) is deliberately narrow, never
  just the first line: a heading on the banner's first line (`## Fix strip
  labels` — what the hook writes above its table), or a ONE-line banner that
  opens with a bold run standing alone or before ` · ` (`**Fix strip labels**
  · **Goal:** …` — the hook's OSC fallback). A bold label (`**Goal:** …`), a
  bold run followed by prose (`**PR #12** — 3 files`), a bold line heading a
  multi-line banner (`**Last result**`), and a title-less table are not
  titles. Markdown is stripped (bold, code, links → their label). Tests:
  `PaneSidebarTextTests`, `aStripIsLabeledByItsBannerTitleLive` (reads the
  composited window).

- **Clicking a strip focuses its pane, and focus is what brings it forward**
  — there is no separate "bring forward" state. A click, `goto_split`, the pane
  sidebar, `ghoztty://focus/…` all just focus the pane, and the row follows
  (`PaneStackState.noteFocus`). It is a carousel, not a z-flip: the clicked card
  slides into the slot it takes and the cards it displaces slide to the slots it
  left, every card staying in tree order left to right. A strip click restores
  just that pane, sharing the space evenly; a pane on the far edge minimizes
  only when there is no room for one more. **Focusing a pane already on show
  never moves anything**, in a collapsed row or one stacked for want of room:
  the run sticks (`PaneLayout.stickyRun`, from the run last laid out,
  `PaneStackState.shownRun`), and a strip brought forward slides it only as far
  as it takes. Focus history decides a run only when there is none to keep (a
  new row, the window grown or shrunk past a card) — it used to decide every
  layout, so clicking the far card on show re-centred the row on it.
- **Elevation**: the run is highest, and strips sit lower the farther they are
  from it, on both sides — the run casts its shadow on the strip beside it, and
  each strip on the next one out. On either side of the run a tucked card is
  drawn at its strip's size (`Leaf.isSliver`), so glides never move a card
  through another and no card on show ever has one under its glass.
  Paint order is `Leaf.elevation`, not tree order.
- **Every gutter of a row is one thing, and the row is a function of where
  it is.** A divider, a grip between cards on show, and a grip where the run
  meets its strips (on any stacked row with strips on that side, collapsed by
  the user or for want of room) are all gutters of their row, and dragging one
  makes the row what `PaneLayout.dragged` says the gutter's position makes of
  it — computed afresh every step from the row as the drag found it, never
  from the step before: the items before the gutter get the space from the
  row's start to it, the items after it the rest; each side shows as many of
  its items as fit at their minimums, nearest the gutter first, the others
  strips at the row's edge on that side (a side with no room for even one is
  all strips, the gutter at their edge, the other side taking the rest); the
  item beside the gutter takes up the slack, and the others keep their sizes
  from when the drag began until the space runs out, then give way nearest
  first. **A drag only collapses panes, and brings out at most one**: a side
  never shows more than it had on show when the drag began — or, all strips
  then, the one pane beside the gutter, pulled out. So a gutter dragged one
  way tucks the panes on that side away one after another while the panes on
  the other side grow and its strips stay strips; a strip pulled out by its
  gutter comes out alone, growing as far as the hand takes it, the strips
  behind it staying strips and the panes on the other side tucking away to
  make room (`aStripPulledOutBringsOutItsPaneAlone`,
  `aGutterDraggedNeverBringsStripsOutOnItsOtherSide`,
  `aStripPulledFarBringsOutItsPaneAlone`). It used to bring strips out on
  the side gaining room, so collapsing one pane pulled the far ones out, and
  a strip pulled far brought the next one out after it. Dragged back, a
  gutter undoes exactly that: let go where it began, the row is as it was.
  A pane tucks away the moment it would go under its minimum; there
  is no resistance band past it, which would make the row depend on how the
  gutter got where it is. The row's state goes to `PaneStackState.show` (a
  `Pin` and slot shares), or, all of it on show, to the tree's ratios
  (`SplitTree.settingRow`). It measures in row coordinates, so `(a | b) | c`
  and `a | (b | c)` behave the same. It replaced a squeeze chain for dividers,
  a one-strip-at-a-time pull for edge grips and a two-slot resize for grips
  between cards, which disagreed with each other and depended on the path:
  an edge grip brought out one strip and nothing more until the mouse was
  let go, and dragging a gutter across a row and back ended in undefined
  states. Tests: `aGutterDraggedAcrossTheWholeRowAndBackIsCoherentThroughout`
  (the whole of it, hand-paced: a middle gutter dragged to the left edge, the
  right edge, and back, every sampled frame checked — no overlap, every
  gutter the row's, every card inside the row, one bar — and the row as it
  was at the end), `pullingTheLastStripOutOfAFullRowTucksTheFarPane`,
  `aRunEdgeWithNoRoomForOneMoreIsStillAGrip`,
  `aStripIsPulledBackOutByItsGutterLikeADivider`; the rule's own cases in
  `PaneLayoutTests` (`aGutterDragged…`). **A row nested across the divider
  counts as it is laid out**: a column holding a collapsed row (or one
  stacked for want of room) is only as wide as that row's run and strips
  (`PaneStackState.laidOutPin`, through `SplitTree.movingDivider(laidOut:)`);
  counted with all its panes side by side, the column was past its minimum at
  the first pixel and the whole column tucked away
  (`aDividerBesideAColumnWithACollapsedRowResizesIt`). A collapsed row stays
  collapsed with room to spare (a `Pin`). Rows nest (`a | (b / c)` is a row
  whose second item is a column), and each keeps its own collapse.
- **Double-clicking a divider evens out the panes across it — in its
  direction only** (`TerminalSplitOperation.equalize`,
  `SplitTree.equalized(only:)`): a horizontal divider evens the heights and
  leaves every width as set, and the other way round. It used to run
  `equalize_splits`, which reset every ratio both ways (a pane made narrow
  came back wide). `equalize_splits` itself still evens out both. Test:
  `equalizedInOneDirectionKeepsTheOther`. **Windows:** T2285.
- **What can be dragged says so**: every divider and grip (`DividerHandle`)
  and the edge of a side panel (the pane sidebar's, a viewer's contents —
  `SidePanelResizeHandle`) shows a 4pt accent bar with a soft glow down the
  middle of its gutter (`GutterBar`): at half strength while the pointer is
  over it, full while it is dragged. **The bar stays in the gutter**, never
  out at the pointer: it is drawn at the gutter being dragged as the layout
  leaves it, so it stops where the edge stops — at a pane's minimum, a
  panel's widest or narrowest, a strip whose pane has not come out yet — and
  when the gutter snaps (a pane tucks away, a strip comes out or goes back)
  it moves to the gutter that took its place, lit until the mouse comes up.
  Rules that came from bugs:
  - While a drag is under way the bar is drawn on the window, not on the
    handle, and above everything on it (`zPosition`): a grip whose strip
    comes out is replaced mid-drag, and the bar went with it; then the
    panes' layers were drawn over it as a card slid.
  - One bar at a time: no gutter shows its hover bar while any drag is under
    way (a grip that came back under the pointer doubled the bar up).
  - When the dragged gutter is replaced, the bar goes to the gutter that
    moved the way the drag is going, nearest to where the bar was — a gutter
    snapped to the edge as its pane tucked away. Nearest the pointer, it
    took the gutter beside it (`theBarStaysWithTheGutterThatSnappedToTheEdge`).
  - A gutter asks again whether the pointer is over it whenever it moves in
    its window (`updateTrackingAreas`, which AppKit calls then, even when it
    is an ancestor that moved), and every gutter in the window asks when a
    drag ends: a gutter that moved out from under a still pointer gets no
    mouse-exited, and stayed lit as if the drag were still going on. The
    tracking areas also run during drags (`.enabledDuringMouseDrag`). Tests
    say where their synthetic pointer is (`GutterBar.pointerOverride`).

  Tests: `aDividerShowsABarOnHoverThatFollowsTheDrag`,
  `theBarStaysInTheGutterAsAStripComesOutAndGoesBack` and
  `theBarStaysInTheGutterAsADividerCollapsesAPaneAndBack` (paced drags
  recorded as the window server composites them: one bar in every frame
  while held, in the gutter), `theExpandedSidebarResizesFromTheGutterBesideIt`
  (stops at the panel's widest).

  **Windows:** the one gutter rule, the accent bar and the glide are T2253.
- **Strips are blades**: no gap between two strips (`Metrics.bladeGap` = 0),
  and a strip that has another between it and the run reaches 12pt under that
  one (`Metrics.bladeTuck`), its rounded edge out of sight — overlaid bars, not
  pills touching at their corners; each still shows 36pt, its title centered on
  what shows (`PaneCardView.titleRect`). Each casts a tight shadow that leans
  AWAY from the run onto the blade behind it and stops at its own sides, and
  the shadow follows `collapse`, so it comes on as a card narrows into its
  strip rather than snapping in when the glide lands. They used to be spaced
  by a full gutter each. **Windows:** T2283.
- **Resizers live in the gutters**: every card on show is separated from the
  next by the same gutter (`Metrics.gap`: 10pt elevated, 6pt flat), and so is
  the run from each group of strips beside it — the grip that pulls a strip
  back out lives there. A run with strips on both sides has one more such
  gutter than a run at an end, so its cards are that much narrower there (they
  take it after the glide, one resize each). Every resizer takes the mouse in its gutter and nowhere else
  (`Divider.gutter`, `StackHandle.gutter`): split dividers, grips between
  cards, the grip where the run meets its strips, and the pane sidebar's edge
  — expanded, ALL of the gutter between the panel and the panes, and none of
  the panel (`PaneSidebarState.pinnedEdgeGrip`; it used to straddle the
  edge, half of it a click on the list; `theExpandedSidebarResizesFromTheGutterBesideIt`);
  flat, or on the rail card, just inside its edge. A click just
  inside a card's edge is the card's — its grab handle sits at its top edge,
  and a strip is its own drag source. Pinned by
  `everyResizerSitsInAGutter` / `everyResizerOfAStackSitsInAGutter` (real
  windows: every resizer frame against every card frame, plus hit-tests just
  inside each card's edges) and by `PaneStackFuzzTests` in both styles.
- **Adding or removing a pane never brings minimized panes back out** —
  in a row or a column — unless only one pane is left in that direction.
  Every tree change carries each collapse over to the row it became
  (`PaneStackState.rowsDidChange`, `Pin.carrying`): the same items with
  some gone, some joined, or moved within it — or with a column that emptied
  down to a row of its own merged into it, each of its pieces keeping the
  column's place (a strip if it was one). A collapsed row nested in that column
  keeps what it minimized: the merged row's run is what both show
  (`intersecting`). The one exception is the focused pane: a merge never
  leaves it a strip, so a strip between it and the run comes out with it (a
  run is contiguous). `PaneStackFuzzTests` drives random sequences of
  collapse, widen, focus, split, close, close-and-undo, swap and resize, in
  rows, columns and nested rows, both styles, checking these rules after every
  step.
- **A pane joining a collapsed row keeps it collapsed** (a split — Cmd-D,
  `+split` —, a drop, a restored stash): one that lands beside the panes on
  show, or between them, is on show with them — a split of a pane on show
  shows both where they fit, else the focused one, and the pane it pushed out
  becomes a strip. One that lands among the strips is a strip until focused.
  A split *across* the row (`d` becomes a column `d / e`) changes no slot.
  A pane moved within the row keeps the same panes on show; a swap swaps
  what is on show (`PaneStackState.swap`), and a pane dropped on a strip
  takes its place there, minimized — the caret goes to the pane that came out
  of the strip, not the dragged one. Focus landing before or after the tree
  change gives the same row.
- **A pane leaving a collapsed row keeps it collapsed** (closed, stashed,
  moved away): the panes still on show take its space and the strips stay
  strips on their sides; closing the only pane on show brings out the strip
  before it (else after). Pins are keyed by the row's pane set, so
  `PaneStackState.rowsDidChange` carries them over on every tree change; a row
  that is no longer on screen has no pin. **Undo puts back the stack state
  saved with the tree** (`PaneStackState.Saved`, taken by
  `replaceSurfaceTree`), so an undone close brings the row back exactly. (Old
  rows' pins used to be kept for that, and came back stale after later changes
  — minimizing the focused pane.)
- **A side pane opened without focus comes on show.** A pane split off the
  pane with the caret that does not take it — every agent `+split` (focus is
  opt-in), a banner link's Cmd-click side pane — was asked for, so it must be
  seen: it is the **featured** pane (`PaneStackState.featured`), ranked ahead
  even of the focused pane (`PaneStackState.ranks`, -1) wherever its row has
  no room for every pane. Other panes in the row minimize to make room; when
  even that is not enough the CALLER becomes the strip — and **keeps the
  caret**. It used to be born a strip: in a window with room for two cards
  but not three (~640–950pt, a half-screen window), the run kept the caller
  and its last-focused neighbour, and the new pane was a strip nobody saw.
  The feature ends with the next change of focus, after which the row is the
  focus history's again. Set by `newViewerSplit`, and by `newTerminalSplit`
  / `newSplit` when `focus` is false. Tests:
  `aSidePaneOpenedWithoutFocusComesOnShow`,
  `aSidePaneInARowWithRoomForOneTakesItAndTheCallerKeepsTheCaret`,
  `aSidePaneOpenedWhileTheWindowIsCoveredIsThereWhenUncovered` (rules out a
  covered window as a cause). Windows (T2257): the same rule —
  `PaneStackState.featured`, set by `Window.insertPaneAsSplit` for a
  background split; the layout reads it through `layoutRank` (ranks there are
  unsigned, so the featured pane takes 0 and the history moves back one), and
  it is also dropped once its pane leaves every row, since win32 pane ids are
  addresses. Tests: the `side pane` cases in `pane_stack_state.zig` and
  `test\win32\side-pane-featured.ps1`.
- **Focus never MOVES onto a strip** unless the user asked for that pane:
  focusing one brings it out. (The one way the caret can sit in a strip is to
  have stayed there — the caller of a side pane, above.) Every handoff picks the pane on show nearest
  the candidate (`paneOnShow`, `focusTargetAfterRemoving`): a close, Cmd-W in
  a viewer, a stash, a close from the sidebar, and the window becoming key
  with nothing focused. And only a pane that **really has the caret** counts
  as focused to a stack (`PaneView.holdsKeyboardFocus`): `focusedPane` falls
  back to the last focused terminal while the caret is elsewhere (a viewer
  gave it up, the window itself after a re-parent), and that terminal may
  have been minimized since — reading it as focused again brought it back
  out.
- **A change in what is on show glides; nothing slides on its own clock.**
  A strip's pane coming out or going back, a pane tucking away — by a
  divider or grip drag, a strip click, a split or a close — is a **glide**
  (`PaneStageView.glide`): every card and strip eases from where it is drawn
  toward where the layout puts it (about 90% in 0.15s), all re-placed
  together every frame, so a card, its sheet and its content move as one
  and the gutters between cards hold their width. Under a drag the layout
  keeps changing and each frame eases toward its latest — no tween with an
  end to reach and correct from: the target is retargeted mid-motion as the
  hand moves.
  - **A pane going into its strip narrows into it** as a card, rim and glass
    all round it, its content pinned to its far edge (sliding behind the
    strip's edge) and cut by the card; **its content fades out and its title
    fades in** as it narrows (`PaneCardView.collapse`: by how much wider than
    a strip it is drawn, over its last 120pt). Coming out is the same the
    other way round. At the strip there is nothing left to change: it used to
    glide in as a glass card and then switch, in one frame, to a dark bar
    over a black scrim (`aPaneCollapsesIntoAGlassStripWithNothingSnapping`,
    which also checks the strip reads as glass against the desk beside it).
    The flat style, whose panes are no cards, fills its strips.
  - **What a card's content is held at.** Under a drag, at where the layout
    puts it now (the larger of that and its size when the glide began, for a
    card on show at both ends) — held at the first target instead, a fast
    pull left the content short of its growing card
    (`aFastPullKeepsTheGlideOnTheHand`). In a glide no drag began, at the
    size it had (a strip's pane at its last size on show) until the glide is
    over, when every card takes its size in one transaction: **one resize per
    terminal, after the motion** (`aResizingSlideResizesEachTerminalOnceAfterIt`,
    which records the glide at the display's frame rate, frames in
    `/tmp/pane-stack-snapshots/frames`, and fails on a frame where the still
    card flashes). It used to be resized on every frame of a 0.25s focus fade.
  - **A glide lasts the drag and settles after it**: a card that has caught
    up rests until the next step, and when the hand lets go the cards glide
    on to where they were headed. "The drag is over"
    (`PaneStackState.isGesturing`) lands 50ms after the mouse comes up: a
    fast hand outruns the grid (`aFastPullLetGoOfSettlesWithoutASnap`). The
    stage hears the drag end itself (it observes `isGesturing`): left to the
    next redraw of the grid, which the end of a drag does not always bring, a
    resting glide never finished.
  - **Every item glides**, a strip as much as a card, by the rect it is
    drawn in — with only cards gliding, a pane that tucked away left a hole
    its neighbours glided into (`pullingTheLastStripOutOfAFullRowSettlesWhole`).
    The drag's bar is drawn over the gutter as the cards draw it
    (`PaneStageView.shownGutter`).
  - Clicks used to run a Core Animation slide, and a drag ran it against the
    hand: the card beside jumped, the one coming out lagged with its content
    held at its old size, its sheet faded in and its strip out on their own
    clocks, and a release mid-slide could leave them there. Tests:
    `aStripPulledOutFollowsTheHandWithNothingSliding` (every card sampled
    through a hand-paced drag: nothing on its own clock, the gutter its
    width, the pane seen on its way in, the bar over the drawn gutter).
- **A minimized pane is never resized**: it keeps the size it last had on
  show — a row reflowing around it never resizes a program nobody can see —
  and takes its slot's size once, when the glide bringing it forward ends.
- **Drag a strip** to pick its pane up: the card itself follows the pointer (no
  drag image, past a 5pt threshold, so a click with a wobble is a click). A
  strip has **targets of its own** (`PaneDropResolver.resolveBlade`; see Pane
  rearrange mode): a slot between any two cards or strips of its row (or at
  either end) moves it there — on show if it lands between cards on show, a
  strip among strips — a window's edge inserts it at the top level, a
  screen's edge tiles it into a window of its own, the pane sidebar stashes
  it. Over a pane there is nothing: no split quadrants, no swap. Strips are
  still drop targets for a NORMAL pane drag (`PaneDragSession` uses the
  strip's rect for a minimized pane — only a strip that is showing).
- **Zoom / hero** show one pane, so nothing stacks. **The pane sidebar** lists
  minimized panes like any other; clicking one focuses it, which restores it.
  Dragging a strip onto the sidebar stashes it. **Flat style** stacks the same way, with square
  strips and a 1px line on its grips.
- **Ephemeral**: which panes are minimized and how a run's slots are sized are
  not persisted. A relaunch starts from the focused pane with every row side by
  side again where it fits.

Code: `PaneLayout.swift` (pure), `PaneStackState.swift`, `PaneStage.swift`,
`PaneStackTab.swift`. Tests: `PaneLayoutTests`, `PaneStackStateTests`,
`PaneStackFuzzTests`, `PaneStackWindowTests` (real windows, real mouse events
for divider drags; captures to `/tmp/pane-stack-snapshots`).

**Windows status (2026-10-20 intake):** none of this exists on win32 yet.
The epic is T2081: the minimum, strip layout and carousel slide T2082, a
collapsed row staying collapsed across close/stash/move/split T2083, sticky
runs, chained drag-collapse, gutter-only resizers and strip drop targets T2084.
Strip names by banner title share T2085's label rule.

## Pane rearrange mode

**Cmd+Shift+.** (menu: View → Toggle Rearrange Mode; command palette: "Toggle
Rearrange Mode") toggles a per-window mode in which every pane grows a 24pt
**header** — a drag grip on the left, the pane's title, and a button on the
right that moves the pane out into its own window. The **tab bar is forced
visible** while the mode is on, because it is a drop target. Exit with the
toggle again, **Escape**, or the menu item.

The header takes real layout space: a pane's sticky banner is pushed down
below it and the content below that, so entering and leaving the mode
**resizes every terminal in the window** (one `SIGWINCH` and redraw each way).
That is deliberate — a header that occludes nothing costs a reflow.

**Dragging a pane works with the mode off too.** The mode changes affordances,
never behavior: the hover-revealed grab handle at the top of a pane and the
moded header both start the same drag, and every drop goes through one
resolver. There is no "moded dropping" to drift from "unmoded dropping".

| Where the pointer is released | Result |
|---|---|
| A quadrant of a pane | Split that pane on that side |
| The **center** of a pane | **Swap** the two panes in place |
| Within **28pt of the window's edge** | Insert at the **top level** of that window's tree, spanning the full side |
| The **tab bar** | Move the pane into a **new tab of its own**, at the index under the pointer |
| Anywhere else | Move the pane into a **new window** there |

**A strip (a minimized pane) has its own targets** — it is a pane put away
in its row, so it gets the targets of putting it somewhere else in that row or
taking it out of the window, never a pane's quadrants or swap
(`PaneDropResolver.resolveBlade`, in this order):

| Where a strip is released | Result | Preview |
|---|---|---|
| Within **12pt of a screen's edge** | A **new window** holding the pane, **tiled** to that half of the screen's visible frame | A translucent accent panel over that half (`TileDropPreview`) |
| The **pane sidebar** | Stash it, as any pane | As any pane |
| A **slot of its own row** — the gutter between two of its cards or strips (reaching 24pt into each), or either end | **Move it there** within the row: on show between cards on show, a strip among strips; the row stays collapsed | An accent insertion bar down the gutter (`BladeDropOverlay`) |
| Within **28pt of a window's edge** | Insert at the **top level**, as any pane | As any pane |
| Anywhere else (over a pane, another window, the desktop) | **Nothing** — the card settles back | — |

The slots are read off the strips and cards on screen
(`PaneBladeDrag.slots`, from the row `PaneStackState.stackMinimizing` names);
a slot beside the strip's own place is left out. A strip that is one pane of a
minimized column leaves the column. Resize grips never compete: they live in
the gutters only, and a strip is a drag source of its own.
**Windows:** strip drop targets are T2084.

Pane zones use the pane's diagonals (nearest edge wins), with a centered swap
rectangle at 34% of each dimension — floored at 44pt so a narrow pane stays
hittable, capped at 60% so a small pane does not become mostly swap. The
window edge band beats the pane under it. **Long-hovering a tab button for
500ms selects that tab** so the drag can continue into its layout; that is the
only way to drop *into* an existing tab, since the bar itself always means
"make a tab".

**Cross-window and cross-tab drags are the same code path** — a macOS tab is
its own `NSWindow` with its own `TerminalController`, so "another tab" and
"another window" are both just a different controller. Resolution takes a
**set** of candidate windows and arbitrates overlaps by z-order.

**Viewer panes rearrange like any other leaf**, and terminal panes keep their
process, scrollback, and session: every mutation rebuilds the tree out of the
*existing* `PaneView` instances, the same identity-preserving rule
`+rearrange` follows.

**A drag never closes a window.** A move that would empty the source window is
refused, and the pop-out button is disabled on a lone pane — an emptied window
closing as a drag side effect would bypass close confirmation and the remote
Disconnect prompt.

**Moving a pane between windows must not end its session.**
`SessionCloseIntentPolicy` reads a leaf leaving a tree as "closed" and marks
its agent session CLOSE-on-free. Removing from the source before inserting
into the destination fixes a plain move, but **no ordering fixes a
cross-window swap** (each pane departs one tree and arrives in the other), so
`PaneMoveCoordinator.finishRelocation` explicitly declares the relocated panes
alive once both trees are in place. The coordinator is the one thing that
knows a move happened, so it says so.

Design: `docs/design/pane-rearrange-mode.md`. Code:
`macos/Sources/Features/Splits/PaneDropResolver.swift` (pure),
`PaneDragSession.swift`, `PaneMoveCoordinator.swift`, `PaneHeaderView.swift`.
Tests: `PaneDropResolverTests`, `SplitTreeRearrangeTests`,
`PaneMoveSessionSafetyTests`, `RearrangeModeStateTests`.

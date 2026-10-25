# IPC targeting: focus, names, pane identity, anchoring, instances

How an IPC command (`ghoztty +…`) decides **which instance**, **which window
or pane**, and **whether to take focus**. Every command in
[cli-commands.md](cli-commands.md) follows these rules; the per-command docs
only note exceptions. User-facing flag tables live in the bundled skill
(`macos/Resources/Ghoztty/skills/ghoztty/`).

IPC commands talk to a running Ghoztty over a Unix domain socket. All are
idempotent: a named target that already exists and matches the request is
reused, not recreated (and focused only with `--focus`). A `+split --name` that
names a *different* pane fails instead of silently reusing it (see `+split`).

## Focus: programmatic surfaces stay in the background

**No `ghoztty +…` command takes focus unless it is given `--focus`.** Agents
and hooks open windows and panes while the user is working somewhere else, so
the default is "background", and no skill or hook has to opt out.

| | default (no `--focus`) | `--focus` |
|---|---|---|
| App activation (`NSApp.activate`) | no | yes |
| Window raise (`makeKeyAndOrderFront`) | no | yes |
| Keyboard focus moved to the new/target pane | no — **the pane that had it keeps it** | yes |

- **Where it applies**: `+new-window` (incl. `--view`, `--split`,
  `--from-focused`), `+split` (every anchor: caller pane, `--pane`, `--target`,
  `--from-focused`; terminal and `--view`), `+new-remote-window`, `+restore`.
  The **idempotent hits** too: `+new-window --target=<existing>` and `+split
  --name=<existing>` succeed and do nothing focus-wise; with `--focus` they
  raise/focus the existing target.
- A background window is shown without being made key, ordered **directly
  behind Ghoztty's frontmost window** (`TerminalController.orderInBackground`)
  — not `orderBack`, which buries it behind every app's windows.
- `+split` run from a pane leaves **the caller's pane** with the caret. That
  needs work: inserting a split re-parents the pane beside it, which resigns
  first responder and leaves the *window* as first responder (typing goes
  nowhere). `BaseTerminalController.keepingFirstResponder` hands focus back
  after the re-parent; every non-focusing split goes through it, including the
  GUI's viewer side panes (banner/link Cmd-click).
- `--focus` from an **inactive** app waits for activation to land before
  moving the caret (`IPCServer.focusOnceSettled`); otherwise the window's
  become-key handler restores its stale `focusedSurface` after the move.
- `--focus` is a bare switch; `--focus=true` / `--focus=false` also parse.
  After `-e` it is part of the command. **`--no-activate`** (the old opt-out)
  is accepted as a no-op so existing callers don't break; `--focus` wins if
  both are given.
- **Manual surfaces are unaffected**: Cmd-N, Cmd-D, the menu, the command
  palette, File → Open, the dock, App Intents and AppleScript keep focusing —
  they never consult the policy.
- **`ghoztty://focus/<target>` is unaffected** — raising is the whole verb. It
  shares `IPCServer.bringForward` with the `--focus` idempotent hits, so
  "focus an existing target" means one thing.
- A failed `+new-remote-window` dial still shows its modal alert either way.
- One decision point: `IPCFocusPolicy` (`.background` / `.foreground`), parsed
  into `ParsedArguments.focus`. Tests: `IPCFocusPolicyTests`.

## Naming

- `+new-window --target=<name>` registers a **window**. Window names are
  global: one window holds a name, and a name a pane holds cannot be taken by
  a window (`+new-window --target=` fails rather than "reusing" a pane).
- `+split --name=<name>` registers a **pane**, in the window it lands in.
  **Pane names belong to their window**: two windows can each have a pane
  called `draft`. (A single global namespace let two agents in different
  windows "reuse" each other's side pane.)
- `+split --target`, `+close --target`, and `+send-keys --target` reference
  either kind.

**How a name is looked up** (`TargetLookup`, the one policy;
`IPCServer.lookup` applies it). Every command carries the pane it was run from
— the CLI writes `$GHOZTTY_PANE_ID` into each request as a top-level
`caller_pane` field — and the name means, in order:

1. a pane of that name in **the caller's window**;
2. a window of that name;
3. a pane of that name in another window, **if exactly one window has one**.

Two or more other windows holding the name is **ambiguous**: the command
fails (exit 1) naming the windows and pointing at the pane id, rather than
act on another agent's pane at random. A caller with no pane (a plain shell, a
`ghoztty://` link) starts at step 2. A pane id is always exact. An explicit
`--target=<window>` / `--pane=<id>` still reaches across windows.

This applies to `+split --name`/`--pane`/`--target`, `+close`, `+send-keys`,
`+read`, `+set-banner`, `+set-state`, `+reload`, `+stash`, `+restore`,
`+rename` and `+rearrange` (whose layout names panes of the window it
rearranges). `caller_pane` is a field rather than an argument so it is
additive both ways: an older app's decoder ignores an unknown field, where an
extra argument would have become text in its `+set-banner`. The server folds
it into the arguments as `--caller-pane=` (in front of any `-e`), the one
spelling every handler reads (`IPCRequest.resolvedArguments`). A name follows
its pane when the pane moves to another window. Tests: `TargetLookupTests`,
`PaneNameScopeWindowTests` (two real windows: split, close and send-keys from
each).

**Auto window names.** A window opened without `--target=` (Cmd-N, a bare
`+new-window`) gets `window-1`, `window-2`, …, exported to its panes as
`$GHOZTTY_WINDOW_NAME` and shown as `target` in `+list`. It is targetable
immediately: `resolveTarget` falls back to scanning live windows by name, so
no `+list` is needed first.

`$GHOZTTY_WINDOW_NAME` is baked at spawn, and a session restore bakes it too:
the restored window's name is settled **before** its panes are built, so an
agent restart RELAUNCHes each shell with it
(`AppDelegate.sessionLayoutLeafConfig`). The name is the persisted target when
still free, else a fresh `window-N` — never a name another window holds, which
`+close --target=$GHOZTTY_WINDOW_NAME` would then close
(`AppDelegate.restoredWindowName`; tests: `SessionLayoutRestoreTests`). A
target name never changes after creation (`+rename` changes the title), but a
process keeps the value it was spawned with, so a pane whose window could not
re-adopt its name holds a stale one. **The authoritative lookup is `+list
--json`, keyed by `$GHOZTTY_PANE_ID`**; the env var is the cheap,
usually-right shortcut.

## Pane identity

Every pane has a **stable, ghoztty-owned pane id** (a UUID):

- Exported to the pane's processes as `$GHOZTTY_PANE_ID` (baked at spawn).
- Shown as the leaf `id` in `+list --json`.
- Accepted directly by every `--target`/`--name` (case-insensitive), with no
  prior registration or `+list`: `ghoztty +set-banner
  --target=$GHOZTTY_PANE_ID …` works from inside any local pane.
- Stable for the pane's whole life: persisted in the session-layout manifest
  and restored on relaunch (session-persistence panes keep the same id AND the
  same baked env), preserved across remote reconnect swaps, and re-applied to
  the respawned shell when the agent relaunches a session after its own
  restart (the RELAUNCH carries the pane's env/TERM/argv).

Prefer the pane id over pid/tty matching for self-identification: pids and
ttys belong to the machine the process runs on and are meaningless for remote
panes. (`+list --tty=<tty>` still works for local panes.)

## Caller anchoring

A command that needs a pane or window and was given none anchors at **the pane
it was invoked from**, not at whatever window happens to be focused. The CLI
forwards `$GHOZTTY_PANE_ID` as `--caller-pane=<id>`; the app prefers it over
`TerminalController.preferredParent`. (The default used to be read on the main
queue at handle time — whichever window was key by then — which raced with the
user and with focus changes.)

- **Name lookup is a different use of the same pane** (see Naming): every
  command sends `caller_pane`; anchoring is only for commands that need
  somewhere to put a pane.
- **Applies to `+split` and `+rearrange`.** `+new-window` needs no anchor, and
  `--from-focused` (on `+split` and `+new-window`) asks for the focused window
  by name, so neither changed.
- **Anything explicit wins**: `--target`, `--pane`, `--from-focused`.
- **Absent or empty ⇒ focused-window fallback**, so a CLI run from a plain
  shell, or from a pane baked by an older app/agent, is unchanged.
- **A pane id that no longer resolves falls back rather than failing** — a
  script outliving its pane is ordinary. That is why the wire flag is
  `--caller-pane=` and not `--pane=`: an explicit `--pane=` naming nothing is a
  typo and stays a hard error.
- One resolution site each side: `apprt.ipc.seedCallerPane()`
  (`src/apprt/ipc.zig`) for the CLI, `IPCServer.callerAnchorPane` (Swift) for
  the server.

## Instance addressability

An IPC command run inside a pane targets **the app instance that owns that
pane**, not whichever build the `ghoztty` on `$PATH` is. Every pane's env is
baked with `$GHOZTTY_IPC_SOCKET` — the absolute path of its own app's IPC
socket — and the CLI prefers it over the compile-time
`ghostty[-debug]-<uid>.sock` derivation. So `ghoztty +split` from a
debug-build pane splits the **debug** window even though `ghoztty` on `$PATH`
is the release binary.

- Baked on every pane path: plain local spawn, session-persistence agent panes
  (the agent replays the pane env on RELAUNCH), and remote panes — a remote
  pane's IPC still belongs to the *local* app.
- Absent or empty ⇒ the derivation, so a plain shell or a pane baked by an
  older app/agent is unchanged.
- Override it (`GHOZTTY_IPC_SOCKET=<path> ghoztty +list`) to aim a single
  command at a specific instance.
- One resolution site each side: `apprt.ipc.socketPath()` (`src/apprt/ipc.zig`)
  for the CLI, `IPCSocket.path` (Swift) for the server.

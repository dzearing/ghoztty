# Sessions and remote machines

Read from the `ghoztty` skill when a pane's process lifetime matters, or to open a shell on another machine.

## `ghoztty +close`

Close a named pane or window. **Closing a nonexistent target succeeds silently** (idempotent).

```
ghoztty +close --target=<name>
```

**This ends the pane's session — it does not hide it.** Session persistence is on by default, so a terminal pane's shell runs under the `ghoztty-agent` and normally survives an app quit, crash, or upgrade. `+close` is not that: it kills the process once the close's undo window expires, exactly like closing the pane in the GUI. Only an app quit preserves a session for re-attach. Viewer panes have no session, and `+close` never prompts for them.

## `ghoztty +sessions`

List the persistent terminal sessions owned by the local `ghoztty-agent` — the daemon that keeps PTYs alive across app restarts.

```
ghoztty +sessions [--json]
```

Unlike every other IPC command, this dials the **agent directly** rather than the app's socket, so it works even when the Ghoztty app is not running (as long as the agent is). Requires `session-persistence = on`, which is the default.

Each row reports the session id, liveness (`alive`, or `dead(<code>)` for a tombstoned session), whether a viewer is `attached`, the activity state, the child pid, whether it is `pinned` against the agent's idle reaper, the working directory, and the command.

`--json` emits a **bare array** of rows — not the `{"success":…,"data":…}` envelope the window commands use — with every field present including nulls: `id`, `alive`, `exit_code`, `attached`, `activity`, `pid`, `cwd`, `argv`, `title`, `created_at`, `last_activity`, `pinned`.

```bash
ghoztty +sessions
ghoztty +sessions --json | jq -r '.[] | select(.alive) | "\(.id)\t\(.activity)\t\(.argv)"'
```

## `ghoztty +new-remote-window`

Open a terminal window whose shell runs on a **remote machine**, via a `ghoztty-agent` reached over TCP. Same flow as the Cmd-Shift-N "New Remote Window" menu action.

```
ghoztty +new-remote-window --host=<host> --port=<port> [flags]
```

| Flag | Description |
|------|-------------|
| `--host=<host>` | Agent host, DNS name or literal IP. Required. |
| `--port=<port>` | Agent TCP port. Required. |
| `--working-directory=<path>` | Working directory **on the remote machine**. Overrides that machine's per-host default. |
| `--shell=<path>` | Shell **on the remote machine** (e.g. `wsl.exe`, `powershell.exe`, `/bin/zsh`). Overrides the per-host default. |
| `--command=<cmd>` | Command to run instead of an interactive shell, through the resolved shell's native convention (POSIX `-lic`, cmd `/c`, powershell `-Command`, wsl `--`). |
| `--focus` | Activate Ghoztty and raise the new window. Off by default — it opens in the background. |

```bash
ghoztty +new-remote-window --host=127.0.0.1 --port=7777
ghoztty +new-remote-window --host=winbox --port=7777 --shell=wsl.exe --working-directory='C:\dev'
```

Your local shell and cwd are **not** forwarded — they wouldn't exist on a different OS such as a Windows ConPTY agent. The remote machine's own defaults apply unless a per-host default (machine chooser → row `⋯` → "Host Settings…") or an explicit flag says otherwise. A remote pane's IPC still belongs to the **local** app, so `+split`, `+close`, and `+set-banner` target it like any other pane.

## Mistakes

- **Don't `+close` a pane you only meant to hide** — it ends that pane's persistent session and the process does not come back.

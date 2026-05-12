# Ghoztty

A fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds CLI-driven window management for AI agents and automation.

## CLI Window Management

IPC commands communicate with a running Ghoztty instance over a Unix domain socket. All commands are idempotent — named targets that already exist are focused instead of recreated.

### `ghoztty +new-window`

Create or focus a terminal window. Auto-launches Ghoztty if no instance is running.

```
ghoztty +new-window --target=<name> --working-directory=<path> --command=<cmd> --shell=<path> --title=<title> --split=right|down|left|up --split-command=<cmd> --no-focus -e <args...>
```

- `--shell`: Shell to use for `--command`/`--split-command`, invoked with `-lic` so profile is loaded. Falls back to config `command-shell`, then `$SHELL`, then `/bin/zsh`.

### `ghoztty +split`

Create a split pane in a running window.

```
ghoztty +split --direction=right|down|left|up --target=<name> --name=<name> --command=<cmd> --shell=<path> --working-directory=<path> --no-focus -e <args...>
```

- `--direction`: Split direction. Default: `right`.
- `--target`: Named window to split in (default: most recently focused).
- `--name`: Register the new pane with a name for later targeting.

### `ghoztty +close`

Close a named pane or window. Closing a nonexistent target succeeds silently.

```
ghoztty +close --target=<name>
```

### `ghoztty +read`

Read the last N lines of terminal output from a named pane and print to stdout.

```
ghoztty +read --name=<pane> --lines=<N>
```

- `--name`: Named pane to read from (required).
- `--lines`: Number of lines from the end of scrollback (default: 50).

### `ghoztty +send-keys`

Send text input to a named pane's terminal PTY.

```
ghoztty +send-keys --target=<name> <text|key>...
```

- `--target`: Named pane or window to send input to. Required.
- Positional arguments are text or key names, concatenated and written to the PTY.
- Key notation: `C-c` (Ctrl-C), `C-d` (Ctrl-D), `C-z` (Ctrl-Z), etc.
- Named keys: `Enter`, `Tab`, `Escape`, `Space`, `Backspace`
- Escape sequences in text: `\n`, `\t`, `\r`, `\\`, `\e`

```bash
ghoztty +send-keys --target=term "ls -la" Enter
ghoztty +send-keys --target=term C-c
ghoztty +send-keys --target=term "hello\tworld\n"
```

### Naming

- `+new-window --target=<name>` registers a **window**
- `+split --name=<name>` registers a **pane**
- `+split --target`, `+close --target`, and `+send-keys --target` reference either kind

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

## Build & Test

```bash
zig build -Doptimize=Debug
```

**NEVER modify, replace, copy over, or touch `/Applications/Ghoztty.app` in any way.** The installed app is the user's primary terminal. Always test with the debug build at `zig-out/Ghoztty.app`. The debug build uses a separate socket (`ghostty-debug-<uid>.sock`) so it can run alongside the release app.

## Architecture

- **Zig core** (`src/`): terminal emulation, input handling, CLI commands, IPC client
- **Swift macOS app** (`macos/`): SwiftUI frontend, IPC server, split tree layout
- Split panes use a binary tree (`SplitTree`) with a ratio (0.0–1.0) per split node
- IPC uses JSON messages over a Unix domain socket at `$TMPDIR/ghostty[-debug]-<uid>.sock`

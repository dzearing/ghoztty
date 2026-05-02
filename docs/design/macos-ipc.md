# macOS IPC for Declarative Terminal Workspaces

## Goal

Enable programmatic, declarative terminal workspace setup on macOS via CLI commands. All commands are idempotent — running a setup script twice focuses existing windows/panes rather than creating duplicates.

```bash
# Create a named workspace — re-running focuses instead of duplicating
ghostty +new-window --target=dev --working-directory=~/project --command=vim
ghostty +split --target=dev --name=server --direction=right --command="npm run dev"
ghostty +split --target=dev --name=tests --direction=down --command="npm test"

# Tear down specific panes or entire windows
ghostty +close --target=tests    # closes just the test pane
ghostty +close --target=dev      # closes the entire window
```

## Background

The `+new-window` CLI action exists and works on Linux via D-Bus IPC. On macOS, `embedded.zig:performIpc` previously returned `false` because no IPC transport was implemented. The macOS app is a native Swift/Cocoa app that embeds the Ghostty Zig library via C function exports.

## Architecture

```
CLI (+new-window / +split / +close)
  → apprt.App.performIpc()
    → embedded.zig: Unix socket client
      → JSON over Unix socket
        → IPCServer.swift: parse, dispatch
          → TerminalController / NotificationCenter
```

### IPC Transport: Unix Domain Socket

Unix sockets are the simplest cross-language transport (Zig ↔ Swift) that avoids XPC entitlement complexity and deprecated distributed notifications.

**Socket path:** `$TMPDIR/ghostty[-debug]-$UID.sock`
- Debug/ReleaseSafe builds use `ghostty-debug-$UID.sock`
- ReleaseFast/ReleaseSmall builds use `ghostty-$UID.sock`
- This prevents debug builds from conflicting with a running release instance

**Socket security:**
- Mode `0600` (owner read/write only)
- `FD_CLOEXEC` set to prevent leaking into child processes
- Stale socket removed via `unlink()` before `bind()` on startup
- Socket removed in `applicationWillTerminate`

**Protocol:** Length-prefixed JSON messages.

```
[4 bytes: message length (big-endian uint32)][JSON payload]
```

Request:
```json
{
  "action": "new-window",
  "arguments": ["--target=dev", "--working-directory=/path", "--command=vim"]
}
```

Response:
```json
{
  "success": true
}
```

## CLI Actions

### `+new-window` — Create or Focus a Window

```bash
ghostty +new-window [flags]
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Register window with a name. If exists, focuses instead of creating. |
| `--working-directory=<path>` | Working directory for the initial surface |
| `--command=<cmd>` | Command to run in the initial surface |
| `--split=right\|down\|left\|up` | Create an initial split after window creation |
| `--split-command=<cmd>` | Command to run in the initial split pane |
| `--name=<name>` | Name for the initial split pane (if `--split` is used) |
| `-e <cmd> [args...]` | Command (everything after `-e` becomes the command) |

**Idempotent behavior:** If `--target=X` is specified and a window named X already exists and is alive, the window is focused (`makeKeyAndOrderFront` + `NSApp.activate`) and no new window is created.

### `+split` — Create or Focus a Split Pane

```bash
ghostty +split [flags]
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Window to add the split to (by name). Defaults to frontmost. |
| `--name=<name>` | Register the pane with a name. If exists, focuses instead of creating. |
| `--direction=right\|down\|left\|up` | Split direction. Defaults to `right`. |
| `--command=<cmd>` | Command to run in the new pane |
| `--working-directory=<path>` | Working directory for the new pane |
| `-e <cmd> [args...]` | Command (everything after `-e` becomes the command) |

**Idempotent behavior:** If `--name=X` is specified and a pane named X already exists and is alive, the pane is focused via `BaseTerminalController.focusSurface()` and no new split is created.

**Target resolution:** If `--target` is specified, the named window's controller is looked up. If omitted, `TerminalController.preferredParent` (the most recently focused terminal window) is used.

### `+close` — Close a Named Pane or Window

```bash
ghostty +close --target=<name>
```

| Flag | Description |
|------|-------------|
| `--target=<name>` | Required. The name of the pane or window to close. |

**Behavior by target type:**
- If target is a **pane name** → calls `closeSurface(_:withConfirmation: false)` on that surface
- If target is a **window name** → calls `closeWindowImmediately()` on the controller
- If target **doesn't exist** (already closed or never created) → returns success (idempotent)

`withConfirmation: false` skips the "process still running" dialog since this is a programmatic close.

## Target Registry

IPCServer maintains a `[String: TargetEntry]` dictionary that maps names to either windows or panes.

```swift
private enum TargetEntry {
    case window(WeakRef<TerminalController>)
    case pane(controller: WeakRef<TerminalController>, surface: WeakRef<Ghostty.SurfaceView>)
}
```

- All references are **weak** — when a user manually closes a window/pane, the reference becomes `nil` automatically
- `pruneStaleTargets()` is called before lookups to remove dead entries
- Window names and pane names share a **single namespace** (last write wins if collision)
- Names are registered at creation time and removed on `+close`

## Implementation Details

### Split Creation (bypasses `ghostty_surface_split`)

Splits are created entirely on the Swift side by posting `Notification.ghosttyNewSplit` directly with a custom `SurfaceConfiguration`. This bypasses the `ghostty_surface_split()` C export because that function only accepts a direction — it has no way to pass a custom command or working directory.

The notification is handled by `BaseTerminalController.ghosttyDidNewSplit()` which creates the new `SurfaceView` synchronously and moves focus to it. After the notification is posted, `controller.focusedSurface` returns the newly created surface — this is what gets registered for pane names.

### Thread Safety

- Socket server accepts connections on a background GCD serial queue
- All UI operations (`newWindow`, `closeSurface`, `focusSurface`) dispatch to `DispatchQueue.main`
- `stop()` uses `queue.sync` to safely cancel the accept source
- Window/split creation is fire-and-forget (response sent immediately, UI dispatched async)

### Zig JSON Serialization

Uses `std.json.Stringify` with `std.Io.Writer.Allocating` (same pattern as `src/terminal/c/types.zig`). Response parsing uses `std.json.parseFromSlice`. Reads use a `readFull` helper that loops to handle partial reads.

## Key Files

| File | Role |
|------|------|
| `src/apprt/embedded.zig` | Unix socket client: `performIpc` → `ipcNewWindow` / `ipcSplit` / `ipcClose` |
| `src/apprt/ipc.zig` | IPC action types: `NewWindow`, `Split`, `Close` (with C ABI structs) |
| `src/cli/new_window.zig` | `+new-window` CLI action (argument collection, `performIpc` call) |
| `src/cli/split.zig` | `+split` CLI action |
| `src/cli/close.zig` | `+close` CLI action |
| `src/cli/ghostty.zig` | CLI action registry (enum + runMain dispatch) |
| `include/ghostty.h` | C header for IPC action enums and structs |
| `macos/Sources/Features/IPC/IPCServer.swift` | Socket server, target registry, action handlers |
| `macos/Sources/Features/IPC/IPCMessage.swift` | `IPCRequest` (Decodable) / `IPCResponse` (Encodable) |
| `macos/Sources/App/macOS/AppDelegate.swift` | Lifecycle: `ipcServer.start()` / `.stop()` |

## Build & Test

```bash
# Build (from repo root — requires Zig 0.15.2+, Xcode 26, Metal Toolchain)
PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" zig build -Doptimize=Debug

# Launch the debug build (uses separate socket from release)
./zig-out/Ghostty.app/Contents/MacOS/ghostty

# Test from another terminal
./zig-out/Ghostty.app/Contents/MacOS/ghostty +new-window --target=test --command=bash
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=test --name=right --direction=right --command=top
./zig-out/Ghostty.app/Contents/MacOS/ghostty +close --target=right
./zig-out/Ghostty.app/Contents/MacOS/ghostty +close --target=test

# Re-runnable workspace script
./zig-out/Ghostty.app/Contents/MacOS/ghostty +new-window --target=dev --command=vim
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=dev --name=server --direction=right --command="npm start"
./zig-out/Ghostty.app/Contents/MacOS/ghostty +split --target=dev --name=tests --direction=down --command="npm test"
# Run again — focuses existing panes, no duplicates
```

Consult `HACKING.md` for full build prerequisites.

## Non-Goals

- Windows support (no macOS IPC on Windows)
- Replacing the existing GTK D-Bus implementation
- Full remote control API (focused on workspace setup/teardown)
- `--title` support (SurfaceConfiguration doesn't have a title field)
- `--tab` support (could be added later)

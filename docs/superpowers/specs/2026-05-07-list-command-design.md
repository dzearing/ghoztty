# +list IPC Command — Design & Implementation Status

## Overview

`ghoztty +list` queries the running Ghoztty instance over the Unix domain socket and outputs the current window/tab/split/pane state. Human-readable tree view by default, `--json` flag for machine-readable output.

## Implementation Status

**Branch:** `users/dzearing/list-state`  
**Status:** Code complete, builds successfully. Tested with debug build (created named windows, splits, verified JSON and tree output). Needs final retest after merge to main — the debug build can't run alongside the installed release Ghoztty due to bundle ID conflict.

### What was tested and worked (2026-05-07)
- `ghoztty +list` — human-readable tree view with window targets, pane names, split structure
- `ghoztty +list --json` — full JSON output with recursive split tree
- `ghoztty +list --help` — help text
- `ghoztty +help` — list action appears in help listing
- Creating windows/splits with `--target`/`--name`, then verifying they appear in `+list` output
- Empty state (no windows) returns appropriate message

### What needs retesting after merge
- Auto-generated window names (`window-1`, `window-2`) showing in `target` field
- Auto-generated pane names (UUID format) showing in `name` field
- `+close` targeting panes by UUID name after `+list` auto-registers them
- Crash fix: removed unsafe `unsafeCValue` pointer cast, now uses UUID strings

## Architecture

### Key design decision: bypasses `performIpc`

The existing IPC actions (`+new-window`, `+split`, `+close`) are mutations that go through `performIpc` → `sendIpc`, which returns a `bool` (success/fail). `+list` is a query that needs the response body, so `list.zig` handles its own socket communication directly — connecting to the same Unix socket, sending the request, and reading the full response.

This means `+list` does NOT touch `ipc.zig`, `embedded.zig`, `none.zig`, or `ghostty.h`. It's self-contained in `list.zig` plus the Swift server handler.

### Socket path

Same socket as all other IPC: `$TMPDIR/ghostty[-debug]-<uid>.sock`  
Debug builds use `-debug` suffix. Release builds do not.

### Protocol

Standard IPC protocol: 4-byte big-endian length prefix + JSON payload, both directions.

**Request:** `{"action":"list"}`  
**Response:** `{"success":true,"data":{"windows":[...]}}`

## Files Changed

### New files
- **`src/cli/list.zig`** — CLI handler. Parses `--json` flag. Connects to Unix socket, sends `{"action":"list"}`, reads response. Either prints raw JSON or formats a human-readable tree view. Duplicates socket connection helpers from `embedded.zig` (small, avoids coupling).

### Modified files
- **`src/cli/ghostty.zig`** — Added `list` to `Action` enum, import, `runMain` dispatch, `description`, `options`
- **`macos/Sources/Features/IPC/IPCMessage.swift`** — Added optional `data: IPCData?` field to `IPCResponse`. Added `IPCData` enum with `ListStateData`, `WindowData`, `TabData`, `SplitNodeData` (recursive), `TerminalData` structs. Custom `Encodable` conformance for the recursive split tree.
- **`macos/Sources/Features/IPC/IPCServer.swift`** — Added `"list"` case to `dispatchAction`. Implemented `handleList()` which dispatches to main thread via `DispatchQueue.main.async` + `MainActor.assumeIsolated` + semaphore pattern. Walks `NSApp.scriptWindows` → tabs → `controller.surfaceTree` recursively. Auto-registers all discovered windows/panes in `targetRegistry` so `+close` can target them. Helper methods: `buildSplitNodeData`, `paneNameForSurface`, `ensureWindowRegistered`, `ensurePaneRegistered`.

### NOT modified (by design)
- `src/apprt/ipc.zig` — `list` is not in the `Action` union (no payload, no C ABI needed)
- `src/apprt/embedded.zig` — `list.zig` handles socket IO directly
- `src/apprt/none.zig` — same reason
- `include/ghostty.h` — no C enum entry needed

## JSON Schema

```json
{
  "windows": [
    {
      "id": "tab-group-8f436dd60",
      "title": "Editor",
      "target": "window-1",
      "focused": true,
      "tabs": [
        {
          "id": "tab-8f5985200",
          "title": "Editor",
          "index": 1,
          "selected": true,
          "splits": {
            "type": "split",
            "direction": "horizontal",
            "ratio": 0.5,
            "left": {
              "type": "leaf",
              "terminal": {
                "id": "485DECDE-6D97-4936-9EF1-EA2D20B77677",
                "title": "~/projects",
                "working_directory": "/Users/david/projects",
                "pid": 12345,
                "tty": "/dev/ttys003",
                "name": "485DECDE-6D97-4936-9EF1-EA2D20B77677",
                "focused": true
              }
            },
            "right": {
              "type": "leaf",
              "terminal": {
                "id": "20EF0AC2-E04F-4BCA-A1AD-31F6A8BF4E12",
                "title": "~/logs",
                "working_directory": "/Users/david/logs",
                "pid": 12346,
                "tty": "/dev/ttys004",
                "name": "logs",
                "focused": false
              }
            }
          }
        }
      ]
    }
  ]
}
```

### Field details

- **`target`** (on windows): Always present. `controller.windowName` — either user-provided via `+new-window --target=X` or auto-generated as `window-1`, `window-2`, etc.
- **`name`** (on terminals): Always present. Either user-provided via `+split --name=X` or the UUID string of the surface. All names are auto-registered in `targetRegistry` during `+list` so they can be used with `+close --target=<name>`.
- **`splits`**: Recursive tree matching `SplitTree.Node` — `"type":"leaf"` with `terminal` object, or `"type":"split"` with `direction`, `ratio`, `left`, `right`.
- **`focused`**: On windows = frontmost window. On terminals = the focused surface in its tab.

## Human-Readable Output

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

- Single-pane tabs: terminal shown inline (no tree characters)
- Multi-pane tabs: `├─`/`└─` tree connectors, flat leaf list
- `*` marks the focused terminal in each tab
- `[target: X]` and `[name: X]` always shown
- No windows: `No windows open.`

## Known Issues / Crash Fix

**Crash (fixed):** Initial implementation tried to cast `view.surfaceModel?.unsafeCValue` (an opaque `ghostty_surface_t` / `void*`) to `UInt` to reconstruct the Zig surface ID hex format (`0x{16hex}`). This crashed. Fixed by using the Swift UUID string instead.

**Consequence:** Pane names from `+list` are UUIDs (e.g. `485DECDE-6D97-4936-9EF1-EA2D20B77677`), not the hex surface IDs in the `GHOZTTY_PANE_NAME` env var (e.g. `0x531c7233013ef071`). These are two different ID systems. To make them match, we'd need to expose the Zig surface ID through the C API — a future improvement.

## Post-Merge TODO

1. Merge branch to `fork/main`
2. Rebuild installed Ghoztty app
3. Retest: `+list`, `+list --json`, auto-naming, `+close` by auto-generated name
4. Update the ghoztty skill with `+list` documentation

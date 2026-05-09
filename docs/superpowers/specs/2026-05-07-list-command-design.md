# +list IPC Command Design

## Overview

Add a `+list` CLI/IPC command that queries the running Ghoztty instance and returns the current window/tab/split state. Human-readable tree view by default, `--json` flag for machine-readable JSON output.

## Protocol

Uses the existing Unix socket IPC protocol (4-byte big-endian length prefix + JSON payload).

**Request:** `{"action":"list"}`

**Response:** `{"success":true,"data":{"windows":[...]}}`

`IPCResponse` gains an optional `data` field. The `+list` CLI handler reads the full response body rather than just parsing `success`.

## JSON Schema

```json
{
  "windows": [
    {
      "id": "string",
      "title": "string",
      "target": "string (optional, from targetRegistry)",
      "focused": true,
      "tabs": [
        {
          "id": "string",
          "title": "string",
          "index": 1,
          "selected": true,
          "splits": {
            "type": "leaf|split",
            "terminal": {
              "id": "UUID",
              "title": "string",
              "working_directory": "string",
              "pid": 12345,
              "tty": "/dev/ttys003",
              "name": "string (optional, from targetRegistry)",
              "focused": true
            },
            "direction": "horizontal|vertical (split only)",
            "ratio": 0.5,
            "left": { "...recursive" },
            "right": { "...recursive" }
          }
        }
      ]
    }
  ]
}
```

## Human-Readable Output

```
Window: "~/projects — zsh" [target: editor] (focused)
  Tab 1: "~/projects — zsh" (selected)
    zsh  ~/projects  pid:12345  /dev/ttys003  [name: main-editor] *
  Tab 2: "~/logs — tail"
    ├─ tail  ~/logs  pid:12346  /dev/ttys004
    └─ zsh   ~/src   pid:12347  /dev/ttys005  [name: log-watcher]
```

No windows: prints `No windows open.`

## Files to Modify

### Zig (src/)
- `src/cli/ghostty.zig` — Add `list` to Action enum
- `src/cli/list.zig` — New file: CLI handler with `--json` flag, socket communication, tree formatting
- `src/apprt/ipc.zig` — Add `list` to Action union and Key enum (void payload)
- `src/apprt/embedded.zig` — Add `list` case to `performIpc`, add `sendIpcQuery` that returns response body
- `include/ghostty.h` — Add `GHOSTTY_IPC_ACTION_LIST` to C enum

### Swift (macos/)
- `macos/Sources/Features/IPC/IPCMessage.swift` — Add optional `data` field to `IPCResponse`
- `macos/Sources/Features/IPC/IPCServer.swift` — Add `handleList` that walks windows/tabs/splits and builds JSON, including targetRegistry name lookups

## Post-Merge

Update the ghoztty skill with `+list` documentation after publishing.
